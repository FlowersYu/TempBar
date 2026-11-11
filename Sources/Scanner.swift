import Foundation
import CoreBluetooth
import UserNotifications

/// 被动监听 BTHome 广播。
///
/// 关键点：`allowDuplicates = true`。默认值 false 会在看到某设备第一次广播后
/// 就再也不回调它，那样温度永远停在第一次的读数上。
/// 开着它才能每 10 秒拿到一次新包，代价只是多一点 CPU（几乎可忽略）。
final class Scanner: NSObject {
    static let shared = Scanner()

    private var central: CBCentralManager?
    private(set) var bluetoothOff = false
    private(set) var unauthorized = false
    private(set) var running = false

    var onStateChange: (() -> Void)?

    /// 设备 → 上次 packet_id，用来丢弃重复上报
    private var lastPacket: [String: Int] = [:]

    func start() {
        guard central == nil else {
            if central?.state == .poweredOn { beginScan() }
            return
        }
        // queue 传 nil 就走主线程，回调里可以直接改 UI 状态，省掉一次 dispatch
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionShowPowerAlertKey: false
        ])
    }

    func stop() {
        running = false
        central?.stopScan()
        onStateChange?()
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn, !running else { return }
        running = true
        central.scanForPeripherals(
            withServices: BLEFormat.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        onStateChange?()
    }

    /// 传 nil 表示扫全部设备，用来做"附近有什么"的诊断
    func restartScan(allDevices: Bool) {
        guard let central, central.state == .poweredOn else { return }
        central.stopScan()
        running = true
        central.scanForPeripherals(
            withServices: allDevices ? nil : BLEFormat.scanServices,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        onStateChange?()
    }
}

extension Scanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            bluetoothOff = false
            unauthorized = false
            beginScan()
        case .poweredOff:
            bluetoothOff = true
            running = false
        case .unauthorized:
            unauthorized = true
            running = false
        default:
            running = false
        }
        onStateChange?()
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // RSSI 127 是"不可用"的哨兵值，不是真实信号强度
        let rssi = RSSI.intValue
        guard rssi != 127, rssi < 0 else { return }

        guard let sd = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data],
              let reading = BLEFormat.parse(serviceData: sd) else { return }

        // 诊断日志：默认关闭。排查"读数不合理"时打开它，
        // 把原始广播字节写到 Application Support/TempBar/raw.log，
        // 有字节才能定论，否则只能猜。
        // 打开方式：defaults write <bundleid> tempbar.dump -bool true
        let dump = ProcessInfo.processInfo.environment["TEMPBAR_DUMP"] == "1"
            || UserDefaults.standard.bool(forKey: "tempbar.dump")
        if dump {
            let hex = sd.map { uuid, d in
                "\(uuid.uuidString)=\(d.map { String(format: "%02x", $0) }.joined())"
            }.joined(separator: " ")
            let nm = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
                ?? peripheral.name ?? "-"
            let line = "RAW name=\(nm) rssi=\(rssi) \(hex) "
                + "→ T=\(reading.temperature.map { String(format: "%.2f", $0) } ?? "-") "
                + "H=\(reading.humidity.map { String(format: "%.1f", $0) } ?? "-") "
                + "pid=\(reading.packetID.map(String.init) ?? "-")\n"
            NSLog("TempBar " + line)
            // 同时写文件：log show 的谓词在不同系统版本上行为不一致，
            // 排查时用文件最省事
            let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                in: .userDomainMask).first!
            let dir = base.appendingPathComponent("TempBar", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true)
            let f = dir.appendingPathComponent("raw.log")
            if let h = try? FileHandle(forWritingTo: f) {
                h.seekToEndOfFile()
                h.write(line.data(using: .utf8)!)
                try? h.close()
            } else {
                try? line.write(to: f, atomically: true, encoding: .utf8)
            }
        }

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
            ?? ""

        // 用 UUID 当 key：macOS 不暴露真实 MAC，UUID 是系统给的稳定标识，
        // 同一台设备每次扫描都是同一个 UUID，够用。
        let id = peripheral.identifier.uuidString

        // 重复包过滤放在这儿，避免把同一个读数反复塞进历史
        if let pid = reading.packetID {
            if lastPacket[id] == pid { return }
            lastPacket[id] = pid
        }

        // 合理性检查：>200° 之类的值直接丢，不进状态、不进历史、不弹通知。
        // 放在 ingest 之前，这样界面、曲线、最高最低温三处一起干净。
        let sane = reading.sanitized()
        guard !sane.isEmpty else { return }

        AppState.shared.ingest(id: id, name: name, reading: sane, rssi: rssi)
        AlertCenter.shared.evaluate(reading: sane, deviceName: name)
    }
}

// MARK: - 阈值提醒

/// 通知要克制：温度在阈值附近来回抖动时不能每条广播都弹一次。
/// 做法是"迟滞 + 冷却期"：超阈值要超出 0.3 才触发，触发后 30 分钟内不重复。
final class AlertCenter {
    static let shared = AlertCenter()

    private var lastFire: [String: Date] = [:]
    private var armed = true
    private let cooldown: TimeInterval = 30 * 60
    private let hysteresis: Double = 0.3

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(reading: Reading, deviceName: String) {
        let th = AppState.shared.thresholds
        guard th.enabled else { return }

        var messages: [String] = []

        if let t = reading.temperature {
            // 迟滞：先要回到范围内才重新"上膛"，避免边界抖动连发
            if t > th.maxTemp + hysteresis {
                if armed { messages.append("温度 \(fmt(t))°C，高于上限 \(fmt(th.maxTemp))°C") }
                armed = false
            } else if t < th.minTemp - hysteresis {
                if armed { messages.append("温度 \(fmt(t))°C，低于下限 \(fmt(th.minTemp))°C") }
                armed = false
            } else if t <= th.maxTemp && t >= th.minTemp {
                armed = true
            }
        }

        if messages.isEmpty { return }

        let key = "temp"
        if let last = lastFire[key], Date().timeIntervalSince(last) < cooldown { return }
        lastFire[key] = Date()

        let content = UNMutableNotificationContent()
        content.title = deviceName.isEmpty ? "温湿度提醒" : deviceName
        content.body = messages.joined(separator: "\n")
        content.sound = .default

        let req = UNNotificationRequest(
            identifier: "tempbar.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(req)
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }
}
