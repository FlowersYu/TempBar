import Cocoa

/// 小组件尺寸。
///
/// 尺寸和主题是**两个独立维度**，不是绑在一起的枚举 ——
/// 之前把「大号」和「仿苹果」塞进同一个 case（`.apple`），
/// 结果就是选了仿苹果就必然是大号，换小号就必然掉回经典白卡，
/// 想「小号的仿苹果」这种组合根本表达不出来。
enum WidgetSize: String, Codable, CaseIterable {
    case small, medium, large

    /// 尺寸直接取 Apple HIG 的官方规范，不再自己拍。
    ///
    /// 之前是 168×152 / 340×152，两个都不在规范里：
    /// HIG（Widgets → Specifications → iOS dimensions）给的是
    ///   small  158×158
    ///   medium 338×158
    ///   large  338×354
    /// 我起初想从用户截图反推，但截图可能是 2x，量出来的像素除以 2
    /// 还得凑整数，误差会累积。官方表直接查得到，没有理由去猜。
    var size: NSSize {
        switch self {
        case .small: return NSSize(width: 158, height: 158)
        case .medium: return NSSize(width: 338, height: 158)
        case .large: return NSSize(width: 338, height: 354)
        }
    }

    /// 圆角。
    ///
    /// HIG 只说"用 ContainerRelativeShape 让内容跟随容器"，没给具体数值 ——
    /// 因为 SwiftUI 会自动算，而我们是自己画 NSPanel，必须手写。
    ///
    /// 数值从苹果截图反算：沿卡片左上角对角线扫，
    /// 第一个不透明像素出现在距离 d 处，圆角半径 r 满足 d = r(1 - 1/√2)。
    /// 苹果那张 d = 11px → r ≈ 37.6px，卡宽 382 → r/宽 = 0.0984。
    /// （之前用"逐行内缩归零"的粗办法量到 0.0785，把圆角算小了，
    ///  并排一看苹果那张明显更圆。）
    var cornerRadius: CGFloat {
        CGFloat(size.width * 0.0984)
    }

    /// 内容到卡片边缘的标准留白。
    /// HIG 明确写：大多数组件用 16pt，紧凑分组可用 11pt。
    /// 「不要贴边、留白统一」是原文强调的点，所以三个尺寸都用 16。
    var contentInset: CGFloat { 16 }

    /// 显示名，右键菜单用
    var title: String {
        switch self {
        case .small: return "小号"
        case .medium: return "中号"
        case .large: return "大号"
        }
    }
}

/// 小组件主题。和尺寸正交：小/中/大 都能套任意一套。
enum WidgetTheme: String, Codable, CaseIterable {
    /// 经典：系统动态色的浅色卡片，跟随系统深浅色
    case classic
    /// 仿苹果天气组件：固定深紫渐变 + 白色细体字
    case apple

    var title: String {
        switch self {
        case .classic: return "经典"
        case .apple: return "仿苹果"
        }
    }
}


/// 桌面小组件。
///
/// 为什么是 NSPanel 而不是 WidgetKit：
/// WidgetKit 组件由系统进程渲染，刷新靠 Timeline 请求，最短也是分钟级；
/// 而且它要求 App Group + 正式开发者账号。温度每 10 秒广播一次，
/// 用 WidgetKit 只会看到一个几分钟前的旧数字。这里用窗口自己画，
/// 能做到秒级更新，且不需要任何特殊权限。
final class WidgetPanel: NSPanel {

    private var card: CardView!
    private var contentStack: NSStackView!
    /// contentStack 相对卡片的边距约束。切换尺寸时布局方式不同，
    /// 需要先全部解除再重建，否则新旧两套互斥约束并存会冲突。
    private var contentConstraints: [NSLayoutConstraint] = []
    private var size_: WidgetSize = .medium
    private var theme_: WidgetTheme = .classic
    private var refreshTimer: Timer?

    private static let posKey = "tempbar.widget.pos"
    private static let sizeKey = "tempbar.widget.size"
    private static let themeKey = "tempbar.widget.theme"
    private static let pinnedKey = "tempbar.widget.pinned"

    private var pinnedToFront: Bool {
        get { UserDefaults.standard.bool(forKey: Self.pinnedKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.pinnedKey)
            applyLevel()
        }
    }

