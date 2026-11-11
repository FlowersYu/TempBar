import Cocoa

@main
struct Main {
    static func main() {
        // 自检模式必须先把数据目录改到沙盒位置，
        // 否则 AppState.shared 初始化时就已经用真实的 state.json 了，
        // 测试会把伪造设备写进用户的真实数据里。
        if ProcessInfo.processInfo.environment["TEMPBAR_SELFTEST"] == "1" {
            setenv("TEMPBAR_STATE_DIR", "TempBarSelfTest", 1)
        }

        migrateDefaultsIfNeeded()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // 只要菜单栏，不要 Dock 图标
        app.run()
    }

    /// 换 bundle id（为了绕开坏掉的 TCC 授权）会让 UserDefaults 换一个域，
    /// 用户的尺寸、位置、阈值、置顶这些设置会"突然消失"。
    /// 这里从旧域搬一次。
    private static func migrateDefaultsIfNeeded() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "tempbar.migrated.v3") else { return }
        d.set(true, forKey: "tempbar.migrated.v3")

        let oldSuite = UserDefaults(suiteName: "local.tempbar.app")
        guard let old = oldSuite?.dictionaryRepresentation() else { return }
        for key in ["tempbar.widget.pos", "tempbar.widget.size", "tempbar.widget.pinned",
                    "tempbar.widget.visible", "tempbar.thresholds", "tempbar.demo"] {
            // 新域已有值就不覆盖，避免把用户新调的设置冲掉
            if d.object(forKey: key) == nil, let v = old[key] {
                d.set(v, forKey: key)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var statusPanel: StatusPanel!
    private var widget: WidgetPanel!
    private var settingsWC: SettingsWindowController?
    private var refreshTimer: Timer?

    /// 给设置窗口用：改尺寸/主题时要拿到同一个小组件实例。
    /// 新建一个 WidgetPanel 是不行的 —— 那会在屏幕上多出一张卡。
    var widgetInstance: WidgetPanel? { widget }

    static let widgetKey = "tempbar.widget.visible"

    /// 小组件是否应该显示（用户在菜单里关掉后不再自动弹）
    static var widgetVisible: Bool {
        get {
            if UserDefaults.standard.object(forKey: widgetKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: widgetKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: widgetKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.enabled {
            SelfTest.run()
            return
        }

        setupStatusItem()
        setupPopover()

        // 先把 UI 建好再开数据源，否则首条广播到达时 widget 还是 nil，
        // onChange 里的 widget.rebuild() 会炸（演示模式每 3 秒一条，必现）
        widget = WidgetPanel()
        if Self.widgetVisible { widget.showWidget() }

        AppState.shared.onChange = { [weak self] in
            self?.refreshStatus()
            self?.widget?.rebuild()
            self?.statusPanel?.refresh()
            self?.refreshSettingsIfVisible()
        }

        // 调试：没有真实设备时用模拟数据走一遍完整链路
        if Self.demoMode {
            startDemoFeed()
        } else {
            // 首次启动给蓝牙授权一点时间，延后 0.6 秒再开扫描
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                Scanner.shared.onStateChange = { [weak self] in self?.refreshStatus() }
                Scanner.shared.start()
                _ = self
            }
        }

        // 菜单栏文字每秒刷一次，让"几分钟前"这类相对时间能自己走
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)

        refreshStatus()

        // 每天清一次长期不出现的幽灵设备
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            AppState.shared.dropGhosts()
        }

        // 启动时清一次历史里的越界采样。
        // 旧版本存进 state.json 的 236° 数据不会自己消失，
        // 不清理的话曲线纵轴永远被撑爆，最高/最低也会算成 236。
        AppState.shared.scrubOutOfRangeHistory()

        // 系统睡眠唤醒后蓝牙扫描可能被系统掐断，这里主动重启一次
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(wakeUp),
            name: NSWorkspace.didWakeNotification, object: nil
        )
    }

    @objc private func wakeUp() {
        Scanner.shared.restartScan(allDevices: false)
    }

    /// 演示模式：没有真实设备时伪造广播，走和真实蓝牙完全相同的入口。
    /// 用 UserDefaults 开关而不是环境变量，因为要通过 `open` 启动 bundle 才能拿到
    /// 蓝牙权限；直接跑二进制会被 TCC 直接 SIGABRT。
    static var demoMode: Bool {
        ProcessInfo.processInfo.environment["TEMPBAR_DEMO"] == "1"
            || UserDefaults.standard.bool(forKey: "tempbar.demo")
    }

    private func startDemoFeed() {
        var pid = 0
        var t = 22.8
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            pid += 1
            t += Double.random(in: -0.25...0.28)
            t = min(max(t, 20.5), 28.5)
            var r = Reading()
            r.temperature = (t * 100).rounded() / 100
            r.humidity = (34 + Double.random(in: -15...15) / 10).rounded() / 10
            r.battery = 92
            r.voltage = 2.995
            r.packetID = pid % 256
            AppState.shared.ingest(id: "DEMO-DEVICE", name: "温湿度计",
                                   reading: r, rssi: -55)
            AlertCenter.shared.evaluate(reading: r, deviceName: "温湿度计")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.persist()
    }

    // MARK: 菜单栏

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "thermometer.medium",
                               accessibilityDescription: "温度")
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(statusClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            statusPanel.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func setupPopover() {
        statusPanel = StatusPanel()
        popover = NSPopover()
        popover.contentViewController = statusPanel
        popover.behavior = .transient
        popover.animates = false

        // 菜单栏面板固定浅色，不跟随系统深浅色。
        //
        // 原因：popover 背后那块"尾巴"和圆角是系统画的，系统深色下是深灰，
        // 但面板内部的卡片、分隔线用的是我们自己的动态色，两边一深一浅，
        // 切过一次外观之后边界就很怪。固定成浅色让内外始终同一套配色。
        // 想改成跟随系统，把下面两行删掉即可。
        popover.appearance = NSAppearance(named: .aqua)
        statusPanel.view.appearance = NSAppearance(named: .aqua)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let widgetItem = NSMenuItem(title: "显示桌面小组件",
                                    action: #selector(toggleWidgetMenu), keyEquivalent: "")
        widgetItem.state = (widget?.isVisibleNow ?? false) ? .on : .off
        widgetItem.target = self
        menu.addItem(widgetItem)

        let settingsItem = NSMenuItem(title: "设置…",
                                      action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let updateItem = NSMenuItem(title: "检查更新…",
                                    action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 TempBar",
                                  action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // 用完清掉，否则下次左键点也会弹菜单
        statusItem.menu = nil
    }

    @objc private func toggleWidgetMenu() {
        let visible = widget?.isVisibleNow ?? false
        setWidgetVisible(!visible)
    }

    @objc func checkForUpdates() {
        Updater.shared.check(interactive: true)
    }

    func setWidgetVisible(_ visible: Bool) {
        Self.widgetVisible = visible
        if visible { widget.showWidget() } else { widget.orderOut(nil) }
        syncWidgetMenuState()
    }

    func syncWidgetMenuState() {
        // 设置窗口若正开着，让里面的显示开关跟右键菜单的变化对齐
        if let s = settingsWC, s.window?.isVisible == true {
            s.syncWidgetSwitch()
        }
    }

    /// 设置窗口开着时，设备列表和改名框要跟着广播更新，
    /// 否则插上温度计后下拉里还是"暂未发现设备"
    private func refreshSettingsIfVisible() {
        guard let s = settingsWC, s.window?.isVisible == true else { return }
        s.reloadDevices()
    }

    // MARK: 设置

    /// 把 App 真正顶到最前面。
    ///
    /// 我们是 accessory app（没有 Dock 图标），系统对它的前台激活比普通 App 更保守：
    /// 只 `makeKeyAndOrderFront` 的话，窗口画出来了但没拿到键盘焦点，
    /// 表现就是"设置里的输入框点了没反应、打不了字"——同事装完改不了名字就是这个。
    /// macOS 14 起 `activate(ignoringOtherApps:)` 被标废弃，新接口是无参 `activate()`，
    /// 两个都叫一次，旧系统走前者、新系统走后者。
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        }
    }

    @objc func openSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController()
        }
        Self.bringToFront()
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
        settingsWC?.window?.orderFrontRegardless()

        // 首次激活是异步的，系统有时会把这一轮的 makeKey 吃掉，
        // 结果窗口在前台但输入框打不了字。下一轮回调补一次 makeKey，
        // 代价几乎为零。
        DispatchQueue.main.async { [weak self] in
            self?.settingsWC?.window?.makeKey()
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: 菜单栏文字

    func refreshStatus() {
        guard let button = statusItem.button else { return }
        let state = AppState.shared

        if let dev = state.primary, let t = dev.reading.temperature, !dev.isStale {
            button.title = " " + String(format: "%.1f°", t)
            button.contentTintColor = nil
        } else if Scanner.shared.bluetoothOff {
            button.title = " 蓝牙关"
            button.contentTintColor = .systemOrange
        } else if state.primary == nil {
            button.title = " 搜索中"
            button.contentTintColor = .secondaryLabelColor
        } else {
            button.title = " --°"
            button.contentTintColor = .secondaryLabelColor
        }
    }
}
