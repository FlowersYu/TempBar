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
    /// 毛玻璃：真·背景模糊（桌面上透出壁纸）+ 深色叠色 + 白色层级文字
    case glass

    var title: String {
        switch self {
        case .classic: return "经典"
        case .glass: return "毛玻璃"
        }
    }

    /// 从存档里读主题。
    ///
    /// 老版本的这套主题叫 "apple"（当年只有一个紫渐变），
    /// 现在换成了真正的毛玻璃，rawValue 也跟着改成 "glass"。
    /// 老用户存档里还是 "apple"，这里翻译过去 ——
    /// 不认的话他升级后主题会静默掉回经典，等于我们把他设的东西改了。
    static func stored(_ raw: String?) -> WidgetTheme {
        switch raw {
        case "glass", "apple": return .glass
        default: return .classic
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
    /// 毛玻璃主题的背景模糊层。垫在 card 底下，只有玻璃主题显示。
    private var blur: NSVisualEffectView!
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
            theme_ = .glass
        } else {
            theme_ = WidgetTheme.stored(UserDefaults.standard.string(forKey: Self.themeKey))
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

        // 背景模糊层。垫在卡片底下，卡片用半透明叠色盖在它上面，
        // 两者叠起来就是 macOS 自己那套"毛玻璃"观感。
        //
        // 三个参数缺一不可：
        //   material = .hudWindow      偏深的材质，白字压上去才有对比
        //   blendingMode = .behindWindow 模糊的是窗口**后面**的壁纸；
        //                                .withinWindow 只模糊同窗口内的兄弟视图，
        //                                在桌面上就是一块死板的半透明色
        //   state = .active            必须钉死。默认的 .followsWindowActiveState
        //                                在窗口不活跃时会把模糊退成一块灰饼 ——
        //                                一个桌面挂件几乎永远不活跃，不钉住就等于没有毛玻璃
        blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.isEmphasized = false
        blur.translatesAutoresizingMaskIntoConstraints = true
        blur.autoresizingMask = [.width, .height]
        blur.frame = container.bounds
        blur.isHidden = true          // 经典主题不需要，由 applyCardStyle 打开
        container.addSubview(blur)

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
            UserDefaults.standard.set(WidgetTheme.glass.rawValue, forKey: Self.themeKey)
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

        // 毛玻璃小号用 14pt 留白：HIG 说紧凑分组可用 11（标准是 16）。
        // 小号要在一张 158×158 里塞下四行，留 16 就排不下。
        let inset: CGFloat = (theme_ == .glass && size_ == .small) ? 14 : size_.contentInset
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
        contentStack.alignment = (isLarge || theme_ == .glass) ? .leading : .centerX

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
    /// 小号也可以要毛玻璃，大号也可以要经典的浅色卡。
    ///
    /// 经典主题用系统动态色，跟随深浅色；
    /// 玻璃主题是"看得见壁纸的一层深色玻璃"，固定配色、不跟随系统外观
    /// （系统切深色不会让它更黑，只会让桌面上其它东西变深）。
    private func applyCardStyle() {
        card.radius = size_.cornerRadius

        if theme_ == .glass {
            blur.isHidden = false
            // 模糊层不吃 layer 圆角（它的模糊是窗口服务器在 layer 之外合成的），
            // 只能走 maskImage 这条官方路径做圆角。
            blur.maskImage = Self.roundedMask(radius: card.radius)

            // 卡片这边用 layer 的连续曲率裁圆角（苹果的超椭圆），
            // 自己 draw 只负责铺色。
            card.usesLayerMask = true
            card.layer?.cornerRadius = card.radius
            card.layer?.masksToBounds = true

            // 叠色：深靛蓝→紫，带透明度。透明度是玻璃的关键 ——
            // 全不透明就只是一张深色卡，后面的模糊一点也透不出来。
            //
            // 但也不能太透：用户壁纸是亮的（雪山那张），
            // 透太多白字就糊了。0.55~0.70 这一档是"看得见壁纸、
            // 又压得住白字"的平衡点，实测在这个区间里两头都成立。
            card.gradientFill = CardView.Gradient(
                top: NSColor(srgbRed: 0.07, green: 0.06, blue: 0.16, alpha: 0.70),
                bottom: NSColor(srgbRed: 0.20, green: 0.10, blue: 0.35, alpha: 0.56),
                mid: NSColor(srgbRed: 0.12, green: 0.08, blue: 0.27, alpha: 0.64)
            )
            card.glassOverlay = CardView.GlassOverlay(
                glow: NSColor(srgbRed: 0.45, green: 0.33, blue: 1.0, alpha: 0.30),
                glowCenter: NSPoint(x: 0.82, y: 0.84),
                glowRadius: 0.95,
                sheen: 0.10,
                hairline: 0.22
            )
            card.borderWidth = 0
            card.borderColor = .clear
        } else {
            blur.isHidden = true
            card.usesLayerMask = false
            card.layer?.masksToBounds = false
            card.gradientFill = nil
            card.glassOverlay = nil
            card.setDynamicFill(.textBackgroundColor, alpha: 0.96)
            card.setDynamicBorder(.labelColor, alpha: 0.10, width: 1)
        }
        // 阴影完全交给窗口的 hasShadow 那一层（见 init 里的说明）。
        // 这里别再动 card.layer 的 shadow —— 两层一叠，圆角外就会露出灰框。
        card.layer?.shadowOpacity = 0
        card.needsDisplay = true
    }

    /// 给 NSVisualEffectView 做圆角遮罩。
    ///
    /// 用 maskImage 而不是 layer.cornerRadius：模糊效果由窗口服务器合成，
    /// 在视图 layer 之外，layer 圆角只能裁掉视图自己画的内容，
    /// 裁不掉那层模糊 —— 表现就是"四角还是方的，卡片里却有圆角"。
    /// capInsets + .stretch 让同一张 9-patch 图适应任意尺寸，不用每次改尺寸重建。
    private static func roundedMask(radius r: CGFloat) -> NSImage {
        let d = r * 2 + 1
        let img = NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        img.resizingMode = .stretch
        return img
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
    /// 自检用：卡片本体。
    /// 内容区里现在垫了一张背景模糊层，`subviews.first` 已经不等于卡片了 ——
    /// 拿错对象截出来的是一张空图，测什么都是"没找到内容"。
    var cardView: NSView { card }
    /// 自检用：模糊层是否按当前主题该显示的那样显示
    var blurActive: Bool { !(blur?.isHidden ?? true) }
    /// 自检用：卡片是不是在用 layer 的连续曲率圆角（苹果超椭圆）
    var usesSquircleCorners: Bool { card.usesLayerMask }


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

        // 文字颜色必须跟主题走：玻璃是深色底，
        // 用 .labelColor 在浅色系统下就是黑字压深紫，等于看不见。
        let isGlass = theme_ == .glass
        let mainColor: NSColor = isGlass ? .white : .labelColor
        let subColor: NSColor = isGlass
            ? NSColor.white.withAlphaComponent(0.72)
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
        if isGlass { spin.appearance = NSAppearance(named: .darkAqua) }

        stack.addArrangedSubview(title)
        stack.addArrangedSubview(hint)
        stack.addArrangedSubview(spin)
        return stack
    }

    private func makeContent(for dev: Device) -> NSView {
        // 主题先分叉，再在主题内部按尺寸排版。
        // 这样以后加第三套主题时，只需再写一个 makeXxxContent 分派，
        // 不用把尺寸的判断散落到每个角落。
        if theme_ == .glass {
            return makeGlassContent(dev: dev)
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

    /// 毛玻璃主题在三个尺寸下的字号与间距。
    ///
    /// 和旧那套「仿苹果」的差别不只是配色：旧那套把小号四行硬挤进 158，
    /// 结果窗口被内容顶到 166（自检里那条 `[apple-small] 窗口=158×166` 就是它），
    /// 字也小得发虚。这套按 Mac 上真实组件的比例重排，
    /// 小号四行只占 ~132pt，稳稳落在 158 里，那条遗留问题顺带消失。
    private struct GlassMetrics {
        var nameSize: CGFloat
        var tempSize: CGFloat
        /// 温度字重。苹果并不是所有尺寸都用细体：
        /// 小/中号温度小，细笔画会发虚，用 regular；大号 96pt 才用 thin。
        var tempWeight: NSFont.Weight
        var humSize: CGFloat
        var humIcon: CGFloat
        var rangeLabel: CGFloat
        var rangeValue: CGFloat
        var rangeGap: CGFloat
        var nameToTemp: CGFloat
        var tempToHum: CGFloat
        var humToRange: CGFloat
        var showsRange: Bool
        /// 走势曲线的高度。0 表示不画（小号放不下）。
        /// 中/大号必须画：一块 338×354 的卡只有四行字，下面空 120pt，
        /// 看着不像"留白"，像"没做完"。
        var chartHeight: CGFloat
        var chartCaption: CGFloat

        static func forSize(_ s: WidgetSize) -> GlassMetrics {
            switch s {
            case .small:
                return GlassMetrics(nameSize: 13, tempSize: 44, tempWeight: .regular,
                                    humSize: 12, humIcon: 11,
                                    rangeLabel: 10, rangeValue: 15, rangeGap: 12,
                                    nameToTemp: 0, tempToHum: 3, humToRange: 7,
                                    showsRange: true,
                                    chartHeight: 0, chartCaption: 0)
            case .medium:
                return GlassMetrics(nameSize: 15, tempSize: 50, tempWeight: .regular,
                                    humSize: 13, humIcon: 12,
                                    rangeLabel: 11, rangeValue: 16, rangeGap: 16,
                                    nameToTemp: 0, tempToHum: 4, humToRange: 7,
                                    showsRange: true,
                                    chartHeight: 84, chartCaption: 10)
            case .large:
                return GlassMetrics(nameSize: 17, tempSize: 92, tempWeight: .thin,
                                    humSize: 15, humIcon: 14,
                                    rangeLabel: 13, rangeValue: 24, rangeGap: 22,
                                    nameToTemp: 10, tempToHum: 12, humToRange: 16,
                                    showsRange: true,
                                    chartHeight: 64, chartCaption: 11)
            }
        }
    }

    /// 毛玻璃主题的内容。
    ///
    /// 骨架照 macOS / iOS 天气组件：左上名字 → 巨大温度 → 湿度 → 最高最低。
    /// 文字一律白色，用透明度做层级 —— 玻璃后面是壁纸，深浅完全不可控，
    /// 只有白色能保证任何壁纸下都压得住；用 .labelColor 的话，
    /// 浅色壁纸下系统给黑字，压在深色玻璃上直接看不见。
    private func makeGlassContent(dev: Device) -> NSView {
        let m = GlassMetrics.forSize(size_)

        let nameRow = makeGlassNameRow(dev: dev, m: m)
        let tempRow = makeGlassTempRow(text: fmt0(dev.reading.temperature), m: m)
        let humRow = makeGlassHumRow(dev: dev, m: m)
        let rangeRow = m.showsRange ? makeGlassRangeRow(dev: dev, m: m) : nil

        // 左列：文字信息。三/四个尺寸都用同一套左对齐 ——
        // 苹果的组件里「城市 / 温度 / 天气 / 最高最低」左边是一条竖线，
        // 居中的话会显得卡片中间糊着一坨东西，和桌面上别的组件并排很跳。
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 0
        col.addArrangedSubview(nameRow)
        col.setCustomSpacing(m.nameToTemp, after: nameRow)
        col.addArrangedSubview(tempRow)
        col.setCustomSpacing(m.tempToHum, after: tempRow)
        col.addArrangedSubview(humRow)
        if let rangeRow {
            col.setCustomSpacing(m.humToRange, after: humRow)
            col.addArrangedSubview(rangeRow)
        }

        guard m.chartHeight > 0 else { return col }
        let chart = makeGlassChart(dev: dev, m: m)

        if size_ == .medium {
            // 中号是 338×158 的横条：左列信息 + 右侧曲线。
            // 和苹果中号天气组件同一个套路（那边右边放的是逐小时预报）。
            // 不这么做的话，158 高的横条里右半边会空出一大片。
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 18
            row.addArrangedSubview(col)
            row.addArrangedSubview(chart)
            col.setContentHuggingPriority(.required, for: .horizontal)
            chart.setContentHuggingPriority(.defaultLow, for: .horizontal)
            chart.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return row
        }

        // 大号：竖着堆，曲线跟在最高最低下面，把下半张卡填上。
        // 间距 16 是按"内容正好落在 322 可用高度里"算的，改字体会连带改它。
        col.setCustomSpacing(16, after: rangeRow ?? humRow)
        col.addArrangedSubview(chart)
        return col
    }

    private func makeGlassNameRow(dev: Device, m: GlassMetrics) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5

        // 只在数据断了的时候给一个橙点。正常状态下什么都不加 ——
        // 苹果那种卡上没有"在线"绿点，多一个点就多一处要跟人解释的东西。
        if dev.isStale {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 2.5
            dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 5).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 5).isActive = true
            row.addArrangedSubview(dot)
        }

        let name = NSTextField(labelWithString: dev.displayName)
        name.font = .systemFont(ofSize: m.nameSize, weight: .semibold)
        name.textColor = NSColor.white.withAlphaComponent(0.96)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(name)
        return row
    }

    /// 湿度行：图标 + 数值。
    ///
    /// 用 drop.fill 而不是 humidity.fill —— 后者在小字号下就是三根波浪线加一个点，
    /// 缩到 11pt 完全看不出是湿度，还容易被当成渲染糊了。
    private func makeGlassHumRow(dev: Device, m: GlassMetrics) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = size_ == .small ? 3 : 5

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "湿度")
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: m.humIcon, weight: .medium)
        icon.contentTintColor = NSColor.white.withAlphaComponent(0.75)
        icon.translatesAutoresizingMaskIntoConstraints = false

        let value = NSTextField(labelWithString: "\(fmt0(dev.reading.humidity))%")
        value.font = .systemFont(ofSize: m.humSize, weight: .medium)
        value.textColor = NSColor.white.withAlphaComponent(0.88)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(value)
        return row
    }

    /// 「最高 25° 最低 22°」一行。
    ///
    /// 之前把「最/高」两个字竖着摞起来塞在大数字左边，想模仿苹果那张截图。
    /// 实机上两个字行高不一样，和大数字并排永远对不齐，看着像文字在打架。
    /// 改回一行小标签 + 数值，干净、也不用再跟基线较劲。
    private func makeGlassRangeRow(dev: Device, m: GlassMetrics) -> NSView {
        let range = AppState.shared.todayRange(of: dev)

        func cell(_ title: String, _ v: Double?) -> NSView {
            let t = NSTextField(labelWithString: title)
            t.font = .systemFont(ofSize: m.rangeLabel, weight: .regular)
            t.textColor = NSColor.white.withAlphaComponent(0.62)

            let n = NSTextField(labelWithString: v.map { "\(fmt0($0))°" } ?? "--")
            n.font = .systemFont(ofSize: m.rangeValue, weight: .regular)
            n.textColor = NSColor.white.withAlphaComponent(0.92)

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
        row.spacing = m.rangeGap
        row.addArrangedSubview(cell("最高", range?.high))
        row.addArrangedSubview(cell("最低", range?.low))
        return row
    }

    /// 玻璃上的走势曲线：白线 + 很淡的白填充。
    ///
    /// 不用系统青色 —— 青色压在深紫玻璃上会泛绿，像从别的界面贴上去的；
    /// 白线才和整套字色是一家。
    private func makeGlassChart(dev: Device, m: GlassMetrics) -> NSView {
        let col = NSStackView()
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 5

        let samples = AppState.shared.history(of: dev, hours: 24)
        let temps = samples.compactMap(\.temp)

        let caption = NSTextField(labelWithString: temps.isEmpty
            ? "近 24 小时"
            : "近 24 小时   \(fmt1(temps.min()))° — \(fmt1(temps.max()))°")
        caption.font = .systemFont(ofSize: m.chartCaption, weight: .regular)
        caption.textColor = NSColor.white.withAlphaComponent(0.55)
        col.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true

        let chart = Sparkline()
        chart.points = temps
        chart.lineColor = NSColor.white.withAlphaComponent(0.85)
        chart.lineWidth = 1.8
        chart.fillAlpha = 0.12
        chart.referenceColor = .white
        let th = AppState.shared.thresholds
        if th.enabled { chart.reference = th.maxTemp }
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: m.chartHeight).isActive = true
        col.addArrangedSubview(chart)
        chart.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        return col
    }

    /// 温度大字 + `°`。
    ///
    /// `°` 的字号和位置是量出来的，不是拍脑袋：
    ///   苹果原图里 ° 墨迹 ≈ 数字字高的 25%，顶部比数字顶低 2%
    ///   用 SF Pro 的字体度量反推 → ° 字号 ≈ 0.646 × 数字字号，top ≈ 0.099 × 字号
    /// 固定写死会在换尺寸时飘走，所以按比例算。
    ///
    /// 度数符号单独装进容器、手动给上边距，是因为 NSStackView 的
    /// .firstBaseline 会把两种字号拉到同一条基线，° 会掉到数字腰部去。
    private func makeGlassTempRow(text: String, m: GlassMetrics) -> NSView {
        let s = m.tempSize

        let big = NSTextField(labelWithString: text)
        big.font = .systemFont(ofSize: s, weight: m.tempWeight)
        big.textColor = .white

        let deg = NSTextField(labelWithString: "°")
        deg.font = .systemFont(ofSize: (s * 0.646).rounded(), weight: .light)
        deg.textColor = NSColor.white.withAlphaComponent(0.92)

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
