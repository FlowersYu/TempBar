import Cocoa

/// 菜单栏面板：点顶部图标弹出的详情视图。
/// 用 NSPopover 而不是普通窗口，跟随系统外观、点外部自动收起，符合菜单栏工具的惯例。
final class StatusPanel: NSViewController {

    private var tempLabel: NSTextField!
    private var humLabel: NSTextField!
    private var nameLabel: NSTextField!
    private var chart: Sparkline!
    private var rangeLabel: NSTextField!
    private var batLabel: NSTextField!
    private var rssiLabel: NSTextField!
    private var updatedLabel: NSTextField!
    private var statusDot: NSView!
    private var devicePopup: NSPopUpButton!
    private var refreshTimer: Timer?

    private let width: CGFloat = 292

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 300))
        root.translatesAutoresizingMaskIntoConstraints = false
        // 面板固定浅色，不跟随系统深浅色。
        //
        // 用户反馈：跟随系统切换之后面板内外配色对不上，很难看。
        // 这里钉在视图自身而不是只在 App 里设 popover.appearance，
        // 原因是 popover 只在真正弹出时才存在，视图属性则任何情况下都生效，
        // 也才能被自检覆盖到（见 SelfTest.menuPanelLightCheck）。
        // 想恢复跟随系统，删掉 appearance 这行和下面的 wantsLayer 底色即可。
        root.appearance = NSAppearance(named: .aqua)

        // 光固定 appearance 还不够：popover 的背景是系统画的，
        // 深色系统下那块深灰框会露在浅色内容外围，看起来就很怪。
        // 给根视图铺一层不透明浅色，把系统那层盖住。
        // 圆角与箭头由 NSPopover 自己裁剪，这里不用管。
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            root.widthAnchor.constraint(equalToConstant: width)
        ])

        // --- 设备名 + 状态点
        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.spacing = 5
        nameRow.alignment = .centerY

        statusDot = NSView()
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        statusDot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        nameLabel = NSTextField(labelWithString: "等待设备")
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor

        nameRow.addArrangedSubview(statusDot)
        nameRow.addArrangedSubview(nameLabel)

        // --- 主读数
        let mainRow = NSStackView()
        mainRow.orientation = .horizontal
        mainRow.alignment = .bottom
        mainRow.spacing = 3

        tempLabel = NSTextField(labelWithString: "--")
        tempLabel.font = .systemFont(ofSize: 40, weight: .medium)
        tempLabel.textColor = .labelColor

        let deg = NSTextField(labelWithString: "°C")
        deg.font = .systemFont(ofSize: 16)
        deg.textColor = .tertiaryLabelColor

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        humLabel = NSTextField(labelWithString: "--%")
        humLabel.font = .systemFont(ofSize: 20, weight: .medium)
        humLabel.textColor = .systemBlue

        mainRow.addArrangedSubview(tempLabel)
        mainRow.addArrangedSubview(deg)
        mainRow.addArrangedSubview(spacer)
        mainRow.addArrangedSubview(humLabel)

        // --- 曲线卡片
        let chartCard = CardView()
        chartCard.radius = 8
        chartCard.subtle = true
        chartCard.borderWidth = 0
        chartCard.translatesAutoresizingMaskIntoConstraints = false

        let chartStack = NSStackView()
        chartStack.orientation = .vertical
        chartStack.alignment = .leading
        chartStack.spacing = 4
        chartStack.translatesAutoresizingMaskIntoConstraints = false
        chartCard.addSubview(chartStack)

        let chartHead = NSStackView()
        chartHead.orientation = .horizontal
        chartHead.distribution = .equalSpacing

        let chartTitle = NSTextField(labelWithString: "近 24 小时")
        chartTitle.font = .systemFont(ofSize: 10)
        chartTitle.textColor = .secondaryLabelColor

        rangeLabel = NSTextField(labelWithString: "")
        rangeLabel.font = .systemFont(ofSize: 10)
        rangeLabel.textColor = .tertiaryLabelColor

        chartHead.addArrangedSubview(chartTitle)
        chartHead.addArrangedSubview(rangeLabel)

        chart = Sparkline()
        chart.lineColor = .systemBlue
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 44).isActive = true

        chartStack.addArrangedSubview(chartHead)
        chartStack.addArrangedSubview(chart)

        NSLayoutConstraint.activate([
            chartStack.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 10),
            chartStack.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -10),
            chartStack.topAnchor.constraint(equalTo: chartCard.topAnchor, constant: 8),
            chartStack.bottomAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: -8),
            chartHead.widthAnchor.constraint(equalTo: chartStack.widthAnchor),
            chart.widthAnchor.constraint(equalTo: chartStack.widthAnchor)
        ])

        // --- 两项小指标
        // 原先是三格：电量 / 电压 / 信号。
        // 电压那一格永远是 "--"：抓过真实广播字节
        // （40 00 44 01 4e 02 3f 09 03 36 0d），里面只有
        // packet id、电量、温度、湿度四个 object，没有 0x0C（电压）。
        // 是固件没勾选电压上报，客户端解不出来，留着只是给人看个空值。
        // 所以直接去掉，改成两格平分 —— 每格更宽，数字也更好认。
        let metrics = NSStackView()
        metrics.orientation = .horizontal
        metrics.distribution = .fillEqually
        metrics.spacing = 8

        let batCell = makeMetricCell(title: "电量", value: "--")
        batLabel = batCell.1
        let rssiCell = makeMetricCell(title: "信号", value: "--")
        rssiLabel = rssiCell.1

        metrics.addArrangedSubview(batCell.0)
        metrics.addArrangedSubview(rssiCell.0)

        // --- 底部
        let sep = NSBox()
        sep.boxType = .separator

        let footRow = NSStackView()
        footRow.orientation = .horizontal
        footRow.distribution = .equalSpacing

        updatedLabel = NSTextField(labelWithString: "尚未收到数据")
        updatedLabel.font = .systemFont(ofSize: 10)
        updatedLabel.textColor = .tertiaryLabelColor

        let settingsBtn = NSButton(title: "设置", target: self, action: #selector(openSettings))
        settingsBtn.bezelStyle = .inline
        settingsBtn.isBordered = false
        settingsBtn.contentTintColor = .controlAccentColor
        settingsBtn.font = .systemFont(ofSize: 10)

        let quitBtn = NSButton(title: "退出", target: self, action: #selector(quit))
        quitBtn.bezelStyle = .inline
        quitBtn.isBordered = false
        quitBtn.contentTintColor = .secondaryLabelColor
        quitBtn.font = .systemFont(ofSize: 10)

        footRow.addArrangedSubview(updatedLabel)
        footRow.addArrangedSubview(settingsBtn)
        footRow.addArrangedSubview(quitBtn)

        // --- 多设备切换（只有一台时隐藏）
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        devicePopup.isHidden = true
        devicePopup.font = .systemFont(ofSize: 11)

        stack.addArrangedSubview(nameRow)
        stack.addArrangedSubview(mainRow)
        stack.addArrangedSubview(chartCard)
        stack.addArrangedSubview(metrics)
        stack.addArrangedSubview(devicePopup)
        stack.addArrangedSubview(sep)
        stack.addArrangedSubview(footRow)

        let fullWidth: [NSView] = [mainRow, chartCard, metrics, devicePopup, sep, footRow]
        for v in fullWidth {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        view = root

        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
        refresh()
    }

    private func makeMetricCell(title: String, value: String) -> (NSView, NSTextField) {
        let card = CardView()
        card.radius = 6
        card.subtle = true
        card.borderWidth = 0

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 9)
        t.textColor = .tertiaryLabelColor

        let v = NSTextField(labelWithString: value)
        v.font = .systemFont(ofSize: 13, weight: .medium)
        v.textColor = .labelColor

        stack.addArrangedSubview(t)
        stack.addArrangedSubview(v)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6)
        ])
        return (card, v)
    }

    // MARK: 刷新

    func refresh() {
        // 视图还没加载时（比如首条广播先于面板创建到达）直接跳过，
        // 否则访问未初始化的控件会崩。真正显示时会再刷一次。
        guard isViewLoaded else { return }

        let state = AppState.shared
        let devs = state.sortedDevices
        let scan = Scanner.shared

        // 设备切换器
        if devs.count > 1 {
            devicePopup.isHidden = false
            let titles = devs.map { "\($0.displayName)  ·  \(fmt1($0.reading.temperature))°" }
            if devicePopup.itemTitles != titles {
                devicePopup.removeAllItems()
                devicePopup.addItems(withTitles: titles)
            }
            if let p = state.primary, let idx = devs.firstIndex(where: { $0.id == p.id }) {
                devicePopup.selectItem(at: idx)
            }
        } else {
            devicePopup.isHidden = true
        }

        guard let dev = state.primary else {
            nameLabel.stringValue = scan.bluetoothOff ? "蓝牙已关闭" : "正在搜索附近设备…"
            statusDot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            tempLabel.stringValue = "--"
            humLabel.stringValue = "--%"
            chart.points = []
            rangeLabel.stringValue = ""
            updatedLabel.stringValue = scan.bluetoothOff
                ? "请在系统设置中打开蓝牙"
                : "监听中，请确认温度计在 10 米内"
            return
        }

        nameLabel.stringValue = dev.displayName
        let stale = dev.isStale
        statusDot.layer?.backgroundColor = (stale
            ? NSColor.systemOrange
            : NSColor.systemGreen).cgColor

        tempLabel.stringValue = dev.reading.temperature.map { String(format: "%.1f", $0) } ?? "--"
        humLabel.stringValue = dev.reading.humidity.map { String(format: "%.0f%%", $0) } ?? "--%"

        let samples = state.history(of: dev, hours: 24)
        let temps = samples.compactMap(\.temp)
        chart.points = Array(temps.suffix(144))
        if temps.isEmpty {
            rangeLabel.stringValue = "暂无数据"
        } else {
            rangeLabel.stringValue = "\(fmt1(temps.min()))° — \(fmt1(temps.max()))°"
        }

        batLabel.stringValue = dev.reading.battery.map { "\($0)%" } ?? "--"
        rssiLabel.stringValue = "\(dev.rssi)"

        updatedLabel.stringValue = stale
            ? "\(ago(dev.lastSeen)) · 设备可能已离开"
            : "\(ago(dev.lastSeen))更新"
    }

    @objc private func deviceChanged() {
        let idx = devicePopup.indexOfSelectedItem
        let devs = AppState.shared.sortedDevices
        guard idx >= 0, idx < devs.count else { return }
        AppState.shared.primaryID = devs[idx].id
    }

    @objc private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