    init() {
        // 老版本把「大号」存成了 "apple" 这个尺寸值。
        // 现在尺寸和主题拆开了，读到 legacy 值要翻译成
        // 「大号 + 仿苹果」，否则老用户升级后尺寸会掉回默认的中号，
        // 而且主题变回经典 —— 等于把他设置好的东西悄悄改了。
        let savedSizeRaw = UserDefaults.standard.string(forKey: Self.sizeKey)
        var legacyApple = false
        if savedSizeRaw == "apple" {
            legacyApple = true
            size_ = .large
        } else {
            size_ = savedSizeRaw.flatMap(WidgetSize.init(rawValue:)) ?? .medium
        }

        if legacyApple {
            theme_ = .apple
        } else {
            theme_ = UserDefaults.standard.string(forKey: Self.themeKey)
                .flatMap(WidgetTheme.init(rawValue:)) ?? .classic
        }

        super.init(
            contentRect: NSRect(origin: .zero, size: size_.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // 不出现在 Mission Control / 窗口列表里，更像桌面挂件
        isExcludedFromWindowsMenu = true

        // 显式钉死最小尺寸，别让 AppKit 从内容约束反推出一个下限。
        // 之前小号缩到 257 就下不去，就是被这个隐式下限卡住的。
        contentMinSize = NSSize(width: 1, height: 1)
        minSize = NSSize(width: 1, height: 1)

        // 卡片不能直接当 contentView。
        // 实测这样会把卡片尺寸交给 Auto Layout 决定：窗口 340 宽时，
        // 约束系统按"内容所需的最小宽度"（读数区 + 图表最小 96）把卡片压到 259，
        // 右边露出一条窗口背景，看起来就是"边框对应不上"。
        // 改成普通容器 + 卡片用 autoresizing 填满，卡片就严格等于窗口内容区。
        let container = ContainerView()
        container.wantsLayer = false
        contentView = container

        card = CardView()
        card.radius = size_.cornerRadius
        // 必须走 setDynamicFill 而不是直接赋 fill：
        // withAlphaComponent 会把动态色在调用时固化，
        // 浅色启动后切深色仍是白卡，配上变白的 .labelColor 就是白底白字。
        card.setDynamicFill(.textBackgroundColor, alpha: 0.96)
        card.setDynamicBorder(.labelColor, alpha: 0.10, width: 1)
        card.wantsLayer = true
        // 卡片自己**不画阴影**。
        //
        // 之前这里设了 layer.shadowOpacity/Radius/Offset，同时又让窗口
        // hasShadow = true，于是有了两层阴影：一层系统按窗口形状（方形）算的，
        // 一层 CALayer 按卡片圆角内容算的。后者超出窗口边界就被硬裁掉，
        // 裁切处留下一条 1px 的中灰硬边 + 一圈浅灰填充 ——
        // 用户看到的"黑色线和灰色填充"就是它（量过：边缘 1px 是 (172,171,175)，
        // 外面 50px 是 (244,244,244)）。
        //
        // 只留系统那一层：窗口阴影跟内容 alpha 走，圆角处自然收进去，
        // 边缘干净，也不会被窗口边界裁出硬边。
        card.layer?.shadowOpacity = 0
        card.layer?.shadowRadius = 0
        card.layer?.shadowOffset = .zero
        // 不参与约束求解，frame 由 autoresizing 跟着窗口走
        card.translatesAutoresizingMaskIntoConstraints = true
        card.autoresizingMask = [.width, .height]
        card.frame = container.bounds
        container.addSubview(card)

        contentStack = NSStackView()
        contentStack.orientation = .vertical
        contentStack.spacing = 0
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(contentStack)
        installContentConstraints()

        applyLevel()
        restorePosition()
        applyCardStyle()
        rebuild()

        // 迁移完成后把新值落盘，下次就走正常分支了
        if legacyApple {
            UserDefaults.standard.set(WidgetSize.large.rawValue, forKey: Self.sizeKey)
            UserDefaults.standard.set(WidgetTheme.apple.rawValue, forKey: Self.themeKey)
        }

        // 秒级刷新：广播间隔约 10 秒，1 秒刷一次足够，CPU 占用可忽略
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(refreshTimer!, forMode: .common)
    }

    /// 内容容器。窗口改大小时它随窗口自动缩放，再顺手把卡片贴满。
    /// 单独一个子类是因为需要在每次 layout 时兜一次底：
    /// autoresizingMask 在个别情况下（比如切换尺寸的那一帧）会慢半拍。
    private final class ContainerView: NSView {
        override func layout() {
            super.layout()
            for sub in subviews {
                if sub.frame != bounds {
                    sub.frame = bounds
                }
            }
        }
    }

    // MARK: 内容边距

    /// 装 contentStack 相对卡片的边距约束。
    ///
    /// 布局方式只看**尺寸**，不看主题：
    ///   - 小/中号：内容按自身高度垂直居中（钉 centerY + 上下"不小于"兜底）
    ///   - 大号：顶部对齐、底部自然留白（苹果那张卡就是上 25 / 下 67）
    ///
    /// 每次切换尺寸都要先解除旧的再装新的。
    /// 两套互斥约束同时存在会直接触发 Auto Layout 冲突日志，
    /// 而且哪一套生效不确定，表现就是"有时候居中、有时候铺满"。
    ///
    /// 留白取 HIG 的标准值 16pt（多数组件用 16，紧凑分组才用 11）。
    /// 大号上下给 20：它行数多，16 会显得挤。
    private func installContentConstraints() {
        NSLayoutConstraint.deactivate(contentConstraints)
        contentConstraints.removeAll()

        // 仿苹果小号用 11pt 留白：HIG 明确说紧凑分组可用 11（标准是 16）。
        // 小号要在一张 158×158 里塞下「名称 + 大温度 + 湿度 + 最高最低」四行，
        // 用 16 的话垂直空间只剩 126，四行排不下。
        // 对着苹果那张对比图看，它的小号内容离边缘也只有 10pt 左右。
        let inset: CGFloat = (theme_ == .apple && size_ == .small) ? 14 : size_.contentInset
        let isLarge = size_ == .large
        let vInset: CGFloat = isLarge ? 20 : inset
        // 仿苹果在**所有尺寸**下都是左上角起排。
        //
        // 这里踩过一次坑：我一度以为苹果小号是"四行全部水平居中"，
        // 就按 centerX 排了。可把系统自带的小号天气组件和我们的并排放，
        // 一眼就能看出不是 —— 苹果那边「秦淮区 / 11° / 多云 / 最高最低」
        // 左边缘是一条竖线，压根没居中。
        // 中央对齐会让人以为卡片里"中间有一坨东西"，和桌面上其它组件并排很跳。
        // 经典主题的小/中号仍保持居中，它本来就是一块信息牌，不追求和苹果一致。
        contentStack.alignment = (isLarge || theme_ == .apple) ? .leading : .centerX

        var c = [
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset)
        ]
        if isLarge {
            // 大号：顶部对齐，底部自然留白。
            // 苹果那张卡就是内容和卡顶距离小（25pt）、底部留一大块（67pt），
            // 用 centerY 会把内容整体压低，反而和原图不一致。
            c.append(contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: vInset))
            c.append(contentStack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor,
                                                          constant: -vInset))
        } else {
            c.append(contentStack.centerYAnchor.constraint(equalTo: card.centerYAnchor))
            c.append(contentStack.topAnchor.constraint(greaterThanOrEqualTo: card.topAnchor,
                                                       constant: vInset))
            c.append(contentStack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor,
                                                          constant: -vInset))
        }
        contentConstraints = c
        NSLayoutConstraint.activate(c)
    }

    // MARK: 主题

    /// 套用卡片外观。只看**主题**，和尺寸无关 ——
    /// 小号也可以要仿苹果的紫渐变，大号也可以要经典的浅色卡。
    ///
    /// 经典主题用系统动态色，跟随深浅色；
    /// 仿苹果刻意用固定的紫蓝渐变 —— 苹果天气组件本身就不跟随系统深浅色，
    /// 它的配色是"天气"的一部分，不是"外观"的一部分。所以这里不走
    /// setDynamicFill 那条路，直接给字面 RGB。
    private func applyCardStyle() {
        card.radius = size_.cornerRadius

        if theme_ == .apple {
            // 渐变端点直接取自苹果截图的实测像素（x=60 竖直采样，避开文字）：
            //   顶部 rgba(20, 0, 149) → 底部 rgba(58, 13, 195)
            // 注意绿色通道几乎为 0 —— 这是深靛蓝到紫蓝的过渡，
            // 不是那种发紫的亮蓝。之前凭感觉写了个偏亮的版本，
            // 并排一看就是我们这边"轻"、苹果那张"沉"。
            card.gradientFill = CardView.Gradient(
                top: NSColor(srgbRed: 20 / 255.0, green: 0 / 255.0, blue: 149 / 255.0, alpha: 1),
                bottom: NSColor(srgbRed: 58 / 255.0, green: 13 / 255.0, blue: 195 / 255.0, alpha: 1)
            )
            // 无边框：苹果那张卡没有描边，靠渐变和阴影分层
            card.borderWidth = 0
            card.borderColor = .clear
        } else {
            card.gradientFill = nil
            card.setDynamicFill(.textBackgroundColor, alpha: 0.96)
            card.setDynamicBorder(.labelColor, alpha: 0.10, width: 1)
        }
        // 阴影完全交给窗口的 hasShadow 那一层（见 init 里的说明）。
        // 这里别再动 card.layer 的 shadow —— 两层一叠，圆角外就会露出灰框。
        card.layer?.shadowOpacity = 0
        card.needsDisplay = true
    }

    // MARK: 层级

    private func applyLevel() {
        if pinnedToFront {
            level = .floating
        } else {
            // 桌面图标层之上一点：压在壁纸上、在普通窗口下面，
            // 这就是"放到桌面上"的效果
            level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        }
    }

    // MARK: 位置

    private func restorePosition() {
        if let s = UserDefaults.standard.string(forKey: Self.posKey) {
            let p = NSPointFromString(s)
            setFrameOrigin(p)
            // 存的位置可能落在已拔掉的显示器上，校验一下是否还在屏内
            if NSScreen.screens.allSatisfy({ !$0.visibleFrame.intersects(frame) }) {
                moveToDefaultCorner()
            }
        } else {
            moveToDefaultCorner()
        }
    }

    private func moveToDefaultCorner() {
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        setFrameOrigin(NSPoint(x: v.maxX - frame.width - 28,
                               y: v.minY + 28))
    }

    private func savePosition() {
        UserDefaults.standard.set(NSStringFromPoint(frame.origin), forKey: Self.posKey)
    }

    // MARK: 拖动 / 右键

    override func mouseDown(with event: NSEvent) {
        performDrag(with: event)
        savePosition()
    }

    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()

        // 尺寸和主题分开两个子菜单：它们是正交的，
        // 六个组合用一个大列表列出来反而难找。
        let sizeItem = NSMenuItem(title: "尺寸", action: nil, keyEquivalent: "")
        let sizeSub = NSMenu()
        for s in WidgetSize.allCases {
            let i = NSMenuItem(title: s.title, action: #selector(changeSize(_:)), keyEquivalent: "")
            i.representedObject = s.rawValue
            i.state = (s == size_) ? .on : .off
            i.target = self
            sizeSub.addItem(i)
        }
        sizeItem.submenu = sizeSub
        menu.addItem(sizeItem)

        let themeItem = NSMenuItem(title: "主题", action: nil, keyEquivalent: "")
        let themeSub = NSMenu()
        for t in WidgetTheme.allCases {
            let i = NSMenuItem(title: t.title, action: #selector(changeTheme(_:)), keyEquivalent: "")
            i.representedObject = t.rawValue
            i.state = (t == theme_) ? .on : .off
            i.target = self
            themeSub.addItem(i)
        }
        themeItem.submenu = themeSub
        menu.addItem(themeItem)

        let pin = NSMenuItem(title: "浮动在所有窗口之上",
                             action: #selector(togglePin), keyEquivalent: "")
        pin.state = pinnedToFront ? .on : .off
        pin.target = self
        menu.addItem(pin)

        menu.addItem(.separator())

        // 直接弹重命名对话框，不再借道设置窗口。
        // 之前这里接的是 openSettings：点了只是打开设置，输入框还藏在第三屏，
        // 同事根本不知道该在哪儿改，报的就是"装完改不了名字"。
        let rename = NSMenuItem(title: "重命名设备…",
                                action: #selector(renameDevice), keyEquivalent: "")
        rename.target = self
        menu.addItem(rename)

        let settings = NSMenuItem(title: "打开设置…",
                                  action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let hide = NSMenuItem(title: "隐藏小组件",
                              action: #selector(hideWidget), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        NSMenu.popUpContextMenu(menu, with: event, for: contentView!)
    }

    @objc private func changeSize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let s = WidgetSize(rawValue: raw) else { return }
        applySize(s)
    }

    @objc private func changeTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let t = WidgetTheme(rawValue: raw) else { return }
        applyTheme(t)
    }

    @objc private func renameDevice() {
        RenamePrompt.show()
    }

    /// 尺寸/主题被右键菜单改掉之后，设置窗口里的两个下拉必须跟着变。
    ///
    /// 之前只写了 UserDefaults，设置窗口没人通知 —— 它只在 loadValues 时读一次，
    /// 所以"右键改成小号 → 打开设置 → 下拉还写的中号"，用户再点一下又给改回去。
    /// 用通知而不是直接拿 AppDelegate，是因为设置窗口可能在自检里单独构造，
    /// 那时根本没有 delegate。
    private func postStyleChanged() {
        NotificationCenter.default.post(name: .tempbarWidgetStyleChanged, object: nil)
    }

    /// 切换尺寸。
    ///
    /// 这里顺序很关键，之前"缩小回不去"就是顺序错了：
    /// 先把窗口 setFrame 到小号，可此时内容还是中号那套（左边读数 + 右边曲线，
    /// 曲线有 `>= 96` 的硬性最小宽度、左侧文字又是 required 抗压缩），
    /// 两者叠加把内容的最小宽度顶到 257 以上。NSPanel 的内容视图一旦用
    /// Auto Layout，AppKit 会拿约束推算窗口的最小尺寸并拒绝再缩小，
    /// 所以 setFrame 到 168 直接被系统挡回去了。
    /// 正确做法是先按新的尺寸重建内容，让约束需求降下来，再改窗口大小。
    func applySize(_ s: WidgetSize) {
        guard s != size_ || frame.size != s.size else { return }
        size_ = s
        UserDefaults.standard.set(s.rawValue, forKey: Self.sizeKey)
        postStyleChanged()

        let origin = frame.origin

        // 0) 先换主题和边距。卡片圆角/配色、内容布局方式都跟着尺寸走
        applyCardStyle()
        installContentConstraints()

        // 1) 先按新尺寸重建内容，把"最小尺寸需求"降下来
        rebuild()
        contentView?.layoutSubtreeIfNeeded()

        // 2) 再改窗口。尺寸和原点一起设，避免先改尺寸再改原点时闪一下
        setFrame(NSRect(origin: origin, size: s.size), display: true)

        // 3) 约束稳定后再兜一次，防止个别系统版本首次 setFrame 被弹回
        if frame.size != s.size {
            contentView?.layoutSubtreeIfNeeded()
            setFrame(NSRect(origin: origin, size: s.size), display: true)
        }
        setFrameOrigin(origin)

        // 4) 卡片贴满，并重绘圆角
        card.frame = contentView?.bounds ?? NSRect(origin: .zero, size: s.size)
        card.needsLayout = true
        card.needsDisplay = true
        card.layoutSubtreeIfNeeded()
        savePosition()
    }

    /// 切换主题。窗口大小不变，所以不需要 applySize 那套"先缩再改"的折腾，
    /// 只要换卡片外观 + 重建内容（两套主题的排版完全不同）。
    func applyTheme(_ t: WidgetTheme) {
        guard t != theme_ else { return }
        theme_ = t
        UserDefaults.standard.set(t.rawValue, forKey: Self.themeKey)
        postStyleChanged()

        applyCardStyle()
        installContentConstraints()
        rebuild()
        contentView?.layoutSubtreeIfNeeded()
        card.frame = contentView?.bounds ?? card.frame
        card.needsLayout = true
        card.needsDisplay = true
        card.layoutSubtreeIfNeeded()
        savePosition()
    }

    /// 当前实际尺寸，供自检核对（窗口被系统撑大时能和 size_ 对不上）
    var actualSize: NSSize { frame.size }
    var cardSize: NSSize { card.frame.size }
    var currentSize: WidgetSize { size_ }
    var currentTheme: WidgetTheme { theme_ }


    @objc private func togglePin() {
        pinnedToFront.toggle()
    }

    @objc private func openSettings() {
        (NSApp.delegate as? AppDelegate)?.openSettings()
    }

    @objc private func hideWidget() {
        orderOut(nil)
        (NSApp.delegate as? AppDelegate)?.syncWidgetMenuState()
    }

    func showWidget() {
        orderFrontRegardless()
        (NSApp.delegate as? AppDelegate)?.syncWidgetMenuState()
    }

    var isVisibleNow: Bool { isVisible }

    /// 自检用：拍整个窗口内容区，而不是只拍卡片。
    ///
    /// `snapshot` 只渲染 card 自己，卡片外面那一圈（container、窗口背景）
    /// 根本不在画面里。用户报的"紫色是对的但外面还有黑线和灰色填充"
    /// 正好落在 card 之外，用 card 级截图永远查不到。
    func windowSnapshot(to path: String) -> Bool {
        guard let cv = contentView else { return false }
        cv.layoutSubtreeIfNeeded()
        guard let rep = cv.bitmapImageRepForCachingDisplay(in: cv.bounds) else { return false }
        rep.size = cv.bounds.size
        cv.cacheDisplay(in: cv.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// 卡片在窗口里的实际 frame，自检用来核对"卡片是否严丝合缝贴满窗口"
    var cardFrameInWindow: NSRect {
        guard let cv = contentView else { return .zero }
        return card.convert(card.bounds, to: cv)
    }

    /// 自检用：把当前内容离屏渲染成 PNG。
    /// 用 cacheDisplay 而不是截屏，不需要屏幕录制权限，也不受当前空间/遮挡影响。
    ///
    /// `scale` 必须自己建 bitmap 才能生效：
    /// `bitmapImageRepForCachingDisplay` 返回的是**窗口所在屏**的倍率，
    /// 这台机器外接屏是 1x，渲出来就是 158×158 的糊图，做官网截图根本没法用。
    /// 手动建 rep 再把它 size 设成逻辑尺寸，cacheDisplay 就会按像素数放大绘制。
    func snapshot(to path: String, scale: CGFloat = 2) -> Bool {
        layoutIfNeeded()
        card.layoutSubtreeIfNeeded()
        let size = card.bounds.size
        guard size.width > 0, size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((size.width * scale).rounded()),
                                         pixelsHigh: Int((size.height * scale).rounded()),
                                         bitsPerSample: 8,
                                         samplesPerPixel: 4,
                                         hasAlpha: true,
                                         isPlanar: false,
                                         colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0,
                                         bitsPerPixel: 0) else { return false }
        rep.size = size
        card.cacheDisplay(in: card.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: 刷新

    private func tick() {
        guard isVisible else { return }
        rebuild()
    }

    /// 数据变了就重画。整块重建比细粒度更新简单可靠，164pt 的视图重建开销极小。
    func rebuild() {
        let state = AppState.shared
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if let dev = state.primary, !dev.reading.isEmpty {
            // 先加进 stack 再补宽约束。
            // 约束必须在"有共同祖先"之后才能激活，否则 AppKit 直接抛
            // NSGenericException: no common ancestor。
            let content = makeContent(for: dev)
            contentStack.addArrangedSubview(content)
            // 内容铺满可用宽度：这样中号的曲线能吃到剩余空间，
            // 小号的 footer 横线也能拉满、左右两端对齐。
            // 垂直方向仍然由 centerY 决定居中，两者不冲突。
            content.widthAnchor.constraint(equalTo: contentStack.widthAnchor).isActive = true

            // 大号不需要铺满高度了：它现在顶部对齐、间距固定，
            // 底部留白由内容自然排完剩下的空间产生（和苹果那张一致）。
            // 之前铺满是为了让弹性占位生效，现在没有弹性占位了。
        } else {
            contentStack.addArrangedSubview(makeEmptyState())
        }

        // 没数据时也要让用户能右键，所以始终让 contentView 接受事件
        card.needsDisplay = true
    }

    private func makeEmptyState() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        // 空状态也用居中对齐，否则整块提示贴在左上角
        stack.alignment = .centerX
        stack.spacing = 6

        // 文字颜色必须跟主题走：仿苹果那张是深紫底，
        // 用 .labelColor 在浅色系统下就是黑字压深紫，等于看不见。
        let isApple = theme_ == .apple
        let mainColor: NSColor = isApple ? .white : .labelColor
        let subColor: NSColor = isApple
            ? NSColor.white.withAlphaComponent(0.78)
            : .secondaryLabelColor

        let title = NSTextField(labelWithString: "等待温度计")
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = mainColor
        title.alignment = .center

        let hint = NSTextField(wrappingLabelWithString: Scanner.shared.bluetoothOff
            ? "蓝牙已关闭，请在系统设置里打开"
            : "正在监听附近的 BTHome 广播…")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = subColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = size_.size.width - 28

        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        // 深色底上默认的转圈是深灰，几乎看不见。
        // NSProgressIndicator 没有 contentTintColor，
        // 但把它的 appearance 钉成 darkAqua，系统就会用浅色画这个控件。
        if isApple { spin.appearance = NSAppearance(named: .darkAqua) }

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(spin)
        return stack
    }

    private func makeContent(for dev: Device) -> NSView {
        // 主题先分叉，再在主题内部按尺寸排版。
        // 这样以后加第三套主题时，只需再写一个 makeXxxContent 分派，
        // 不用把尺寸的判断散落到每个角落。
        if theme_ == .apple {
            return makeAppleContent(dev: dev)
        }
        return makeClassicContent(dev: dev)
    }

    // MARK: 经典主题

    /// 经典主题：浅色卡片 + 系统动态色，跟着系统深浅色走。
    private func makeClassicContent(dev: Device) -> NSView {
        let temp = fmt1(dev.reading.temperature)
        let hum = fmt0(dev.reading.humidity)

        // 顶部：状态点 + 设备名
        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 5
        statusRow.alignment = .centerY

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.backgroundColor = (dev.isStale
            ? NSColor.systemOrange
            : NSColor.systemGreen).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let nameLabel = NSTextField(labelWithString: dev.displayName)
        nameLabel.font = .systemFont(ofSize: 11, weight: .regular)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        statusRow.addArrangedSubview(dot)
        statusRow.addArrangedSubview(nameLabel)

        // 大数字 + 湿度
        let bigRow = NSStackView()
        bigRow.orientation = .horizontal
        bigRow.alignment = .firstBaseline
        bigRow.spacing = 2

        let big = NSTextField(labelWithString: temp)
        big.font = .systemFont(ofSize: 40, weight: .medium)
        big.textColor = .labelColor

        let deg = NSTextField(labelWithString: "°C")
        deg.font = .systemFont(ofSize: 15, weight: .regular)
        deg.textColor = .tertiaryLabelColor

        bigRow.addArrangedSubview(big)
        bigRow.addArrangedSubview(deg)

        let humRow = NSStackView()
        humRow.orientation = .horizontal
        humRow.alignment = .firstBaseline
        humRow.spacing = 4

        let hv = NSTextField(labelWithString: "\(hum)%")
        hv.font = .systemFont(ofSize: 15, weight: .medium)
        hv.textColor = .systemBlue
        hv.setContentCompressionResistancePriority(.required, for: .horizontal)

        let hl = NSTextField(labelWithString: "湿度")
        hl.font = .systemFont(ofSize: 11)
        hl.textColor = .tertiaryLabelColor
        hl.setContentCompressionResistancePriority(.required, for: .horizontal)

        humRow.addArrangedSubview(hv)
        humRow.addArrangedSubview(hl)

        let left = NSStackView()
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 2
        left.addArrangedSubview(statusRow)
        left.addArrangedSubview(bigRow)
        left.addArrangedSubview(humRow)
        // 读数区不能被右边图表挤掉，否则"湿度"两个字会被截断
        left.setContentCompressionResistancePriority(.required, for: .horizontal)

        let footer = makeFooter(dev)

        if size_ == .small {
            let col = NSStackView()
            col.orientation = .vertical
            // 小号没有曲线，整块读数就是全部内容，水平居中才不显得偏左
            col.alignment = .centerX
            col.spacing = 4
            col.addArrangedSubview(left)
            col.addArrangedSubview(footer)
            footer.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
            return col
        }

        if size_ == .large {
            // 大号经典主题：把中号那套放大 —— 数更大、曲线更长、多一行当天最高最低。
            // 354pt 的高度如果只堆中号那三行，下面会空掉小半张卡。
            return makeClassicLarge(dev: dev)
        }

        // 中号：左边读数，右边曲线
        let samples = AppState.shared.history(of: dev, hours: 6)
        let right = makeChartColumn(hours: 6, samples: samples, height: 54)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 14
        row.distribution = .fill
        row.addArrangedSubview(left)
        row.addArrangedSubview(right)

        left.setContentHuggingPriority(.required, for: .horizontal)
        right.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // 图表列要吃满剩余宽度，否则曲线只有一小条
        right.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 6
        col.addArrangedSubview(row)
        col.addArrangedSubview(footer)
        // footer 必须和外层同宽，否则它内部的横线撑不开
        footer.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    /// 经典主题的大号。
    ///
    /// 中号是 338×158 的横条，大号是 338×354 的竖卡 ——
    /// 直接把中号那套塞进大号，底部会空出一大块。这里把字号和曲线一起放大，
    /// 再补一行「当天最高 / 最低」，把纵向空间用满。
    private func makeClassicLarge(dev: Device) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8

        // --- 第一行：状态点 + 设备名（比中号大一档）
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = (dev.isStale
            ? NSColor.systemOrange
            : NSColor.systemGreen).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let nameLabel = NSTextField(labelWithString: dev.displayName)
        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.lineBreakMode = .byTruncatingTail

        let statusRow = NSStackView()
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY
        statusRow.addArrangedSubview(dot)
        statusRow.addArrangedSubview(nameLabel)

        // --- 温度：56pt，配合 20pt 的 °C
        let bigRow = NSStackView()
        bigRow.orientation = .horizontal
        bigRow.alignment = .firstBaseline
        bigRow.spacing = 3

        let big = NSTextField(labelWithString: fmt1(dev.reading.temperature))
        big.font = .systemFont(ofSize: 56, weight: .medium)
        big.textColor = .labelColor

        let deg = NSTextField(labelWithString: "°C")
        deg.font = .systemFont(ofSize: 20, weight: .regular)
        deg.textColor = .tertiaryLabelColor

        bigRow.addArrangedSubview(big)
        bigRow.addArrangedSubview(deg)

        // --- 湿度
        let humRow = NSStackView()
        humRow.orientation = .horizontal
        humRow.alignment = .firstBaseline
        humRow.spacing = 5

        let hv = NSTextField(labelWithString: "\(fmt0(dev.reading.humidity))%")
        hv.font = .systemFont(ofSize: 20, weight: .medium)
        hv.textColor = .systemBlue

        let hl = NSTextField(labelWithString: "湿度")
        hl.font = .systemFont(ofSize: 13)
        hl.textColor = .tertiaryLabelColor

        humRow.addArrangedSubview(hv)
        humRow.addArrangedSubview(hl)

        // --- 当天最高 / 最低
        let range = AppState.shared.todayRange(of: dev)
        let hlRow = makeClassicRangeRow(high: range?.high, low: range?.low)

        // --- 曲线：近 24 小时
        //
        // 高度给 96 而不是 130：354 的卡减掉上下各 20 的留白只剩 314，
        // 上面五行（名字/温度/湿度/最高最低/间隔）已经吃掉 218，
        // 曲线加表头还剩 ~96。给 130 会把卡片撑到 382 —— 自检量的就是 382。
        let samples = AppState.shared.history(of: dev, hours: 24)
        let chart = makeChartColumn(hours: 24, samples: samples, height: 96,
                                    titleSize: 11, rangeSize: 11)

        col.addArrangedSubview(statusRow)
        col.setCustomSpacing(10, after: statusRow)
        col.addArrangedSubview(bigRow)
        col.setCustomSpacing(6, after: bigRow)
        col.addArrangedSubview(humRow)
        col.setCustomSpacing(10, after: humRow)
        col.addArrangedSubview(hlRow)
        col.setCustomSpacing(14, after: hlRow)
        col.addArrangedSubview(chart)
        col.setCustomSpacing(10, after: chart)
        col.addArrangedSubview(makeFooter(dev))

        chart.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    /// 经典主题的「最高 / 最低」一行。用系统色，和浅色卡片配套。
    private func makeClassicRangeRow(high: Double?, low: Double?) -> NSView {
        func cell(_ title: String, _ v: Double?, color: NSColor) -> NSView {
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: 11)
            t.textColor = .tertiaryLabelColor

            let n = NSTextField(labelWithString: v.map { "\(fmt0($0))°" } ?? "--")
            n.font = .systemFont(ofSize: 15, weight: .medium)
            n.textColor = color

            let s = NSStackView()
            s.orientation = .horizontal
            s.alignment = .firstBaseline
            s.spacing = 3
            s.addArrangedSubview(t)
            s.addArrangedSubview(n)
            return s
        }

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        // 温度沿用国内习惯：高温偏红、低温偏蓝
        row.addArrangedSubview(cell("最高", high, color: .systemRed))
        row.addArrangedSubview(cell("最低", low, color: .systemBlue))
        return row
    }

    /// 曲线列。`hours` 同时决定标题文案和取数区间；
    /// `height` / 字号是为了让中号（矮）和大号（高）共用一套代码。
    private func makeChartColumn(hours: Int, samples: [Sample], height: CGFloat,
                                 titleSize: CGFloat = 10, rangeSize: CGFloat = 10) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 4

        let temps = samples.compactMap(\.temp)
        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 8

        let title = NSTextField(labelWithString: "近 \(hours) 小时")
        title.font = .systemFont(ofSize: titleSize)
        title.textColor = .tertiaryLabelColor

        let range = NSTextField(labelWithString: temps.isEmpty
            ? "暂无曲线"
            : "\(fmt1(temps.min()))° — \(fmt1(temps.max()))°")
        range.font = .systemFont(ofSize: rangeSize)
        range.textColor = .secondaryLabelColor

        header.addArrangedSubview(title)
        header.addArrangedSubview(range)
        col.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        let chart = Sparkline()
        chart.points = temps
        chart.lineColor = .systemTeal
        let th = AppState.shared.thresholds
        if th.enabled { chart.reference = th.maxTemp }
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: height).isActive = true
        // 给一个最小宽度就够，剩下的让它自己争——硬编码 150 会挤掉左侧的"湿度"标签。
        // 优先级压到 defaultLow：窗口缩小时这条必须能让步，
        // 否则它会成为整个窗口的尺寸下限，"缩小回不去"就是这么来的。
        let minW = chart.widthAnchor.constraint(greaterThanOrEqualToConstant: 96)
        minW.priority = .defaultLow
        minW.isActive = true
        col.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        return col
    }

    /// 仿苹果主题在三个尺寸下的字号与间距。
    ///
    /// 只写一套固定数值的话，小号（158×158）里 96pt 的温度根本放不下，
    /// 中号（338×158）又会被 96pt 顶得只剩一行。所以按尺寸给一档度量。
    ///
    /// 温度字号的定法：大号沿用实测值 96pt（对 354 高的卡）。
    /// 其余两档按卡片较短边等比缩放 ——
    ///   小 158/338 ≈ 0.47  → 96 × 0.47 ≈ 45，取 46
    ///   中 158/338 ≈ 0.47  → 但中号是横条，宽度充裕，可以稍大，取 54
    /// 字号都 ≥ 11pt，符合 HIG 的最小字号要求。
    private struct AppleMetrics {
        var nameSize: CGFloat
        var tempSize: CGFloat
        /// 温度字重。苹果**不是所有尺寸都用细体**：
        ///   小/中号是常规字重（regular）—— 尺寸小，细笔画会发虚
        ///   大号才是 96pt thin
        /// 之前三个尺寸一律 thin，拿你的小号截图一比，
        /// 我们那个 23° 明显比苹果瘦一圈。
        var tempWeight: NSFont.Weight
        var humSize: CGFloat
        var humIconSize: CGFloat
        var rangeValueSize: CGFloat
        var rangeLabelSize: CGFloat
        var nameToTemp: CGFloat
        var tempToHum: CGFloat
        var humToRange: CGFloat
        /// 最高/最低两组之间的间距
        var rangeGap: CGFloat
        /// 是否显示最高/最低那一行。三个尺寸都显示 ——
        /// 苹果自己的小号组件（small）底下就有一行「最高 26° 最低 15°」，
        /// 只留温度反而不像了。
        var showsRange: Bool

        static func forSize(_ s: WidgetSize) -> AppleMetrics {
            switch s {
            case .small:
                // 数值是拿屏幕上的系统小号天气组件（1:1 像素，卡宽 158）量的：
                //   名称 15pt semibold，温度墨迹高 ≈ 37pt、笔画偏细，
                //   天气行 13-14pt，最高/最低数字 21pt + 竖排小标签 11pt
                // 温度从 46 提到 48：46 时数字墨迹只有 33pt，比苹果那 37 矮一头，
                // 并排看明显"瘦小"。再大就会把四行顶出卡外，48 是这一档的上限。
                return AppleMetrics(nameSize: 15, tempSize: 48, tempWeight: .regular,
                                    humSize: 13, humIconSize: 13,
                                    rangeValueSize: 21, rangeLabelSize: 11,
                                    nameToTemp: 0, tempToHum: 10, humToRange: 9,
                                    rangeGap: 12, showsRange: true)
            case .medium:
                return AppleMetrics(nameSize: 15, tempSize: 48, tempWeight: .regular,
                                    humSize: 14, humIconSize: 14,
                                    rangeValueSize: 26, rangeLabelSize: 11,
                                    nameToTemp: 6, tempToHum: 8, humToRange: 10,
                                    rangeGap: 18, showsRange: true)
            case .large:
                return AppleMetrics(nameSize: 17, tempSize: 96, tempWeight: .thin,
                                    humSize: 17, humIconSize: 17,
                                    rangeValueSize: 38, rangeLabelSize: 13,
                                    nameToTemp: 12, tempToHum: 16, humToRange: 22,
                                    rangeGap: 20, showsRange: true)
            }
        }
    }

    /// 仿苹果主题的分尺寸布局。
    ///
    /// 排版依据 Apple HIG「Widgets → Displaying text in widgets」：
    ///   - 用系统字体和 SF Symbols（我们是 AppKit，对应 .systemFont + SF Symbols）
    ///   - 字号不小于 11pt，否则很多人看不清
    ///   - 大字号用于一眼要看到的关键信息
    ///
    /// 结构照着你给的那张 Apple 天气组件截图：
    ///   左上 位置名 → 巨大温度 → 图标+文字 → 最高/最低
    /// 我们做温度计，所以：
    ///   - 位置名换成设备名（设置里可改）
    ///   - 天气图标和"大部多云"去掉 —— 没有数据源，编一个就是假的
    ///   - 最高/最低换成当天已测到的最高/最低（不是预报）
    ///
    /// 配色不用系统动态色：这张卡固定深紫渐变，白字压在深紫上，
    /// 文字一律用白色 + 不同透明度表达层级。若用 labelColor，
    /// 系统切深色时文字变浅，和这层固定紫底就糊在一起了。
    private func makeAppleContent(dev: Device) -> NSView {
        let m = AppleMetrics.forSize(size_)
        let white = NSColor.white

        // --- 第一行：设备名
        //
        // 之前这里跟了个 location.fill 箭头，照抄苹果天气的「秦淮区↗」。
        // 但那个箭头在苹果那里是「点击切换城市」，我们既没有定位、
        // 也不能点，纯粹是个假交互，看着反而尴尬。去掉。
        let nameLabel = NSTextField(labelWithString: dev.displayName)
        nameLabel.font = .systemFont(ofSize: m.nameSize, weight: .semibold)
        nameLabel.textColor = white
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.addArrangedSubview(nameLabel)

        // --- 温度大字 + 度数符号
        let tempRow = makeAppleTempRow(text: fmt0(dev.reading.temperature), m: m)

        // --- 湿度（代替苹果"大部多云"那一行）
        let humRow: NSStackView
        do {
            let humIcon = NSImageView()
            humIcon.image = NSImage(systemSymbolName: "humidity.fill",
                                    accessibilityDescription: "湿度")
            humIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: m.humIconSize,
                                                                      weight: .regular)
            humIcon.contentTintColor = white.withAlphaComponent(0.78)
            humIcon.translatesAutoresizingMaskIntoConstraints = false

            let humLabel = NSTextField(labelWithString: "湿度 \(fmt0(dev.reading.humidity))%")
            humLabel.font = .systemFont(ofSize: m.humSize, weight: .medium)
            humLabel.textColor = white.withAlphaComponent(0.92)

            humRow = NSStackView()
            humRow.orientation = .horizontal
            humRow.alignment = .centerY
            humRow.spacing = size_ == .small ? 4 : 6
            humRow.addArrangedSubview(humIcon)
            humRow.addArrangedSubview(humLabel)
        }

        // --- 最高 / 最低。
        //
        // 苹果那张是**横排一行**：`最高 13° 最低 6°`。
        // 我第一版写成上下两行的竖排，和原图一比立刻不对：
        // 苹果的"最高"两个字是竖着窄挤在大数字左边的，
        // 也就是「小标签竖排 + 大数字」左右并排，两组再横向排列。
        // 这里照做：每组内部横排（标签 + 数字），两组之间拉开间距。
        var rangeRow: NSStackView?
        if m.showsRange {
            let range = AppState.shared.todayRange(of: dev)
            let hiText = range.map { fmt0($0.high) } ?? "--"
            let loText = range.map { fmt0($0.low) } ?? "--"

            func rangeCell(_ title: String, _ value: String) -> NSView {
                // 标签一律竖排（「最」在上「高」在下）。
                // 苹果那三张卡里，最高/最低都是「窄标签 + 大数字」并排的两组，
                // 小号也一样 —— 我差点按"小号字横排"改，一比对立刻不对：
                // 苹果小号的「最高」两个字就是上下摞着的。
                let t = NSTextField(labelWithString: title.map { String($0) }.joined(separator: "\n"))
                t.font = .systemFont(ofSize: m.rangeLabelSize, weight: .regular)
                t.textColor = white.withAlphaComponent(0.72)
                t.alignment = .center
                t.maximumNumberOfLines = 2

                let v = NSTextField(labelWithString: "\(value)°")
                v.font = .systemFont(ofSize: m.rangeValueSize, weight: .regular)
                v.textColor = white

                let s = NSStackView()
                s.orientation = .horizontal
                s.alignment = .centerY
                s.spacing = 3
                s.addArrangedSubview(t)
                s.addArrangedSubview(v)
                return s
            }

            let r = NSStackView()
            r.orientation = .horizontal
            r.alignment = .centerY
            r.spacing = m.rangeGap
            r.addArrangedSubview(rangeCell("最高", hiText))
            r.addArrangedSubview(rangeCell("最低", loText))
            rangeRow = r
        }

        // --- 自上而下堆，顶部对齐、底部自然留白。
        //
        // 间距照苹果截图的比例定（原图卡高 344）：
        //   地名 → 大数字   12pt
        //   大数字 → 湿度   16pt
        //   湿度 → 最高最低 22pt
        //   底部留白        67pt (0.195 卡高)
        //
        // 之前试过加弹性占位把"最高最低"顶到底部，出来中间一坨大空洞，
        // 和苹果那张完全不像 —— 苹果的留白是内容自然排完剩下的，
        // 不是硬撑出来的。这里回到固定间距。
        // 苹果那张对比图里，三张卡（小/中/大）的内容左边缘都是对齐的一条竖线：
        // 设备名、温度、湿度、最高最低，全都贴同一条左边。
        // 之前小号被我改成 .centerX，实机一比差得非常明显 ——
        // 现在统一 .leading，和桌面上系统自带的小号组件并排才像一家人。
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        col.addArrangedSubview(nameRow)
        col.setCustomSpacing(m.nameToTemp, after: nameRow)
        col.addArrangedSubview(tempRow)
        col.setCustomSpacing(m.tempToHum, after: tempRow)
        col.addArrangedSubview(humRow)
        if let rangeRow {
            col.setCustomSpacing(m.humToRange, after: humRow)
            col.addArrangedSubview(rangeRow)
        }

        // 中号是 338×158 的横条：四行竖着摞起来需要 145pt，
        // 加上 16pt 上下留白就是 177pt，硬塞只会把卡片撑高。
        // 苹果的中号天气组件也是「左列信息 + 右侧数据」的横向结构，
        // 所以这里把最高/最低单独拎出来放右边，并且竖排 ——
        // 横排放在一块 158 高的卡里就是一条细线悬在右边缘，很空。
        if size_ == .medium, let rangeRow {
            rangeRow.removeFromSuperview()

            // 把 rangeRow 里的两组拆出来竖着放
            let cells = rangeRow.arrangedSubviews
            let right = NSStackView()
            right.orientation = .vertical
            right.alignment = .leading
            right.spacing = 6
            for c in cells {
                c.removeFromSuperview()
                right.addArrangedSubview(c)
            }

            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 16
            row.addArrangedSubview(col)

            // 中间塞一个可拉伸的空白，把右列顶到卡右边缘。
            // 只靠 hugging 优先级不够稳：col 是纵向 stack，
            // 它的宽度取值会被"最宽的那个子视图"锚住，
            // 实测最高/最低只挪到温度右边就停了，右边还空 84pt。
            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
            spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(spacer)
            row.addArrangedSubview(right)

            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 8).isActive = true
            return row
        }
        return col
    }

    /// 温度大字 + `°`。
    ///
    /// `°` 的字号与位置，都是量着苹果原图定的，不是拍脑袋。
    /// 从苹果那张截图（454×750）里逐像素扫出来的事实：
    ///   数字「9」墨迹高 96px
    ///   ° 墨迹 24×24px
    ///   ° 顶部比数字顶部低 2px，° 中心在数字顶部下方 13.5px
    /// 换算成比例：° 直径 = 字高的 25%，顶部下沉 2.1%。
    ///
    /// 再用 SF Pro 的字体度量反推（96pt thin 的数字墨迹高 70pt）：
    ///   ° 的墨迹高 / 字号 = 0.283
    ///   ° 的墨迹顶 = 字段顶 + 0.238 × 字号
    /// 于是字号 S 时要让 ° 墨迹 = 数字字高 × 25%，得 ° 字号 ≈ 0.646 × S；
    /// 要让 ° 墨迹顶落在数字顶下方 2.1%，top 常量 ≈ 0.099 × S。
    ///
    /// 之前固定写 46pt / top 6：° 只有字高的 18.6%，还高出数字顶部 6pt，
    /// 看着就是「飘在数字右上方的一个小圈」，和苹果的贴顶感完全不同。
    /// 现在按比例缩放，三个尺寸的观感一致。
    private func makeAppleTempRow(text: String, m: AppleMetrics) -> NSView {
        let white = NSColor.white
        let s = m.tempSize

        let big = NSTextField(labelWithString: text)
        // 字重按尺寸给：小/中号 regular，大号 thin。
        // 苹果那张对比图里，小号卡上的「11°」笔画明显比大号的粗。
        big.font = .systemFont(ofSize: s, weight: m.tempWeight)
        big.textColor = white

        let deg = NSTextField(labelWithString: "°")
        deg.font = .systemFont(ofSize: (s * 0.646).rounded(), weight: .light)
        deg.textColor = white

        // 容器 + 手动上边距。用容器是因为 NSStackView 的 .firstBaseline
        // 会把两种字号的基线拉到同一水平线，46pt 的字落点按它自己的
        // 字体度量算，视觉上就掉到数字腰部去了。
        let degBox = NSView()
        degBox.translatesAutoresizingMaskIntoConstraints = false
        deg.translatesAutoresizingMaskIntoConstraints = false
        degBox.addSubview(deg)
        NSLayoutConstraint.activate([
            deg.leadingAnchor.constraint(equalTo: degBox.leadingAnchor),
            deg.trailingAnchor.constraint(equalTo: degBox.trailingAnchor),
            deg.topAnchor.constraint(equalTo: degBox.topAnchor, constant: s * 0.099),
            deg.bottomAnchor.constraint(lessThanOrEqualTo: degBox.bottomAnchor)
        ])

        let row = NSStackView()
        row.orientation = .horizontal
        // 用 .top 而不是 .firstBaseline：容器自己已经处理了 ° 的垂直位置，
        // stack 只需要把两个盒子在顶部对齐即可。
        row.alignment = .top
        row.spacing = s >= 80 ? 1 : 0
        row.addArrangedSubview(big)
        row.addArrangedSubview(degBox)
        return row
    }

    private func makeFooter(_ dev: Device) -> NSView {
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.distribution = .equalSpacing

        let bat = NSTextField(labelWithString: dev.reading.battery.map { "电量 \($0)%" } ?? "")
        bat.font = .systemFont(ofSize: 10)
        bat.textColor = .tertiaryLabelColor

        let upd = NSTextField(labelWithString: ago(dev.lastSeen))
        upd.font = .systemFont(ofSize: 10)
        upd.textColor = .tertiaryLabelColor

        row.addArrangedSubview(bat)
        row.addArrangedSubview(upd)

        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .centerX   // 让横线按容器宽度居中撑开
        col.spacing = 5
        col.addArrangedSubview(sep)
        col.addArrangedSubview(row)

        sep.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        row.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }
}

extension Notification.Name {
    /// 小组件的尺寸/主题被改动了（右键菜单、设置窗口、自检都算）
    static let tempbarWidgetStyleChanged = Notification.Name("tempbar.widgetStyleChanged")
}
