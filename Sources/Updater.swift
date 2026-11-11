import Cocoa
import CryptoKit

/// 更新清单。服务器上的 updates.json 就是这个结构。
///
/// 字段故意做得少而硬：版本号、包地址、sha256。
/// 没有 sha256 的清单一律拒绝安装 —— 走的是明文 http，
/// 不校验等于把"能不能往用户机器上塞可执行文件"交给网络中间人。
struct UpdateManifest: Decodable {
    var version: String
    var build: Int?
    var publishedAt: String?
    var notes: String?
    var downloadURL: String
    var size: Int64?
    var sha256: String?
}

/// 检查更新 / 下载 / 替换安装。
///
/// 更新源是那台天翼云开发机上的 nginx（8888 端口）。
/// 只有 IP 没有域名证书，所以走 http；为此 Info.plist 里开了 ATS 例外，
/// 代价是用 sha256 兜底 —— 校验不过就中止，绝不解压更不替换。
final class Updater {

    static let shared = Updater()

    /// 换服务器只改这一行
    static let feedURL = URL(string: "http://36.111.167.161:8888/tempbar/updates.json")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    static var currentBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    static var displayVersion: String { "\(currentVersion)（build \(currentBuild)）" }

    /// 语义化版本比较：1.10 > 1.9（按数字比，不是按字符串）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private var busy = false

    // MARK: 检查

