import Cocoa
import ServiceManagement

/// 设置窗口。用代码布局而不是 SwiftUI，为了和其余部分保持一致，
/// 也避免 SwiftUI 在无沙盒 + 无桌面权限的老版本 macOS 上出问题。
final class SettingsWindowController: NSWindowController {

    private var thresholdSwitch: NSSwitch!
    private var minTempField: NSTextField!
    private var maxTempField: NSTextField!
    private var minHumField: NSTextField!
    private var maxHumField: NSTextField!
    private var loginSwitch: NSSwitch!
    private var widgetSwitch: NSSwitch!
    private var devicePopup: NSPopUpButton!
    private var sizePopup: NSPopUpButton!
    private var themePopup: NSPopUpButton!
    private var updateButton: NSButton!
    /// 内部可见：自检要直接驱动真实的输入框，而不是绕过 UI 调 state
    var nameField: NSTextField!
    private var nameHint: NSTextField!
    private var resetNameBtn: NSButton!
    private var scrollView: NSScrollView!

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "TempBar 设置"
        win.center()
        win.isReleasedWhenClosed = false
        self.init(window: win)
        buildUI()
        loadValues()

        // 右键菜单也能改尺寸/主题，改完这里必须跟着变。
        // 之前只在 loadValues 里读一次，所以设置窗口开着时从菜单改尺寸，
        // 下拉框还是旧选中项 —— 用户再点一下就又改回去了。
        NotificationCenter.default.addObserver(
            self, selector: #selector(widgetStyleChangedExternally),
            name: .tempbarWidgetStyleChanged, object: nil
        )
    }

    /// 设置窗口每次显示都回到顶部。
    ///
    /// 之前打开时是停在中间的「软件更新 / 检查更新」那一行（滚动区原点落在
    /// 文档底部），每次都要手动往上滚才能看到「常规」。根因是 documentView
    /// 不是 flipped，初始滚动原点在文档左下角。这里双保险：文档视图改成
    /// flipped，显示时再显式滚到原点。
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.contentView?.layoutSubtreeIfNeeded()
        scrollToTop()
    }

    func scrollToTop() {
        guard let scroll = scrollView, scroll.documentView != nil else { return }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// 当前滚动偏移，自检用来确认"打开时在最上面"
    var scrollOffsetY: CGFloat {
        scrollView?.contentView.bounds.origin.y ?? 0
    }

    /// 滚动区的文档视图是否 flipped —— 打开时停不停止在顶部就取决于它
    var documentIsFlipped: Bool {
        scrollView?.documentView?.isFlipped ?? false
    }

    /// 自检用：两个下拉当前选中的标题
    var selectedSizeTitle: String { sizePopup?.titleOfSelectedItem ?? "" }
    var selectedThemeTitle: String { themePopup?.titleOfSelectedItem ?? "" }

    @objc private func widgetStyleChangedExternally() {
        syncWidgetStyle()
    }

    private func buildUI() {
        guard let win = window else { return }
        let root = NSView()
        win.contentView = root

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)
        scrollView = scroll

        // documentView 必须是 flipped 的。
        //
        // 普通 NSView 的原点在左下角，滚动区的初始滚动原点 (0,0) 落的是
        // **文档底部**，内容比窗口高的时候一打开就停在中间 ——
        // 用户看到的就是"滚轮默认不在最上面，停在检查版本那一行"。
        // 翻过来之后 (0,0) 就是左上角，打开即顶部。
        let content = FlippedView()
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = content

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            content.widthAnchor.constraint(equalTo: scroll.widthAnchor)
        ])
        // 内容高度由 stack 自己决定（底部贴住 content），
        // 但宽度必须锁死在可视区宽度，不能反过来被内容撑大。
        // 之前少了这一步，6 列的温度/湿度网格把内容撑到 514pt，
        // 窗口只有 420pt，右侧输入框直接被裁掉。
        let stackW = stack.widthAnchor.constraint(
            equalTo: content.widthAnchor, constant: -48)
        stackW.priority = .required
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            stackW
        ])
        // content 的高度跟着 stack 走，否则 documentView 高度会是 0
        content.heightAnchor.constraint(equalTo: stack.heightAnchor,
                                        constant: 40).isActive = true

        // ===== 常规
        stack.addArrangedSubview(sectionTitle("常规"))

        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginChanged)
        stack.addArrangedSubview(row(
            title: "开机自动启动",
            subtitle: "登录后在后台运行，菜单栏直接可看",
            control: loginSwitch
        ))

        widgetSwitch = NSSwitch()
        widgetSwitch.target = self
        widgetSwitch.action = #selector(widgetToggled)
        stack.addArrangedSubview(row(
            title: "显示桌面小组件",
            subtitle: "关闭后仍可通过菜单栏查看温度",
            control: widgetSwitch
        ))

        // 尺寸和主题是两个独立维度，所以给两个下拉框，
        // 不是「小号/中号/大号(仿苹果)」那种把主题焊死在尺寸上的单选。
        sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        sizePopup.font = .systemFont(ofSize: 12)
        for s in WidgetSize.allCases {
            sizePopup.addItem(withTitle: s.title)
            sizePopup.lastItem?.representedObject = s.rawValue
        }
        sizePopup.target = self
        sizePopup.action = #selector(widgetStyleChanged)
        stack.addArrangedSubview(row(
            title: "小组件尺寸",
            subtitle: "小 / 中 / 大",
            control: sizePopup
        ))

        themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        themePopup.font = .systemFont(ofSize: 12)
        for t in WidgetTheme.allCases {
            themePopup.addItem(withTitle: t.title)
            themePopup.lastItem?.representedObject = t.rawValue
        }
        themePopup.target = self
        themePopup.action = #selector(widgetStyleChanged)
        stack.addArrangedSubview(row(
            title: "小组件主题",
            subtitle: "仿苹果固定紫蓝渐变",
            control: themePopup
        ))

        // 版本 / 更新
        //
        // 版本号写在 subtitle 里而不是标题：标题位置留给「软件更新」这类
        // 动作名，和上面几行的排版保持一致；版本号是随时会变的信息，放边上。
        updateButton = NSButton(title: "检查更新", target: self,
                                action: #selector(checkUpdates))
        updateButton.bezelStyle = .rounded
        updateButton.controlSize = .small
        stack.addArrangedSubview(row(
            title: "软件更新",
            subtitle: "当前 \(Updater.displayVersion)",
            control: updateButton
        ))

        stack.addArrangedSubview(divider())

        // ===== 设备
        stack.addArrangedSubview(sectionTitle("设备"))

        // 多设备时才需要选择器
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.target = self
        devicePopup.action = #selector(deviceSelectionChanged)
        devicePopup.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(row(
            title: "当前设备",
            subtitle: "小组件和菜单栏显示这一台",
            control: devicePopup
        ))

        nameField = NSTextField(string: "")
        nameField.font = .systemFont(ofSize: 13)
        nameField.placeholderString = "起个名字，如「办公室温湿度计」"
        nameField.target = self
        nameField.action = #selector(commitNameField)
        nameField.delegate = self
        // 宽度不要写死：写死 200 会和左边的副标题一起挤爆行宽。
        // 给一个保底值 + 让它可以被拉伸即可。
        let nameW = nameField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150)
        nameW.priority = .defaultHigh
        nameW.isActive = true
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameStack = NSStackView()
        nameStack.orientation = .horizontal
        nameStack.spacing = 6
        nameStack.addArrangedSubview(nameField)

        resetNameBtn = NSButton(title: "恢复", target: self, action: #selector(resetName))
        resetNameBtn.bezelStyle = .rounded
        resetNameBtn.toolTip = "恢复成温度计广播的原始名字"
        nameStack.addArrangedSubview(resetNameBtn)

        stack.addArrangedSubview(row(
            title: "显示名称",
            subtitle: "只在本机生效",
            control: nameStack
        ))

        nameHint = NSTextField(wrappingLabelWithString: "")
        nameHint.font = .systemFont(ofSize: 11)
        nameHint.textColor = .tertiaryLabelColor
        nameHint.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(nameHint)

        stack.addArrangedSubview(divider())

        // ===== 提醒
        stack.addArrangedSubview(sectionTitle("温度提醒"))

        thresholdSwitch = NSSwitch()
        thresholdSwitch.target = self
        thresholdSwitch.action = #selector(thresholdToggled)
        stack.addArrangedSubview(row(
            title: "超出范围时通知我",
            subtitle: "同一次超限 30 分钟内只提醒一次",
            control: thresholdSwitch
        ))

        // 温度/湿度上下限：4 个数字 + 4 个单位，排成 2 组而不是 6 列一张大表。
        // 6 列表格在 420pt 窗口里必然会挤（实测要 470pt），
        // 单位符号还会被推到最右边，看着像跟数字分了家。
        func limitGroup(_ title: String, _ unit: String,
                        _ a: inout NSTextField!, _ pa: String,
                        _ b: inout NSTextField!, _ pb: String) -> NSView {
            let l1 = label(title + "下限")
            let l2 = label(title + "上限")
            let u1 = label(unit)
            let u2 = label(unit)
            let row = NSStackView(views: [l1, field(&a, pa), u1, l2, field(&b, pb), u2])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            // 单位紧贴数字，不要把空隙都塞在数字和单位之间
            row.setCustomSpacing(14, after: u1)
            return row
        }

        stack.addArrangedSubview(limitGroup("温度", "°C",
                                            &minTempField, "18", &maxTempField, "28"))
        stack.addArrangedSubview(limitGroup("湿度", "%",
                                            &minHumField, "30", &maxHumField, "70"))

        for f in [minTempField, maxTempField, minHumField, maxHumField] {
            f?.target = self
            f?.action = #selector(thresholdsChanged)
        }

        stack.addArrangedSubview(divider())

        // ===== 诊断
        stack.addArrangedSubview(sectionTitle("诊断"))

        let diagRow = NSStackView()
        diagRow.orientation = .horizontal
        diagRow.spacing = 8

        let copyBtn = NSButton(title: "复制设备列表", target: self, action: #selector(copyDevices))
        copyBtn.bezelStyle = .rounded
        let rescanBtn = NSButton(title: "重新扫描", target: self, action: #selector(rescan))
        rescanBtn.bezelStyle = .rounded

        diagRow.addArrangedSubview(copyBtn)
        diagRow.addArrangedSubview(rescanBtn)
        stack.addArrangedSubview(diagRow)

        let hint = NSTextField(wrappingLabelWithString:
            "收不到数据时依次检查：① 蓝牙已打开 ② 温度计在 10 米内且中间别隔承重墙 ③ 温度计固件广播格式为 BTHome v2 且未开启加密 ④ 电池电量是否过低。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 360
        stack.addArrangedSubview(hint)

        for v in stack.arrangedSubviews {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    // MARK: 小零件

    private func sectionTitle(_ s: String) -> NSView {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 12)
        l.textColor = .secondaryLabelColor
        // 6 列的网格比窗口宽，标签必须肯让步
        l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return l
    }

    private func field(_ out: inout NSTextField!, _ placeholder: String) -> NSTextField {
        let f = NSTextField(string: placeholder)
        f.alignment = .right
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // 数字框宽度固定，不要被网格拉伸
        let w = f.widthAnchor.constraint(equalToConstant: 52)
        w.priority = .required
        w.isActive = true
        f.setContentCompressionResistancePriority(.required, for: .horizontal)
        out = f
        return f
    }

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func row(title: String, subtitle: String, control: NSView) -> NSView {
        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13)
        t.textColor = .labelColor

        // 副标题必须能换行 + 能被压缩。
        // 用 labelWithString 得到的是单行不可压缩标签，
        // "只在你这台电脑上生效，不影响温度计" 这一句会把整行顶到 466pt，
        // 结果内容区比窗口还宽，右边的输入框被裁掉。
        let s = NSTextField(wrappingLabelWithString: subtitle)
        s.font = .systemFont(ofSize: 11)
        s.textColor = .tertiaryLabelColor
        s.preferredMaxLayoutWidth = 200
        s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        text.addArrangedSubview(t)
        text.addArrangedSubview(s)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.addArrangedSubview(text)
        row.addArrangedSubview(spacer)
        row.addArrangedSubview(control)
        return row
    }

    // MARK: 状态

    private func loadValues() {
        let th = AppState.shared.thresholds
        thresholdSwitch.state = th.enabled ? .on : .off
        minTempField.stringValue = String(format: "%g", th.minTemp)
        maxTempField.stringValue = String(format: "%g", th.maxTemp)
        minHumField.stringValue = String(format: "%g", th.minHum)
        maxHumField.stringValue = String(format: "%g", th.maxHum)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
        widgetSwitch.state = AppDelegate.widgetVisible ? .on : .off
        syncWidgetStyle()
        updateFieldEnabled()
        reloadDevices()
    }

    /// 把小组件的尺寸/主题下拉同步成当前实际值。
    /// 右键菜单也能改这两项，所以从菜单改完再打开设置必须显示新值，
    /// 否则下拉框里是旧选中项，用户再点一下反而改回去了。
    func syncWidgetStyle() {
        guard isWindowLoaded else { return }
        let sizeRaw = UserDefaults.standard.string(forKey: "tempbar.widget.size")
        let themeRaw = UserDefaults.standard.string(forKey: "tempbar.widget.theme")

        // 兼容老存档：老版本会把 "apple" 存在尺寸键里
        var size = sizeRaw.flatMap(WidgetSize.init(rawValue:)) ?? .medium
        var theme = themeRaw.flatMap(WidgetTheme.init(rawValue:)) ?? .classic
        if sizeRaw == "apple" {
            size = .large
            theme = .apple
        }

        for i in 0..<sizePopup.numberOfItems {
            if (sizePopup.item(at: i)?.representedObject as? String) == size.rawValue {
                sizePopup.selectItem(at: i)
            }
        }
        for i in 0..<themePopup.numberOfItems {
            if (themePopup.item(at: i)?.representedObject as? String) == theme.rawValue {
                themePopup.selectItem(at: i)
            }
        }
    }

    @objc private func widgetStyleChanged() {
        let size = (sizePopup.selectedItem?.representedObject as? String)
            .flatMap(WidgetSize.init(rawValue:)) ?? .medium
        let theme = (themePopup.selectedItem?.representedObject as? String)
            .flatMap(WidgetTheme.init(rawValue:)) ?? .classic

        guard let widget = (NSApp.delegate as? AppDelegate)?.widgetInstance else { return }
        // 先换尺寸再换主题：applySize 内部会重建内容，
        // 而内容长什么样取决于主题，所以主题要在尺寸定下来之后再落。
        widget.applySize(size)
        widget.applyTheme(theme)
        // 走 delegate 而不是 widget.showWidget()：后者只把窗口显示出来，
        // UserDefaults 里的"要不要显示小组件"还是关着的，
        // 紧接着 syncWidgetSwitch 会把刚点开的开关又掰回去。
        (NSApp.delegate as? AppDelegate)?.setWidgetVisible(true)
        widgetSwitch.state = .on
        // 回写一次，防住"两个下拉同时改"时的竞态
        syncWidgetStyle()
    }

    @objc private func checkUpdates() {
        Updater.shared.check(interactive: true)
    }

    /// 刷新设备下拉和名字输入框
    func reloadDevices() {
        guard isWindowLoaded else { return }
        let devs = AppState.shared.sortedDevices
        let hasMultiple = devs.count > 1
        devicePopup.isEnabled = hasMultiple

        // 下拉项按设备 id 判断要不要重建。
        // 标题里带实时温度，每 10 秒就会变一次；如果拿标题做比较，
        // 每次广播都会 removeAllItems 重建，用户正在下拉时会被打断。
        let ids = devs.map(\.id)
        let currentIDs = (0..<devicePopup.numberOfItems).map {
            devicePopup.item(at: $0)?.representedObject as? String ?? ""
        }
        if ids != currentIDs {
            devicePopup.removeAllItems()
            if devs.isEmpty {
                devicePopup.addItem(withTitle: "暂未发现设备")
            } else {
                for d in devs {
                    devicePopup.addItem(withTitle: d.displayName)
                    devicePopup.lastItem?.representedObject = d.id
                }
            }
        } else {
            // id 没变，只就地更新标题，不动选项本身
            for (i, d) in devs.enumerated() where i < devicePopup.numberOfItems {
                devicePopup.item(at: i)?.title = "\(d.displayName) · \(fmt1(d.reading.temperature))°C"
            }
        }

        if devs.isEmpty {
            nameField.stringValue = ""
            nameField.isEnabled = false
            resetNameBtn.isEnabled = false
            nameHint.stringValue = "还没收到任何温度计的广播。确认蓝牙已打开、温度计在附近后稍等几秒。"
            return
        }

        // 选中项跟着 primary 走，但不要覆盖用户刚点选的那一项
        if devicePopup.indexOfSelectedItem < 0 {
            if let p = AppState.shared.primary, let idx = devs.firstIndex(where: { $0.id == p.id }) {
                devicePopup.selectItem(at: idx)
            } else {
                devicePopup.selectItem(at: 0)
            }
        }

        let cur = currentDevice()
        nameField.isEnabled = cur != nil
        resetNameBtn.isEnabled = cur?.hasCustomName ?? false

        // 正在输入时绝对不能改写输入框内容。
        // 这个方法会被每条广播触发的 onChange 调用（约 10 秒一次），
        // 不挡住的话用户打字打到一半就被冲掉了。
        if nameField.currentEditor() == nil {
            nameField.stringValue = cur?.customName ?? ""
        }

        if let c = cur {
            nameHint.stringValue = c.hasCustomName
                ? "已自定义。「恢复」可以退回原始名称「\(c.firmwareName)」。"
                : "原始名称「\(c.firmwareName)」。留空则一直使用原始名称。"
        }
    }

    private func currentDevice() -> Device? {
        if let id = devicePopup.selectedItem?.representedObject as? String,
           let d = AppState.shared.devices[id] {
            return d
        }
        return AppState.shared.primary
    }

    private func updateFieldEnabled() {
        let on = thresholdSwitch.state == .on
        for f in [minTempField, maxTempField, minHumField, maxHumField] {
            f?.isEnabled = on
        }
    }

    /// 外部（右键菜单）改了小组件开关时，把这里的开关同步过来
    func syncWidgetSwitch() {
        widgetSwitch.state = AppDelegate.widgetVisible ? .on : .off
    }

    @objc private func thresholdToggled() {
        updateFieldEnabled()
        thresholdsChanged()
    }

    @objc private func thresholdsChanged() {
        var th = AppState.shared.thresholds
        th.enabled = thresholdSwitch.state == .on
        if let v = Double(minTempField.stringValue) { th.minTemp = v }
        if let v = Double(maxTempField.stringValue) { th.maxTemp = v }
        if let v = Double(minHumField.stringValue) { th.minHum = v }
        if let v = Double(maxHumField.stringValue) { th.maxHum = v }
        // 上下限填反了就顺手纠正，不然判定逻辑会永远不触发
        if th.minTemp > th.maxTemp { swap(&th.minTemp, &th.maxTemp) }
        if th.minHum > th.maxHum { swap(&th.minHum, &th.maxHum) }
        AppState.shared.thresholds = th

        minTempField.stringValue = String(format: "%g", th.minTemp)
        maxTempField.stringValue = String(format: "%g", th.maxTemp)
        minHumField.stringValue = String(format: "%g", th.minHum)
        maxHumField.stringValue = String(format: "%g", th.maxHum)

        if th.enabled { AlertCenter.shared.requestPermission() }
    }

    @objc private func loginChanged() {
        LoginItem.set(enabled: loginSwitch.state == .on)
        loginSwitch.state = LoginItem.isEnabled ? .on : .off
    }

    @objc private func widgetToggled() {
        (NSApp.delegate as? AppDelegate)?
            .setWidgetVisible(widgetSwitch.state == .on)
    }

    @objc private func rescan() {
        Scanner.shared.restartScan(allDevices: false)
    }

    // MARK: 设备改名

    @objc private func deviceSelectionChanged() {
        // 用 representedObject 里的设备 id，不用下拉索引。
        // 索引会随"最近活跃时间"重排而失效，点 A 可能切到 B。
        guard let id = devicePopup.selectedItem?.representedObject as? String else { return }
        AppState.shared.primaryID = id
        reloadDevices()
    }

    /// 提交输入框里的名字。回车、失焦、以及对话框都走这一条路径。
    @objc func commitNameField() {
        guard let dev = currentDevice() else { return }
        AppState.shared.setCustomName(nameField.stringValue, for: dev.id)
        reloadDevices()
    }

    @objc private func resetName() {
        guard let dev = currentDevice() else { return }
        AppState.shared.setCustomName(nil, for: dev.id)
        reloadDevices()
    }

    @objc private func copyDevices() {
        let lines = AppState.shared.sortedDevices.map {
            "\($0.displayName)\tT=\(fmt1($0.reading.temperature))\tH=\(fmt0($0.reading.humidity))\tRSSI=\($0.rssi)\t\(ago($0.lastSeen))"
        }
        let text = lines.isEmpty ? "（未发现任何设备）" : lines.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - 改名输入框

extension SettingsWindowController: NSTextFieldDelegate {
    /// 输入完按 Tab 或点别处也要保存，不能只认回车。
    /// 用 controlTextDidEndEditing 而不是 didChange：后者每敲一个字就写盘，
    /// 会把输入法组字过程中的中间态也存进去。
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let f = obj.object as? NSTextField, f === nameField else { return }
        commitNameField()
    }
}

// MARK: - 重命名对话框

/// 小组件右键「重命名设备…」走这里的模态对话框。
///
/// 为什么不再只靠设置窗口里那个输入框：同事反馈"装完改不了名字"。
/// 设置窗口那条路径要先让 accessory app 拿到前台、再滚到设备区、
/// 再点中输入框才能打字，任何一步焦点没拿到，用户看到的就是"打不了字"。
/// 对话框是模态的，弹出时自己抢焦点，路径最短；而且没有设备时能直接
/// 说清"还没收到广播"，而不是丢一个灰掉的输入框给人猜。
enum RenamePrompt {
    static func show(deviceID: String? = nil) {
        let state = AppState.shared
        let dev = deviceID.flatMap { state.devices[$0] } ?? state.primary

        // 先抢前台，否则输入框看得见、打不了字
        AppDelegate.bringToFront()

        guard let dev else {
            let a = NSAlert()
            a.alertStyle = .informational
            a.messageText = "还没有收到温度计的数据"
            a.informativeText = "改名得先有一台温度计在广播。确认蓝牙已打开、"
                + "温度计在 10 米内，等菜单栏出现温度数字后再试。"
            a.addButton(withTitle: "好")
            a.runModal()
            return
        }

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = dev.customName ?? ""
        field.placeholderString = "如「办公室温湿度计」"
        field.font = .systemFont(ofSize: 13)

        let alert = NSAlert()
        alert.messageText = "重命名「\(dev.firmwareName)」"
        alert.informativeText = "只改这台电脑上显示的名字，不影响温度计本身。"
            + "留空即为恢复原始名称。"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        state.setCustomName(field.stringValue, for: dev.id)
    }
}

/// 设置窗口滚动区的文档视图。
/// 必须是 flipped：原点在左上角，滚动区初始位置才是"最上面"。
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 开机启动

/// 用 SMAppService 之前的老办法（LaunchAgent plist）会有权限和路径问题，
/// 这里直接用 macOS 13+ 的 SMAppService，干净且系统设置里可见。
enum LoginItem {
    static var isEnabled: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
    }

    static func set(enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("TempBar: 登录项设置失败 \(error)")
        }
    }
}
