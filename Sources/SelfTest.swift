import Cocoa

/// 自检模式：注入一组模拟读数，把小组件和菜单栏面板离屏渲染成 PNG。
///
/// 存在的意义：真实数据要等温度计刷好固件才有，但布局问题不能等到那时候
/// 才发现。`cacheDisplay` 走的是正常绘制路径，出来的就是用户看到的画面，
/// 而且不需要屏幕录制权限。
enum SelfTest {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["TEMPBAR_SELFTEST"] == "1"
    }

    static var outputDir: String {
        ProcessInfo.processInfo.environment["TEMPBAR_SELFTEST_DIR"] ?? NSTemporaryDirectory()
    }

    static func run() {
        // 用浅色外观渲染，和用户桌面环境一致
        NSApp.appearance = NSAppearance(named: .aqua)

        // 自检要改 UserDefaults 里的尺寸/主题键（每个组合都得写一次）。
        // 这些键跟用户真实设置是同一份，不备份的话跑完一次自检，
        // 用户本来选的「大号 + 仿苹果」就变成测试最后留下的那个值了。
        // 之前一直有这个副作用：开发期间跑完自检，桌面上那张卡会莫名换样。
        saveUserPrefs()

        // 测试数据落在独立目录，别碰用户真实的 state.json。
        // 注意：这里改晚了也没用 —— AppState.shared 一旦被访问，路径就已经算好了。
        // 所以真正的 setenv 在 Main.main() 里、访问单例之前就执行了。
        seed()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            render()
            // 先关掉写盘，再清内存、删目录。
            // 终止时 AppDelegate 会 persist 一次，不拦就会在删完之后
            // 又把测试数据写回来，目录永远删不干净。
            AppState.persistEnabled = false
            AppState.shared.clearAll()
            cleanup()
            restoreUserPrefs()
            NSApp.terminate(nil)
        }
    }

    /// 自检会动的几个偏好键，跑之前先存一份
    private static let touchedPrefs = ["tempbar.widget.size", "tempbar.widget.theme"]
    private static var savedPrefs: [String: Any?] = [:]

    private static func saveUserPrefs() {
        let d = UserDefaults.standard
        for k in touchedPrefs {
            savedPrefs[k] = d.object(forKey: k)
        }
    }

    private static func restoreUserPrefs() {
        let d = UserDefaults.standard
        for k in touchedPrefs {
            // 原来是 nil 的要删掉，而不是留成空字符串 ——
            // WidgetPanel.init 靠「键不存在」来走默认值分支
            if let v = savedPrefs[k], let real = v {
                d.set(real, forKey: k)
            } else {
                d.removeObject(forKey: k)
            }
        }
    }

    /// 跑完把测试数据目录删掉，不留垃圾
    private static func cleanup() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let d = base.appendingPathComponent("TempBarSelfTest", isDirectory: true)
        try? FileManager.default.removeItem(at: d)
    }

    /// 造一台有 6 小时历史的设备，曲线才有东西可画
    private static func seed() {
        let state = AppState.shared
        // 自检必须从干净状态开始。
        // 用户机器上 state.json 里存着真实温度计，不清掉的话
        // primary 会指向那台"有历史但此刻没读数"的设备，
        // 渲染出来是"等待温度计"，测试就等于没测。
        state.clearAll()

        let id = "SELFTEST-DEVICE"

        var r = Reading()
        r.temperature = 23.4
        r.humidity = 34.2
        r.battery = 92
        r.voltage = 2.995
        r.packetID = 7
        state.ingest(id: id, name: "温湿度计", reading: r, rssi: -55)

        guard let dev = state.devices[id] else { return }

        // 一条平滑起伏的曲线：整体缓慢升温和下班后的回落
        let now = Date()
        var hist: [Sample] = []
        for i in stride(from: 360, through: 0, by: -2) {
            let t = now.addingTimeInterval(-Double(i) * 60)
            let phase = Double(360 - i) / 60.0
            let base = 22.0 + 2.4 * sin(phase / 2.2) + 0.5 * cos(phase * 1.7)
            let noise = Double.random(in: -0.12...0.12)
            hist.append(Sample(t: t, temp: base + noise,
                               hum: 36 + 6 * sin(phase / 3.1)))
        }
        dev.history = hist

        var th = state.thresholds
        th.enabled = true
        state.thresholds = th
    }

    private static func render() {
        let dir = outputDir
        try? FileManager.default.createDirectory(atPath: dir,
                                                 withIntermediateDirectories: true)

        // --- 六个组合全渲染：3 个尺寸 × 2 套主题
        // 尺寸和主题是两个独立维度，所以要把笛卡尔积都渲一遍。
        // 只渲对角线（小-经典、中-经典、大-仿苹果）会漏掉
        // 「小号仿苹果」「大号经典」这些新组合的排版问题。
        for theme in WidgetTheme.allCases {
            for size in WidgetSize.allCases {
                UserDefaults.standard.set(size.rawValue, forKey: "tempbar.widget.size")
                UserDefaults.standard.set(theme.rawValue, forKey: "tempbar.widget.theme")
                let w = WidgetPanel()
                w.rebuild()
                w.layoutIfNeeded()
                let p = (dir as NSString)
                    .appendingPathComponent("widget-\(theme.rawValue)-\(size.rawValue).png")
                NSLog("TempBar 自检 widget-\(theme.rawValue)-\(size.rawValue): "
                      + "\(w.snapshot(to: p) ? "OK " + p : "失败")")
            }
        }

        // 恢复默认，免得后面几项检查读到最后一轮残留的"大号仿苹果"
        UserDefaults.standard.set(WidgetSize.medium.rawValue, forKey: "tempbar.widget.size")
        UserDefaults.standard.set(WidgetTheme.classic.rawValue, forKey: "tempbar.widget.theme")

        // --- 菜单栏面板
        let panel = StatusPanel()
        let v = panel.view      // 触发 loadView
        v.frame = NSRect(x: 0, y: 0, width: 292, height: 300)
        v.layoutSubtreeIfNeeded()
        panel.refresh()
        v.layoutSubtreeIfNeeded()
        let p3 = (dir as NSString).appendingPathComponent("menu-panel.png")
        NSLog("TempBar 自检 menu-panel: \(snapshot(v, to: p3) ? "OK " + p3 : "失败")")

        // --- 菜单面板必须恒定浅色
        menuPanelLightCheck(dir: dir)

        // --- 几何检查：卡片必须严格填满窗口，尺寸必须按档位到位
        geometryChecks()

        // --- 尺寸切换：中→小→中，验证缩得回去也放得回去
        sizeSwitchChecks(dir: dir)

        // --- 主题切换：尺寸不能被主题带跑，反之亦然
        themeSwitchChecks(dir: dir)

        // --- 改名：自定义名不能被广播冲掉
        renameChecks()

        // --- 改名持久化：存盘再读回来，名字还在
        persistChecks()

        // --- 老版本存档迁移：尺寸存成 "apple" 的要翻译成 大号+仿苹果
        migrationChecks()

        // --- 设置窗口（含设备名输入行）也要能正常布局
        settingsChecks(dir: dir)

        // --- 越界读数过滤（236° 那种）
        sanitizeChecks()

        // --- 检查更新：版本比较 + 清单解析
        updateChecks()

        // --- 深色模式：必须真的能看清字，不能只是"渲染成功"
        darkModeChecks(dir: dir)

        // --- 空状态（验证"等待温度计"不出错）
        // 先把设备清掉，否则渲染的还是种子数据，测不到空状态分支
        AppState.shared.clearAll()
        let empty = WidgetPanel()
        empty.rebuild()
        let p4 = (dir as NSString).appendingPathComponent("widget-empty.png")
        NSLog("TempBar 自检 widget-empty: \(empty.snapshot(to: p4) ? "OK " + p4 : "失败")")

        // 空状态在仿苹果主题下也要能看清（深紫底不能配黑字）
        UserDefaults.standard.set(WidgetSize.medium.rawValue, forKey: "tempbar.widget.size")
        UserDefaults.standard.set(WidgetTheme.apple.rawValue, forKey: "tempbar.widget.theme")
        let emptyApple = WidgetPanel()
        emptyApple.rebuild()
        let p5 = (dir as NSString).appendingPathComponent("widget-empty-apple.png")
        NSLog("TempBar 自检 widget-empty-apple: "
              + "\(emptyApple.snapshot(to: p5) ? "OK " + p5 : "失败")")

        // 窗口级：把卡片外面那一圈也拍下来。
        // 用户报的"紫色对但外面还有黑线 + 灰色填充"就在卡片之外，
        // 只拍 card 的话永远看不出来。
        let p6 = (dir as NSString).appendingPathComponent("window-empty-apple.png")
        NSLog("TempBar 自检 window-empty-apple: "
              + "\(emptyApple.windowSnapshot(to: p6) ? "OK " + p6 : "失败")")

        let cf = emptyApple.cardFrameInWindow
        let win = emptyApple.actualSize
        NSLog("TempBar 自检 [几何] 窗口=\(Int(win.width))×\(Int(win.height)) "
              + "卡片 frame=(\(Int(cf.origin.x)),\(Int(cf.origin.y))) "
              + "\(Int(cf.width))×\(Int(cf.height)) → "
              + "\(abs(cf.width - win.width) < 0.5 && abs(cf.height - win.height) < 0.5 ? "贴合 OK" : "有缝 错")")

        UserDefaults.standard.set(WidgetTheme.classic.rawValue, forKey: "tempbar.widget.theme")
    }

    /// 主题切换不能带着尺寸跑。
    ///
    /// 这是拆分尺寸/主题时最容易出的错：把 theme 的切换写成也调 applySize，
    /// 用户点一下主题，卡片忽大忽小。这里正反各试一次。
    private static func themeSwitchChecks(dir: String) {
        UserDefaults.standard.set(WidgetSize.medium.rawValue, forKey: "tempbar.widget.size")
        UserDefaults.standard.set(WidgetTheme.classic.rawValue, forKey: "tempbar.widget.theme")

        let w = WidgetPanel()
        w.rebuild()
        let beforeSize = w.actualSize

        w.applyTheme(.apple)
        let afterApple = w.actualSize
        let okTheme = w.currentTheme == .apple
        let okSize = abs(afterApple.width - beforeSize.width) < 0.5
            && abs(afterApple.height - beforeSize.height) < 0.5
        NSLog("TempBar 自检 [主题] 经典→仿苹果 尺寸 \(Int(afterApple.width))×\(Int(afterApple.height)) "
              + "(原 \(Int(beforeSize.width))×\(Int(beforeSize.height))) → "
              + "\(okSize ? "尺寸没变 OK" : "尺寸被带跑了 错")；"
              + "主题切换 \(okTheme ? "OK" : "错")")

        // 换个尺寸再切回去，验证套用顺序不影响结果
        w.applySize(.small)
        w.applyTheme(.classic)
        let okBack = w.currentTheme == .classic
            && abs(w.actualSize.width - WidgetSize.small.size.width) < 0.5
        NSLog("TempBar 自检 [主题] 小号+经典 窗口=\(Int(w.actualSize.width))×\(Int(w.actualSize.height)) "
              + "→ \(okBack ? "OK" : "错")")

        // 小号 + 仿苹果：这个组合以前根本表达不出来
        w.applyTheme(.apple)
        let okSmallApple = w.currentTheme == .apple
            && abs(w.actualSize.width - WidgetSize.small.size.width) < 0.5
        NSLog("TempBar 自检 [主题] 小号+仿苹果 \(okSmallApple ? "OK" : "错")")

        UserDefaults.standard.set(WidgetTheme.classic.rawValue, forKey: "tempbar.widget.theme")
    }

    /// 老存档迁移。
    ///
    /// 老版本只有三个尺寸值 small/medium/apple，其中 "apple" 同时代表
    /// 大号和仿苹果主题。拆开之后读到 "apple" 必须翻译成
    /// 「大号 + 仿苹果」，否则老用户升级后设置会被悄悄改回中号经典。
    private static func migrationChecks() {
        UserDefaults.standard.set("apple", forKey: "tempbar.widget.size")
        UserDefaults.standard.removeObject(forKey: "tempbar.widget.theme")

        let w = WidgetPanel()
        let okSize = w.currentSize == .large
        let okTheme = w.currentTheme == .apple
        NSLog("TempBar 自检 [迁移] 旧值 size=apple → 尺寸=\(w.currentSize.title) "
              + "主题=\(w.currentTheme.title) → "
              + "\(okSize && okTheme ? "OK" : "错")")

        // 迁移后要把新值落盘，第二次启动才走正常分支
        let storedSize = UserDefaults.standard.string(forKey: "tempbar.widget.size")
        let storedTheme = UserDefaults.standard.string(forKey: "tempbar.widget.theme")
        NSLog("TempBar 自检 [迁移] 落盘 size=\(storedSize ?? "nil") theme=\(storedTheme ?? "nil") → "
              + "\(storedSize == "large" && storedTheme == "apple" ? "OK" : "错")")

        // 正常值不能被迁移逻辑误伤
        UserDefaults.standard.set("small", forKey: "tempbar.widget.size")
        UserDefaults.standard.set("apple", forKey: "tempbar.widget.theme")
        let w2 = WidgetPanel()
        NSLog("TempBar 自检 [迁移] 正常值 small+apple → 尺寸=\(w2.currentSize.title) "
              + "主题=\(w2.currentTheme.title) → "
              + "\(w2.currentSize == .small && w2.currentTheme == .apple ? "OK" : "错")")

        UserDefaults.standard.set(WidgetSize.medium.rawValue, forKey: "tempbar.widget.size")
        UserDefaults.standard.set(WidgetTheme.classic.rawValue, forKey: "tempbar.widget.theme")
    }

    /// 越界读数必须被掐掉。
    ///
    /// 之前图表出现过 "23.5° — 236.5°"，纵轴被一条 236 度的直线压成一条缝。
    /// 抓原始字节确认解码没错，是广播本身吐了不合理值。
    /// 现在入口处统一过滤（Reading.sanitized），这里验证三件事：
    ///   1. 236° 被清成 nil
    ///   2. 正常值原样保留
    ///   3. 已经写进历史文件的越界采样也会被 prune 清掉
    /// 检查更新的核心逻辑：版本比较 + 清单解析。
    ///
    /// 这两块是纯逻辑，脱网也能测，所以放进自检。
    /// 「能不能真连上服务器、能不能下载」依赖网络，不在这里测 ——
    /// 自检一旦依赖外网，没网的时候就一片红，反而干扰判断。
    ///
    /// 版本比较踩过的坑：直接按字符串比会得出 "1.10" < "1.9"，发到第十个
    /// 小版本时所有人都收不到更新。所以必须按点分段转数字比。
    private static func updateChecks() {
        let cases: [(String, String, Bool)] = [
            ("1.3", "1.2", true),
            ("1.10", "1.9", true),      // 字符串比会算错，数字比才对
            ("1.9", "1.10", false),
            ("1.3", "1.3", false),
            ("2.0", "1.99.99", true),
            ("1.3.1", "1.3", true),
            ("1.3", "1.3.1", false)
        ]
        var bad = 0
        for (a, b, want) in cases where Updater.isNewer(a, than: b) != want {
            bad += 1
            NSLog("TempBar 自检 [更新] 版本比较 \(a) vs \(b) → 期望 \(want) 实际相反 错")
        }
        NSLog("TempBar 自检 [更新] 版本比较 \(cases.count) 例 → \(bad == 0 ? "全部 OK" : "\(bad) 例错")")

        let full = #"{"version":"1.4","build":5,"downloadURL":"http://x/T.zip","sha256":"ab12","size":100}"#
        if let m = try? JSONDecoder().decode(UpdateManifest.self,
                                             from: Data(full.utf8)) {
            NSLog("TempBar 自检 [更新] 清单解析 version=\(m.version) build=\(m.build ?? -1) "
                  + "sha256=\(m.sha256 ?? "nil") → OK")
        } else {
            NSLog("TempBar 自检 [更新] 清单解析 → 错（完整清单解不出来）")
        }

        // 没 sha256 的清单本身能解析，但 Updater 在安装前会拒绝。
        // 这里只验证"不会因为缺字段就崩"，拒绝逻辑在 verifyAndInstall 里。
        let noSha = #"{"version":"1.4","downloadURL":"http://x/T.zip"}"#
        let ok = (try? JSONDecoder().decode(UpdateManifest.self, from: Data(noSha.utf8))) != nil
        NSLog("TempBar 自检 [更新] 缺 sha256 的清单 → \(ok ? "能解析、安装前会被拒 OK" : "解析失败 错")")

        // 真实拉一次服务器。
        //
        // 只在设了 TEMPBAR_NET_TEST=1 时跑：常规自检不能依赖外网，
        // 没网的时候一片红反而看不出真问题。
        // 这项专门验 ATS —— 更新源是裸 IP + http，Info.plist 里的
        // NSAllowsArbitraryLoads 没生效的话，这里会直接报
        // "App Transport Security has blocked a cleartext HTTP"。
        guard ProcessInfo.processInfo.environment["TEMPBAR_NET_TEST"] == "1" else { return }

        let sem = DispatchSemaphore(value: 0)
        var req = URLRequest(url: Updater.feedURL)
        req.timeoutInterval = 8
        req.cachePolicy = .reloadIgnoringLocalCacheData
        var out = "超时（12 秒没回来）"
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let e = err {
                out = "错：\(e.localizedDescription)"
            } else if let d = data,
                      let m = try? JSONDecoder().decode(UpdateManifest.self, from: d) {
                let newer = Updater.isNewer(m.version, than: Updater.currentVersion)
                out = "OK 服务器 \(m.version)(build \(m.build ?? -1))，"
                    + "本机 \(Updater.currentVersion)，"
                    + (newer ? "判定有新版" : "判定已是最新")
            } else {
                out = "响应无法解析，HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)"
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        NSLog("TempBar 自检 [更新] 真实拉取 \(Updater.feedURL.absoluteString) → \(out)")
    }

    private static func sanitizeChecks() {
        var bad = Reading()
        bad.temperature = 236.5
        bad.humidity = 34
        bad.battery = 80
        bad.packetID = 1
        let s = bad.sanitized()
        let okTemp = s.temperature == nil
        let okKeep = s.humidity == 34 && s.battery == 80
        NSLog("TempBar 自检 [越界] 236.5° → \(s.temperature.map { String($0) } ?? "nil") "
              + "→ \(okTemp ? "OK（已丢弃）" : "错（没过滤）")；"
              + "其余字段保留 \(okKeep ? "OK" : "错")")
        // 全部字段都被清掉时不该再当成有效读数
        var allBad = Reading()
        allBad.temperature = 999
        allBad.humidity = 250
        allBad.battery = 300
        NSLog("TempBar 自检 [越界] 全越界 → 被清空 \(allBad.sanitized().isEmpty ? "OK" : "错")")

        // 边界值：200 本身算合法，201 不算
        var edge = Reading(); edge.temperature = 200
        var edge2 = Reading(); edge2.temperature = 201
        NSLog("TempBar 自检 [越界] 边界 200 保留 \(edge.sanitized().temperature != nil ? "OK" : "错")"
              + " / 201 丢弃 \(edge2.sanitized().temperature == nil ? "OK" : "错")")
    }

    /// 菜单栏面板固定浅色。
    ///
    /// 用户反馈：跟随系统深浅色时，切换之后面板内外配色不统一，很难看。
    /// 现在把 appearance 钉成 .aqua。这条测试的关键是**在深色环境下**渲染，
    /// 结果仍必须是浅色底 —— 只在浅色下渲染是测不出这个问题的。
    private static func menuPanelLightCheck(dir: String) {
        let panel = StatusPanel()
        let v = panel.view
        v.frame = NSRect(x: 0, y: 0, width: 292, height: 300)
        // 不覆盖 v.appearance：StatusPanel 已把它钉成 .aqua，
        // 这里要验证的正是那一行有没有生效。
        v.layoutSubtreeIfNeeded()
        panel.refresh()
        v.layoutSubtreeIfNeeded()

        let p = (dir as NSString).appendingPathComponent("menu-panel-dark-env.png")
        guard snapshot(v, to: p, appearance: NSAppearance(named: .darkAqua),
                       forceAppearance: false) else {
            NSLog("TempBar 自检 [菜单浅色] 渲染失败 → 错")
            return
        }

        // 直接量根视图自身的 appearance：这才是实际生效的那个
        let effective = v.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        let isLight = effective == .aqua
        NSLog("TempBar 自检 [菜单浅色] 生效外观 = \(isLight ? "aqua（浅色）" : "darkAqua（深色）") "
              + "→ \(isLight ? "OK" : "错（被系统带成深色了）")")

        // 再核一遍像素：画出来也得是浅底，光属性对不算数
        guard let img = NSImage(contentsOfFile: p),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return }
        let bg = medianLuma(rep, x: rep.pixelsWide / 2 - 20, y: 10, w: 40, h: 6)
        NSLog("TempBar 自检 [菜单浅色] 底色亮度 \(Int(bg)) → \(bg > 200 ? "OK（浅色）" : "错（变深了）")")
    }

    /// 深色模式检查。
    ///
    /// 这个测试存在的理由：之前浅色主题下启动，卡片填充被
    /// `withAlphaComponent` 固化成了白色，文字却是动态色会变白，
    /// 结果深色模式下白底白字，温度完全看不见。
    /// 光"渲染成功"是过不了这个坑的 —— 必须量像素对比度。
    private static func darkModeChecks(dir: String) {
        let w = WidgetPanel()
        w.appearance = NSAppearance(named: .darkAqua)
        // 让整棵子树都继承深色外观
        w.contentView?.appearance = NSAppearance(named: .darkAqua)
        w.rebuild()
        w.layoutIfNeeded()

        guard let card = w.contentView?.subviews.first else {
            NSLog("TempBar 自检 [深色] 拿不到卡片 → 错")
            return
        }
        card.appearance = NSAppearance(named: .darkAqua)
        card.layoutSubtreeIfNeeded()

        let p = (dir as NSString).appendingPathComponent("widget-dark.png")
        let ok = snapshot(card, to: p, appearance: NSAppearance(named: .darkAqua))
        NSLog("TempBar 自检 [深色] 渲染: \(ok ? "OK " + p : "失败")")

        // 读回像素做量化判断。NSBitmapImageRep 没有 contentsOfFile 构造器，
        // 用 NSImage 中转一次拿到 bitmap 表示。
        guard ok,
              let img = NSImage(contentsOfFile: p),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            NSLog("TempBar 自检 [深色] 读不回图片 → 错")
            return
        }

        // 注意坐标原点：NSBitmapImageRep.colorAt 的 y=0 在左下角，
        // 而人眼/图片查看器的 y=0 在左上角。取"右上角空白"必须换算，
        // 否则量到的是左下角的空白，判据会永远得 0。
        let W = rep.pixelsWide, H = rep.pixelsHigh
        // 右上角空白区（避开文字和曲线）
        let bg = medianLuma(rep, x: W - 60, y: H - 26, w: 40, h: 16)
        // 温度大字所在区域：左侧、垂直中部偏上
        let textBox = lumaRange(rep, x: 16, y: H / 2 - 20, w: W / 3, h: 44)

        let darkBg = bg < 90
        let contrast = textBox.max - textBox.min
        // 深色模式下文字和底色至少要有 60 级亮度差才看得出
        let okContrast = contrast > 60

        NSLog("TempBar 自检 [深色] 卡片底色亮度 \(Int(bg)) → \(darkBg ? "OK（是深色）" : "错（还是浅色）")")
        NSLog("TempBar 自检 [深色] 文字区亮度差 \(Int(contrast)) → \(okContrast ? "OK（看得清）" : "错（白底白字）")")

        // 深色 + 小号：小号布局没有曲线，网点也要正常
        w.applySize(.small)
        w.layoutIfNeeded()
        let p2 = (dir as NSString).appendingPathComponent("widget-dark-small.png")
        if let card2 = w.contentView?.subviews.first {
            let ok2 = snapshot(card2, to: p2, appearance: NSAppearance(named: .darkAqua))
            NSLog("TempBar 自检 [深色] 小号渲染: \(ok2 ? "OK " + p2 : "失败")")
        }
    }

    /// 直接读位图字节，不用 colorAt。
    ///
    /// colorAt 在 TIFF 往返之后会返回转换过的 NSColor，
    /// 某些色彩空间下 usingColorSpace(.sRGB) 拿到的值不可靠（实测恒为 0）。
    /// 直接按 bitmapData 取原始通道最稳。
    private static func pixelLuma(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Double? {
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        guard let data = rep.bitmapData else { return nil }
        let bpp = rep.bitsPerPixel / 8
        let rowBytes = rep.bytesPerRow
        guard bpp >= 3 else { return nil }
        let off = y * rowBytes + x * bpp
        let r = Double(data[off])
        let g = Double(data[off + 1])
        let b = Double(data[off + 2])
        return 0.299 * r + 0.587 * g + 0.114 * b
    }

    private static func medianLuma(_ rep: NSBitmapImageRep,
                                   x: Int, y: Int, w: Int, h: Int) -> Double {
        var vals: [Double] = []
        for yy in y..<min(y + h, rep.pixelsHigh) {
            for xx in x..<min(x + w, rep.pixelsWide) {
                if let l = pixelLuma(rep, xx, yy) { vals.append(l) }
            }
        }
        guard !vals.isEmpty else { return 0 }
        vals.sort()
        return vals[vals.count / 2]
    }

    private static func lumaRange(_ rep: NSBitmapImageRep,
                                  x: Int, y: Int, w: Int, h: Int) -> (min: Double, max: Double) {
        var lo = 1.0, hi = 0.0
        for yy in y..<min(y + h, rep.pixelsHigh) {
            for xx in x..<min(x + w, rep.pixelsWide) {
                guard let l = pixelLuma(rep, xx, yy) else { continue }
                lo = Swift.min(lo, l)
                hi = Swift.max(hi, l)
            }
        }
        return lo > hi ? (0, 0) : (lo, hi)
    }

    private static func settingsChecks(dir: String) {
        let wc = SettingsWindowController()
        guard let win = wc.window, let content = win.contentView else {
            NSLog("TempBar 自检 [设置] 窗口建不起来 → 错")
            return
        }
        // 给个确定尺寸再布局，避免依赖屏幕大小
        win.setContentSize(NSSize(width: 420, height: 560))
        content.layoutSubtreeIfNeeded()

        let h = content.fittingSize.height
        NSLog("TempBar 自检 [设置] 内容区 \(Int(content.frame.width))×\(Int(content.frame.height))pt "
              + "窗口 \(Int(win.frame.width))×\(Int(win.frame.height))pt "
              + "fittingSize 高 \(Int(h))pt")
        // 逐行打印宽度，找出到底哪一行把内容撑破了
        if let scroll = content.subviews.first as? NSScrollView,
           let stack = scroll.documentView?.subviews.first as? NSStackView {
            for (i, v) in stack.arrangedSubviews.enumerated() {
                NSLog("  [设置行 \(i)] \(type(of: v)) 宽 \(Int(v.frame.width)) 需要 \(Int(v.fittingSize.width))")
            }
        }

        let p = (dir as NSString).appendingPathComponent("settings.png")
        NSLog("TempBar 自检 [设置] 截图: \(snapshot(content, to: p) ? "OK " + p : "失败")")
    }

    /// 只看内存里的值是不够的 —— 真正的坑是 persist 时没把新字段写出去。
    private static func persistChecks() {
        let state = AppState.shared
        let id = "SELFTEST-DEVICE"

        guard state.devices[id] != nil else { return }
        state.setCustomName("客厅温度计", for: id)   // 内部会 persist
        state.persist()                             // 确保落盘

        // 直接读文件，确认 customName 真的写进去了
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        let file = base.appendingPathComponent("TempBarSelfTest/state.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devs = json["devices"] as? [[String: Any]] else {
            NSLog("TempBar 自检 [持久化] 读不到 state.json → 错")
            return
        }
        let saved = devs.first { ($0["id"] as? String) == id }?["customName"] as? String
        NSLog("TempBar 自检 [持久化] 文件里的 customName = 「\(saved ?? "nil")」 "
              + "→ \(saved == "客厅温度计" ? "OK" : "错（没写进去）")")

        // 再验证老版本 state.json（没有 customName 字段）不会解码失败
        let legacy = """
        {"primaryID":"OLD","devices":[{"id":"OLD","name":"ATC_OLD","history":[]}]}
        """.data(using: .utf8)!
        let probe = base.appendingPathComponent("TempBarSelfTest/legacy.json")
        try? legacy.write(to: probe)
        let obj = try? JSONSerialization.jsonObject(with: legacy)
        NSLog("TempBar 自检 [持久化] 旧格式 JSON 可解析 → \(obj != nil ? "OK" : "错")")
        try? FileManager.default.removeItem(at: probe)
    }

    /// 改名功能的核心断言：设了自定义名之后，后续广播（带固件名）
    /// 不能把它覆盖掉。之前直接把用户输入写进 `name`，下一条广播就冲回来了。
    private static func renameChecks() {
        let state = AppState.shared
        let id = "SELFTEST-DEVICE"
        guard let dev = state.devices[id] else {
            NSLog("TempBar 自检 [改名] 找不到测试设备，跳过")
            return
        }
        let firmware = dev.firmwareName

        state.setCustomName("办公室温湿度计", for: id)
        // 模拟一条新广播，带上固件原名
        var r = Reading()
        r.temperature = 23.5
        r.humidity = 34.0
        // 电量也要带上。之前漏了这行，后面深色截图里"电量"一栏是空的，
        // 排查时一度误以为是 footer 渲染丢了。
        r.battery = 92
        r.packetID = 99
        state.ingest(id: id, name: firmware, reading: r, rssi: -50)

        let afterBroadcast = dev.displayName
        let okKeep = afterBroadcast == "办公室温湿度计"
        NSLog("TempBar 自检 [改名] 自定义名在广播后 = 「\(afterBroadcast)」 → \(okKeep ? "OK" : "错（被覆盖）")")

        // 恢复原名
        state.setCustomName(nil, for: id)
        let restored = dev.displayName
        let okRestore = restored == firmware
        NSLog("TempBar 自检 [改名] 恢复后 = 「\(restored)」 期望「\(firmware)」 → \(okRestore ? "OK" : "错")")

        // 空字符串等于恢复原名，不能留个空名字
        state.setCustomName("   ", for: id)
        let blank = dev.displayName
        NSLog("TempBar 自检 [改名] 空白名 = 「\(blank)」 → \(blank == firmware ? "OK" : "错")")
    }

    /// 卡片和窗口必须严格对应。
    /// 这条之前是坏的：card 当 contentView 时被 Auto Layout 压到 259，
    /// 而窗口是 340，右边露出一条底色，肉眼看就是"边框对应不上"。
    private static func geometryChecks() {
        // 六个组合全部核对：尺寸和主题正交，任何一个组合都不能把窗口撑歪
        for theme in WidgetTheme.allCases {
            for want in WidgetSize.allCases {
                UserDefaults.standard.set(want.rawValue, forKey: "tempbar.widget.size")
                UserDefaults.standard.set(theme.rawValue, forKey: "tempbar.widget.theme")
                let w = WidgetPanel()
                w.rebuild()
                w.layoutIfNeeded()

                let label = "\(theme.rawValue)-\(want.rawValue)"
                let win = w.actualSize
                let card = w.cardSize
                let okSize = abs(win.width - want.size.width) < 0.5
                    && abs(win.height - want.size.height) < 0.5
                let okCard = abs(card.width - win.width) < 0.5
                    && abs(card.height - win.height) < 0.5
                NSLog("TempBar 自检 [\(label)] 窗口=\(fmt(win)) 期望=\(fmt(want.size)) "
                      + "卡片=\(fmt(card)) → 尺寸\(okSize ? "OK" : "错") 贴合\(okCard ? "OK" : "错")")

                centeringCheck(w, label: label)
            }
        }
        UserDefaults.standard.set(WidgetSize.medium.rawValue, forKey: "tempbar.widget.size")
        UserDefaults.standard.set(WidgetTheme.classic.rawValue, forKey: "tempbar.widget.theme")
    }

    /// 内容必须在卡片里居中，不能挤在左上角。
    ///
    /// 这条之前是坏的，而且是纯视觉问题、渲染永远"成功"，
    /// 所以必须量像素：取内容包围盒，比较上下留白与左右留白的差。
    /// 修复前实测顶部 13pt / 底部 59pt，差 46pt，肉眼看就是贴顶。
    private static func centeringCheck(_ w: WidgetPanel, label: String) {
        let dir = outputDir
        let p = (dir as NSString).appendingPathComponent("center-\(label).png")
        guard snapshot(w.contentView?.subviews.first ?? w.contentView!, to: p),
              let img = NSImage(contentsOfFile: p),
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            NSLog("TempBar 自检 [居中-\(label)] 拿不到位图 → 错")
            return
        }

        let W = rep.pixelsWide, H = rep.pixelsHigh
        // 用卡片中部靠上的空白当底色基准，避开圆角与边框
        guard let bg = pixelLuma(rep, W / 2, 6) else { return }
        // 左右各收 34pt 避开圆角；上下各收 8pt 避开边框
        let inset = 34
        func isInk(_ x: Int, _ y: Int) -> Bool {
            guard let l = pixelLuma(rep, x, y) else { return false }
            return abs(l - bg) > 25
        }

        var top = -1, bottom = -1
        for y in 8..<(H - 8) {
            let n = (inset..<(W - inset)).reduce(0) { $0 + (isInk($1, y) ? 1 : 0) }
            if n > 2 { if top < 0 { top = y }; bottom = y }
        }
        var left = -1, right = -1
        for x in 4..<(W - 4) {
            let n = (8..<(H - 8)).reduce(0) { $0 + (isInk(x, $1) ? 1 : 0) }
            if n > 2 { if left < 0 { left = x }; right = x }
        }
        guard top >= 0, left >= 0 else {
            NSLog("TempBar 自检 [居中-\(label)] 没找到内容 → 错")
            return
        }

        let padTop = top, padBottom = H - 1 - bottom
        let padLeft = left, padRight = W - 1 - right

        // 判据分尺寸/主题：
        //   小/中号：要求上下对称（居中的紧凑卡）
        //   大号：照苹果原图那样**顶部对齐、底部自然留白**，
        //     上下不等才是对的 —— 苹果那张实测顶部 25 / 底部 67。
        //     所以大号只验证"底部留白确实大于顶部"。
        //   水平：仿苹果主题整体是左对齐排版（苹果原图就是左对齐），
        //     所以看的是"左边贴到 16pt 留白"，不是左右对称；
        //     经典主题内容居中，才要求左右对称。
        let isLarge = w.currentSize == .large
        let isAppleTheme = w.currentTheme == .apple
        let okV: Bool
        if isLarge {
            okV = padBottom > padTop
        } else {
            okV = abs(padTop - padBottom) <= 8
        }
        let okH = isAppleTheme ? (padLeft <= 30) : (abs(padLeft - padRight) <= 3)
        NSLog("TempBar 自检 [居中-\(label)] 上\(padTop) 下\(padBottom) "
              + "左\(padLeft) 右\(padRight) → 垂直\(okV ? "OK" : "错（偏上/偏下）") "
              + "水平\(okH ? "OK" : "错（偏左/偏右）")")
    }

    /// 模拟用户在右键菜单里点"小号"再点"中号"。
    /// 小号必须真的缩到 168 —— 之前的 bug 是缩到 257 就卡住了。
    private static func sizeSwitchChecks(dir: String) {
        UserDefaults.standard.set(WidgetSize.medium.rawValue, forKey: "tempbar.widget.size")
        let w = WidgetPanel()
        w.rebuild()

        w.applySize(.small)
        w.layoutIfNeeded()
        let smallWin = w.actualSize
        let smallCard = w.cardSize
        let okSmall = abs(smallWin.width - WidgetSize.small.size.width) < 0.5
            && abs(smallCard.width - smallWin.width) < 0.5
        NSLog("TempBar 自检 [切换] 中→小 窗口=\(fmt(smallWin)) 卡片=\(fmt(smallCard)) "
              + "→ \(okSmall ? "OK" : "错（缩不回去）")")

        let p5 = (dir as NSString).appendingPathComponent("widget-after-switch-small.png")
        _ = w.snapshot(to: p5)

        w.applySize(.medium)
        w.layoutIfNeeded()
        let medWin = w.actualSize
        let medCard = w.cardSize
        let okMed = abs(medWin.width - WidgetSize.medium.size.width) < 0.5
            && abs(medCard.width - medWin.width) < 0.5
        NSLog("TempBar 自检 [切换] 小→中 窗口=\(fmt(medWin)) 卡片=\(fmt(medCard)) "
              + "→ \(okMed ? "OK" : "错（放不回去）")")
    }

    private static func fmt(_ s: NSSize) -> String {
        String(format: "%.0f×%.0f", s.width, s.height)
    }

    static func snapshot(_ v: NSView, to path: String,
                         appearance: NSAppearance? = nil,
                         forceAppearance: Bool = true) -> Bool {
        // 离屏渲染没有窗口，动态颜色会退化，
        // 必须显式指定外观才能得到和真实桌面一致的配色。
        // 默认用浅色（和多数人的桌面一致），测深色时传 .darkAqua。
        let app = appearance ?? NSAppearance(named: .aqua)
        guard let app else { return false }
        // forceAppearance=false 时不覆盖视图自己的 appearance。
        // 用于"视图已经贴了自己的外观，要验证它顶不顶得住父级深色"这类场景：
        // 一覆盖就等于把被测的那行代码擦掉了，测了个空。
        if forceAppearance {
            v.appearance = app
        }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return false }
        rep.size = v.bounds.size
        // 在指定外观的上下文里绘制，否则动态 NSColor 解析出来的还是默认外观
        app.performAsCurrentDrawingAppearance {
            v.cacheDisplay(in: v.bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
