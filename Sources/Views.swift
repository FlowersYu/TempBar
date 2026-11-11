import Cocoa

/// 画曲线的小视图。不用 SwiftUI 的 Charts 是因为这里只要一条折线，
/// 手绘更省依赖，也更好控制圆角端点和填充。
final class Sparkline: NSView {
    var points: [Double] = [] { didSet { needsDisplay = true } }
    var lineColor: NSColor = .systemTeal { didSet { needsDisplay = true } }
    var showFill = true { didSet { needsDisplay = true } }
    /// 线宽。毛玻璃主题上白线要比系统色的线再粗一点点才压得住,
    /// 否则被背景的模糊一层一层洗淡，看着像没画。
    var lineWidth: CGFloat = 1.6 { didSet { needsDisplay = true } }
    /// 填充透明度。默认 0.10 是给浅色卡用的，玻璃上用 0.14 才看得出体积。
    var fillAlpha: CGFloat = 0.10 { didSet { needsDisplay = true } }
    /// 画一条参考线（比如阈值上限）
    var reference: Double?
    var referenceColor: NSColor = .systemRed

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2, bounds.width > 1, bounds.height > 1 else { return }

        var lo = points.min()!
        var hi = points.max()!
        // 数据跨度太小时给一个保底，避免曲线放大成锯齿噪声
        if hi - lo < 0.6 {
            let mid = (hi + lo) / 2
            lo = mid - 0.4
            hi = mid + 0.4
        }
        if let r = reference {
            // 阈值线只在离数据不太远时才纳入视野。
            // 否则像上限 28° 配 23° 的读数，会把整条曲线压到框底一条缝里。
            let limit = (hi - lo) * 0.6
            if r >= lo - limit && r <= hi + limit {
                lo = Swift.min(lo, r)
                hi = Swift.max(hi, r)
            }
        }
        // 上下各留 4pt，避免折线贴边
        let pad: CGFloat = 4
        let h = bounds.height - pad * 2
        var span = hi - lo
        if span < 0.5 { span = 0.5 }     // 数据平直时给一个最小跨度，否则除零

        func pt(_ i: Int, _ v: Double) -> CGPoint {
            let x = bounds.width * CGFloat(i) / CGFloat(points.count - 1)
            let y = pad + h * CGFloat(1 - (v - lo) / span)
            return CGPoint(x: x, y: y)
        }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (i, v) in points.enumerated() {
            let p = pt(i, v)
            if i == 0 { path.move(to: p) } else { path.line(to: p) }
        }

        if showFill {
            let fill = NSBezierPath()
            for (i, v) in points.enumerated() {
                let p = pt(i, v)
                if i == 0 { fill.move(to: p) } else { fill.line(to: p) }
            }
            fill.line(to: CGPoint(x: bounds.width, y: bounds.height))
            fill.line(to: CGPoint(x: 0, y: bounds.height))
            fill.close()
            lineColor.withAlphaComponent(fillAlpha).setFill()
            fill.fill()
        }

        lineColor.setStroke()
        path.stroke()

        if let r = reference, r >= lo, r <= hi {
            let y = pad + h * CGFloat(1 - (r - lo) / span)
            let dash = NSBezierPath()
            dash.move(to: CGPoint(x: 0, y: y))
            dash.line(to: CGPoint(x: bounds.width, y: y))
            dash.lineWidth = 1
            dash.setLineDash([3, 3], count: 2, phase: 0)
            referenceColor.withAlphaComponent(0.5).setStroke()
            dash.stroke()
        }
    }
}

/// 圆角卡片容器。NSPanel 本身不做圆角裁剪，得自己画。
final class CardView: NSView {
    /// 圆角半径。设置时同步到 layer ——
    /// 毛玻璃主题用 layer 的连续曲率圆角（见 usesLayerMask），
    /// 那里用的是 layer.cornerRadius，不跟着改就还是旧半径。
    var radius: CGFloat = 14 {
        didSet {
            layer?.cornerRadius = radius
            needsDisplay = true
        }
    }
    var fill: NSColor = .clear
    var borderColor: NSColor = .clear
    var borderWidth: CGFloat = 0.5

    /// 用系统"浅填充"风格。颜色在 draw 时按当前外观解析，
    /// 因为动态 NSColor 在离屏渲染时拿不到外观上下文，会退化成黑色。
    var subtle = false