    /// - Parameter interactive: 用户主动点的（要给出"已是最新"/"检查失败"的反馈）。
    ///   启动时的静默检查传 false，没网没服务器时不要弹窗打扰。
    func check(interactive: Bool) {
        guard !busy else { return }
        busy = true

        var req = URLRequest(url: Self.feedURL)
        req.timeoutInterval = 8
        // 必须绕开缓存：CDN 或系统缓存会把旧清单喂回来，
        // 表现就是"发了新版但同事那边永远提示已是最新"。
        req.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                self?.busy = false
                self?.handle(data: data, response: resp, error: err, interactive: interactive)
            }
        }.resume()
    }

    private func handle(data: Data?, response: URLResponse?, error: Error?, interactive: Bool) {
        if let error = error {
            NSLog("TempBar 更新检查失败：\(error.localizedDescription)")
            if interactive { alert("检查更新失败", "连不上更新服务器。\n\n\(error.localizedDescription)") }
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data = data else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            NSLog("TempBar 更新检查：HTTP \(code)")
            if interactive { alert("检查更新失败", "服务器返回了 \(code)。稍后再试。") }
            return
        }
        guard let m = try? JSONDecoder().decode(UpdateManifest.self, from: data) else {
            NSLog("TempBar 更新清单解析失败")
            if interactive { alert("检查更新失败", "更新清单格式不对，可能服务器上的文件坏了。") }
            return
        }

        let newer = Self.isNewer(m.version, than: Self.currentVersion)
            || (m.version == Self.currentVersion && (m.build ?? 0) > Self.currentBuild)

        guard newer else {
            if interactive {
                alert("已是最新版本", "当前 \(Self.displayVersion)，服务器上是 \(m.version)。")
            }
            return
        }

        offerUpdate(m)
    }

    // MARK: 提示与安装

    private func offerUpdate(_ m: UpdateManifest) {
        NSApp.activate(ignoringOtherApps: true)

        let a = NSAlert()
        a.messageText = "发现新版本 \(m.version)"
        var info = "当前版本：\(Self.displayVersion)\n新版本：\(m.version)"
        if let s = m.size, s > 0 {
            info += "  ·  \(ByteCountFormatter.string(fromByteCount: s, countStyle: .file))"
        }
        if let n = m.notes, !n.isEmpty {
            info += "\n\n\(n)"
        }
        a.informativeText = info
        a.alertStyle = .informational
        a.addButton(withTitle: "下载并安装")
        a.addButton(withTitle: "稍后")

        guard a.runModal() == .alertFirstButtonReturn else { return }
        download(m)
    }

    private func download(_ m: UpdateManifest) {
        guard let url = URL(string: m.downloadURL) else {
            alert("下载地址无效", m.downloadURL)
            return
        }

        // 让用户知道在下载。这一步可能要几秒，没反馈会以为点了没反应。
        let prog = DownloadPanel(text: "正在下载 \(m.version)…")
        prog.show()

        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        req.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.downloadTask(with: req) { [weak self] tmp, resp, err in
            DispatchQueue.main.async {
                prog.close()
                guard let self = self else { return }
                if let err = err {
                    self.alert("下载失败", err.localizedDescription)
                    return
                }
                guard let tmp = tmp else {
                    self.alert("下载失败", "服务器没有返回文件。")
                    return
                }
                self.verifyAndInstall(tmp, manifest: m)
            }
        }.resume()
    }

    private func verifyAndInstall(_ tmp: URL, manifest m: UpdateManifest) {
        let fm = FileManager.default

        guard let expected = m.sha256?.lowercased(), !expected.isEmpty else {
            alert("拒绝安装", "更新清单里没有 sha256，无法确认这个包有没有被篡改。\n\n请联系发版的人补上 sha256 再试。")
            return
        }
        guard let data = try? Data(contentsOf: tmp) else {
            alert("安装失败", "读不到下载下来的文件。")
            return
        }
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == expected else {
            NSLog("TempBar 更新包校验失败：期望 \(expected)，实际 \(got)")
            alert("包校验不通过，已中止", "下载到的文件和服务器上的不一致，可能传输中损坏了。\n\n期望 \(expected.prefix(16))…\n实际 \(got.prefix(16))…")
            return
        }

        // 解压到临时目录
        let work = fm.temporaryDirectory.appendingPathComponent("TempBarUpdate-\(UUID().uuidString)")
        try? fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zip = work.appendingPathComponent("TempBar.zip")
        try? fm.copyItem(at: tmp, to: zip)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, work.path]
        do { try unzip.run(); unzip.waitUntilExit() } catch {
            alert("解压失败", error.localizedDescription)
            return
        }
        guard unzip.terminationStatus == 0 else {
            alert("解压失败", "ditto 返回 \(unzip.terminationStatus)")
            return
        }

        let newApp = work.appendingPathComponent("TempBar.app")
        guard fm.fileExists(atPath: newApp.path) else {
            alert("包结构不对", "解压后没找到 TempBar.app。")
            return
        }

        let target = Bundle.main.bundlePath
        guard target.hasPrefix("/Applications/") || target.hasPrefix(NSHomeDirectory() + "/Applications/") else {
            // 从 build 目录跑的，替换那个目录没意义
            alert("请手动替换", "当前是从 \(target) 运行的，不在「应用程序」里。\n\n新版本已经解压到：\n\(newApp.path)")
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            return
        }

        install(newApp: newApp, to: target)
    }

    /// 替换安装。
    ///
    /// 不能在进程还活着的时候覆盖自己（会损坏正在运行的 bundle），
    /// 所以起一个 bash 脚本：等主进程退出 → 替换 → 清隔离属性 → 重新打开。
    private func install(newApp: URL, to target: String) {
        let script = """
        #!/bin/bash
        # 等 TempBar 自己退出（最多等 15 秒）
        for i in $(seq 1 30); do
            if ! pgrep -f "\(target)/Contents/MacOS/TempBar" >/dev/null; then break; fi
            sleep 0.5
        done
        rm -rf "\(target)"
        /usr/bin/ditto "\(newApp.path)" "\(target)"
        /usr/bin/xattr -cr "\(target)"
        /usr/bin/open "\(target)"
        rm -rf "$(dirname "\(newApp.path)")"
        """

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("tempbar-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        } catch {
            alert("安装失败", "写安装脚本失败：\(error.localizedDescription)")
            return
        }

        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/bin/bash")
        t.arguments = [path.path]
        do {
            try t.run()
        } catch {
            alert("安装失败", error.localizedDescription)
            return
        }

        // 脚本在跑，我们退出让它完成替换
        NSApp.terminate(nil)
    }

    // MARK: 小工具

    private func alert(_ title: String, _ body: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = body
        a.alertStyle = .informational
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

/// 下载时那个很轻的浮层。只有一个转圈和一行字。
private final class DownloadPanel {
    private var window: NSWindow?
    private let text: String

    init(text: String) { self.text = text }

    func show() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 76),
                         styleMask: [.titled, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.standardWindowButton(.closeButton)?.isHidden = true
        w.standardWindowButton(.miniaturizeButton)?.isHidden = true
        w.standardWindowButton(.zoomButton)?.isHidden = true

        let v = NSView(frame: w.contentLayoutRect)
        let spin = NSProgressIndicator()
        spin.style = .spinning
        spin.controlSize = .small
        spin.startAnimation(nil)
        spin.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(spin)
        v.addSubview(label)
        NSLayoutConstraint.activate([
            spin.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
            spin.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: spin.trailingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor)
        ])
        w.contentView = v
        w.center()
        w.orderFrontRegardless()
        window = w
    }

    func close() { window?.close(); window = nil }
}
