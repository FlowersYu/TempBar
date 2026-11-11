import Cocoa

/// 画曲线的小视图。不用 SwiftUI 的 Charts 是因为这里只要一条折线，
/// 手绘更省依赖，也更好控制圆角端点和填充。
final class Sparkline: NSView {
    var points: [Double] = [] { didSet { needsDisplay = true } }
    var lineColor: NSColor = .systemTeal { didSet { needsDisplay = true } }
    var showFill = true { didSet { needsDisplay = true } }
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
        path.lineWidth = 1.6
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
            lineColor.withAlphaComponent(0.10).setFill()
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
    var radius: CGFloat = 14
    var fill: NSColor = .clear
    var borderColor: NSColor = .clear
    var borderWidth: CGFloat = 0.5

    /// 用系统"浅填充"风格。颜色在 draw 时按当前外观解析，
    /// 因为动态 NSColor 在离屏渲染时拿不到外观上下文，会退化成黑色。
    var subtle = false

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

    /// 竖向渐变填充。仿苹果主题用。
    ///
    /// 为什么单独做一个入口：渐变不能靠 fill 一个 NSColor 表达，
    /// 必须在 draw 里画 NSGradient。而组件主题是"固定外观"的
    /// （苹果那个卡片不管系统深浅色都是紫蓝渐变），
    /// 所以这里存的是字面 RGB，不走动态色解析。
    struct Gradient {
        var top: NSColor
        var bottom: NSColor
    }
    var gradientFill: Gradient? {
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
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
                                xRadius: radius, yRadius: radius)
        if let g = gradientFill {
            // 圆角裁剪后画竖向渐变：从左上的深紫到右下的亮紫，
            // 和苹果天气组件那种"光照从左上打过来"的观感一致。
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            NSGradient(starting: g.top, ending: g.bottom)?.draw(in: bounds, angle: -90)
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