    /// 圆角交给 layer 的连续曲率（squircle）裁剪，draw 里铺满整个 bounds。
    ///
    /// 为什么值得单独开一条路：苹果的组件圆角不是正圆角，是超椭圆，
    /// 拿圆角矩形并排一比，转角那一小段弧度立刻能看出来"这个不是苹果的"。
    /// `NSBezierPath(roundedRect:)` 只能画正圆角，而 `CALayer.cornerCurve = .continuous`
    /// 才是系统那套曲线 —— 所以让 layer 去裁，我们只管把颜色铺满。
    var usesLayerMask = false {
        didSet {
            layer?.masksToBounds = usesLayerMask
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
    }

    required init?(coder: NSCoder) { fatalError("不支持归档）") }

    // 为什么不能直接把 `NSColor.textBackgroundColor.withAlphaComponent(0.96)`
    // 存进 fill：`withAlphaComponent` 会返回一个"静态"颜色，
    // 它在调用那一刻就按当前外观求值并定死了。
    // 于是浅色主题启动后切到深色，卡片还是白的，而文字用的是
    // 动态 .labelColor 会变白 —— 白底白字，温度完全看不见。
    // 正确做法是存"基色 + 透明度"，每次 draw 时重新解析。
    private var fillBase: NSColor?
    private var fillAlpha: CGFloat = 1
    private var borderBase: NSColor?
    private var borderAlpha: CGFloat = 1

    /// 设置一个会跟随系统外观的填充色。
    /// 动态 NSColor 在这里不被求值，真正的解析发生在 draw(_:) 里。
    func setDynamicFill(_ base: NSColor, alpha: CGFloat) {
        fillBase = base
        fillAlpha = alpha
        fill = .clear       // 走动态这条路，别让静态 fill 抢先
        needsDisplay = true
    }

    func setDynamicBorder(_ base: NSColor, alpha: CGFloat, width: CGFloat) {
        borderBase = base
        borderAlpha = alpha
        borderWidth = width
        borderColor = .clear
        needsDisplay = true
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 系统切换深浅色时必须重画。
    /// 这个视图是 wantsLayer 的，普通 draw(_:) 的结果会被 layer 缓存，
    /// 外观变了不会自动失效 —— 不主动重绘就会停在旧配色上。
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        // 子视图里的动态文字色也要跟着重新解析
        needsLayout = true
        subviews.forEach { $0.needsDisplay = true }
    }

    /// 在给定的外观下解析一个颜色的具体值。
    /// 必须先 performAsCurrentDrawingAppearance，否则动态色会拿默认外观的结果。
    private func resolve(_ color: NSColor, in appearance: NSAppearance) -> NSColor {
        var out = color
        appearance.performAsCurrentDrawingAppearance {
            out = color.usingColorSpace(.sRGB) ?? color
        }
        return out
    }

    private func resolvedFill() -> NSColor {
        if gradientFill != nil {
            return .clear        // 渐变时不填纯色，交给 draw 里的渐变分支
        }
        if subtle {
            return isDark
                ? NSColor(white: 1.0, alpha: 0.07)
                : NSColor(white: 0.0, alpha: 0.045)
        }
        if let base = fillBase {
            let c = resolve(base, in: effectiveAppearance)
            return c.withAlphaComponent(fillAlpha)
        }
        return fill
    }

    /// 竖向渐变填充。毛玻璃主题用。
    ///
    /// 为什么单独做一个入口：渐变不能靠 fill 一个 NSColor 表达，
    /// 必须在 draw 里画 NSGradient。而组件主题是"固定外观"的
    /// （玻璃卡不管系统深浅色都是同一层深色叠色），
    /// 所以这里存的是字面 RGB，不走动态色解析。
    struct Gradient {
        var top: NSColor
        var bottom: NSColor
        /// 中间停靠点。三段比两段自然得多：纯两端线性插值时，
        /// 中间那段是一条"值一样"的色带，看着像蒙了一层灰。
        var mid: NSColor?
    }
    var gradientFill: Gradient? {
        didSet { needsDisplay = true }
    }

    /// 叠在渐变之上的玻璃质感层。
    ///
    /// 真正的模糊来自背景后的 NSVisualEffectView，这里画的是"玻璃本身的厚度"：
    ///   glow     一大团柔光，模拟玻璃后面有一处光源（没有它就只是一块半透明色块）
    ///   sheen    顶部一道极淡的白，玻璃上边缘受光的那一条
    ///   hairline 内侧一圈 1px 细边，玻璃的边缘折射
    struct GlassOverlay {
        var glow: NSColor
        /// 柔光中心，按比例取（0,0 左下，1,1 右上）
        var glowCenter: NSPoint = NSPoint(x: 0.8, y: 0.85)
        /// 柔光半径，相对卡片较短边
        var glowRadius: CGFloat = 0.9
        var sheen: CGFloat = 0.12
        var hairline: CGFloat = 0.2
    }
    var glassOverlay: GlassOverlay? {
        didSet { needsDisplay = true }
    }

    private func resolvedBorder() -> NSColor? {
        if let base = borderBase {
            let c = resolve(base, in: effectiveAppearance)
            return c.withAlphaComponent(borderAlpha)
        }
        return borderColor == .clear ? nil : borderColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }

        if usesLayerMask {
            // 圆角由 layer 的连续曲率裁，这里铺满整个 bounds 即可
            if let g = gradientFill {
                drawStops(g, in: bounds)
            } else {
                let f = resolvedFill()
                if f.alphaComponent > 0 { f.setFill(); bounds.fill() }
            }
            if let ov = glassOverlay { drawGlassOverlay(ov, in: bounds) }
            return
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                xRadius: radius, yRadius: radius)
        if let g = gradientFill {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            drawStops(g, in: bounds)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let f = resolvedFill()
            if f.alphaComponent > 0 {
                f.setFill()
                path.fill()
            }
        }
        if borderWidth > 0, let b = resolvedBorder() {
            b.setStroke()
            path.lineWidth = borderWidth
            path.stroke()
        }
    }

    /// 画（可多段的）竖向渐变。
    private func drawStops(_ g: Gradient, in rect: NSRect) {
        if let mid = g.mid {
            NSGradient(colors: [g.top, mid, g.bottom],
                       atLocations: [0, 0.46, 1],
                       colorSpace: .sRGB)?.draw(in: rect, angle: -90)
        } else {
            NSGradient(starting: g.top, ending: g.bottom)?.draw(in: rect, angle: -90)
        }
    }

    /// 玻璃的"厚度"：柔光 + 顶部受光 + 内侧细边。
    /// 三样都很淡（加起来不到 30% 不透明度），叠起来才有玻璃感；
    /// 单看任何一层都只是"卡片上有点脏"。
    private func drawGlassOverlay(_ ov: GlassOverlay, in rect: NSRect) {
        // 1) 柔光。非翻转坐标系，y 大的是上面。
        let r = min(rect.width, rect.height) * ov.glowRadius
        let cx = rect.minX + rect.width * ov.glowCenter.x
        let cy = rect.minY + rect.height * ov.glowCenter.y
        let glowRect = NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
        if let gg = NSGradient(colors: [ov.glow, ov.glow.withAlphaComponent(0)]) {
            gg.draw(in: glowRect, relativeCenterPosition: .zero)
        }

        // 2) 顶部受光：只覆盖上半部分，往下淡出到透明
        if ov.sheen > 0 {
            let h = rect.height * 0.55
            let topRect = NSRect(x: rect.minX, y: rect.maxY - h, width: rect.width, height: h)
            let c = NSColor.white.withAlphaComponent(ov.sheen)
            NSGradient(colors: [c, c.withAlphaComponent(0)])?.draw(in: topRect, angle: -90)
        }

        // 3) 内侧细边。inset 0.5 让 1pt 的描边正好落在像素中间，不发虚。
        if ov.hairline > 0 {
            let rr = max(0, radius - 0.5)
            let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: rr, yRadius: rr)
            p.lineWidth = 1
            NSColor.white.withAlphaComponent(ov.hairline).setStroke()
            p.stroke()
        }
    }
}

/// 一行标签 + 数值，用在小组件底部的小指标
func metricLabel(_ title: String, _ value: String, size: CGFloat = 10) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 0

    let t = NSTextField(labelWithString: title)
    t.font = .systemFont(ofSize: size - 1, weight: .regular)
    t.textColor = .tertiaryLabelColor

    let v = NSTextField(labelWithString: value)
    v.font = .systemFont(ofSize: size + 2, weight: .medium)
    v.textColor = .labelColor

    stack.addArrangedSubview(t)
    stack.addArrangedSubview(v)
    return stack
}

func fmt1(_ v: Double?) -> String {
    guard let v else { return "--" }
    return String(format: "%.1f", v)
}

func fmt0(_ v: Double?) -> String {
    guard let v else { return "--" }
    return String(format: "%.0f", v)
}

func ago(_ d: Date) -> String {
    let s = Int(Date().timeIntervalSince(d))
    if s < 5 { return "刚刚" }
    if s < 60 { return "\(s) 秒前" }
    if s < 3600 { return "\(s / 60) 分钟前" }
    if s < 86400 { return "\(s / 3600) 小时前" }
    return "\(s / 86400) 天前"
}
