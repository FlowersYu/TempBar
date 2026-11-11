import Foundation
import CoreBluetooth

// MARK: - 历史采样

struct Sample: Codable {
    var t: Date
    var temp: Double?
    var hum: Double?
}

// MARK: - 设备

final class Device {
    let id: String
    /// 固件广播里带的名字，每收一条广播都会被覆盖，不能拿来存用户改的名字
    var name: String
    /// 用户自己起的名字。非空时优先于固件名。
    /// 单独放一个字段是关键：之前直接改 `name` 会被下一条广播冲掉。
    var customName: String?
    var reading: Reading
    var rssi: Int
    var lastSeen: Date
    var history: [Sample]

    init(id: String, name: String) {
        self.id = id
        self.name = name
        self.reading = Reading()
        self.rssi = 0
        self.lastSeen = Date()
        self.history = []
    }

    /// 界面上显示的名字：用户改过就用用户的，否则用固件名
    var displayName: String {
        if let c = customName?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty {
            return c
        }
        return firmwareName
    }

    var firmwareName: String {
        name.isEmpty ? "未命名设备" : name
    }

    var hasCustomName: Bool {
        !(customName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    /// 超过这个时间没收到广播，就认为设备不在附近
    var isStale: Bool {
        Date().timeIntervalSince(lastSeen) > 90
    }
}

// MARK: - 阈值

struct Thresholds: Codable {
    var enabled: Bool = false
    var minTemp: Double = 18
    var maxTemp: Double = 28
    var minHum: Double = 30
    var maxHum: Double = 70
}

// MARK: - 数据中枢

/// 全局唯一的运行状态。所有 UI 都从这儿读，改完调 `notifyChanged()`。
final class AppState {
    static let shared = AppState()

    private(set) var devices: [String: Device] = [:]
    private(set) var order: [String] = []

    /// 菜单栏和小组件显示哪一台
    var primaryID: String? {
        didSet {
            guard oldValue != primaryID else { return }
            persist()
            notifyChanged()
        }
    }

    var thresholds = Thresholds() {
        didSet {
            thresholds.save()
            notifyChanged()
        }
    }

    /// 界面刷新回调（主线程）
    var onChange: (() -> Void)?

    /// 首次收到数据时回调一次，用来做"已连接"提示
    var onFirstDevice: ((Device) -> Void)?
    private var sawFirstDevice = false

    private init() {
        load()
    }

    // MARK: 读

    var primary: Device? {
        // 指定设备有当前读数，就用它
        if let id = primaryID, let d = devices[id], !d.reading.isEmpty { return d }
        // 指定设备还没出现（或上次的读数已经作废），退回到最近活跃且有读数的那台。
        // 这里必须要求"有读数"：state.json 里会恢复出只有历史、没有读数的设备，
        // 直接返回它会让界面一直显示"等待温度计"，哪怕旁边另一台正在广播。
        if let active = sortedDevices.first(where: { !$0.reading.isEmpty }) { return active }
        // 全都还没读数，就退回最近活跃的那台，至少名字和"几分钟前"是准的
        if let id = primaryID, let d = devices[id] { return d }
        return sortedDevices.first
    }

    var sortedDevices: [Device] {
        order.compactMap { devices[$0] }.sorted { $0.lastSeen > $1.lastSeen }
    }

    // MARK: 写

    /// 收到一条广播。返回 true 表示这次真的更新了数值（用于通知判定）。
    @discardableResult
    func ingest(id: String, name: String, reading: Reading, rssi: Int) -> Bool {
        let now = Date()
        let dev: Device
        if let existing = devices[id] {
            dev = existing
        } else {
            dev = Device(id: id, name: name)
            devices[id] = dev
            order.append(id)
            // 第一台自动成为主设备，省得用户还要去设置里点一下
            if primaryID == nil { primaryID = id }
        }

        if !name.isEmpty { dev.name = name }
        dev.rssi = rssi
        dev.lastSeen = now
        // 同一条广播重复上报（packet_id 相同）就不算新数据，
        // 否则历史里会堆满同一个点，通知也会被误触发。
        let isNewPacket: Bool
        if let pid = reading.packetID, let old = dev.reading.packetID {
            isNewPacket = pid != old
        } else {
            isNewPacket = reading != dev.reading || reading.temperature == nil
        }
        guard isNewPacket || dev.reading.isEmpty else {
            notifyChanged()
            return false
        }

        dev.reading = reading
        appendSample(dev: dev, at: now)

        if !sawFirstDevice {
            sawFirstDevice = true
            onFirstDevice?(dev)
        }
        notifyChanged()
        persistThrottled()
        return true
    }

    private func appendSample(dev: Device, at now: Date) {
        guard dev.reading.temperature != nil || dev.reading.humidity != nil else { return }
        // 越界读数不参与采样，否则曲线纵轴会被 236° 这种值撑爆
        let tempOK = dev.reading.hasSaneTemp

        // 采样策略要同时满足三件事：
        //   1. 曲线要有足够密度（不能 5 分钟一个点）
        //   2. 存储不能无限膨胀（10 秒一条广播，一天有 8640 条）
        //   3. 温度突变要能立刻反映（空调刚开的那一下不能在图上消失）
        //
        // 做法：最短间隔 30 秒；超过 30 秒就记；不足 30 秒时，
        // 只有变化足够大（明显是事件而不是噪声）才提前记。
        if let last = dev.history.last {
            let dt = now.timeIntervalSince(last.t)
            if dt < 30 {
                let dTemp = abs((last.temp ?? 0) - (dev.reading.temperature ?? 0))
                let dHum = abs((last.hum ?? 0) - (dev.reading.humidity ?? 0))
                // 大变化优先：0.5° 或 3% 以上，说明真的在变，值得记一个点
                guard dTemp > 0.5 || dHum > 3.0 else { return }
            }
        }

        dev.history.append(Sample(t: now,
                                 temp: tempOK ? dev.reading.temperature : nil,
                                 hum: dev.reading.humidity))
        prune(dev: dev)
    }

    /// 只留最近 7 天，并顺手清掉历史里的越界采样。
    private func prune(dev: Device) {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        if let idx = dev.history.firstIndex(where: { $0.t > cutoff }), idx > 0 {
            dev.history.removeFirst(idx)
        }
        if dev.history.count > 12000 {
            dev.history.removeFirst(dev.history.count - 12000)
        }
        // 老数据里可能已经存着 236° 这种值（文件是旧版本写的），
        // 每次 prune 顺手过滤一次，不用等用户手动重置。
        let before = dev.history.count
        dev.history.removeAll { s in
            if let t = s.temp, abs(t) > Reading.plausibleTempLimit { return true }
            if let h = s.hum, h < -5 || h > 105 { return true }
            return false
        }
        if dev.history.count != before {
            NSLog("TempBar 清掉 \(before - dev.history.count) 条越界历史采样（\(dev.displayName)）")
        }
    }

    /// 取最近 N 小时的历史
    func history(of dev: Device?, hours: Double) -> [Sample] {
        guard let dev else { return [] }
        let cutoff = Date().addingTimeInterval(-hours * 3600)
        return dev.history.filter { $0.t >= cutoff }
    }

    /// 当天（自然日，从 00:00 起）的最高 / 最低温度。
    ///
    /// 仿苹果主题要用。注意这里算的是"今天已经出现过的"，不是天气预报 ——
    /// 我们没有天气数据源，也不想联网。所以早上刚开始记录时，
    /// 最高最低可能就是这个时刻的温度，随着一天推移才逐渐摊开。
    /// 历史里没有今天的有效采样时返回 nil，界面上显示 "--"。
    func todayRange(of dev: Device?) -> (low: Double, high: Double)? {
        guard let dev else { return nil }
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let today = dev.history.filter { $0.t >= startOfDay }.compactMap(\.temp)
        guard !today.isEmpty else { return nil }
        // 当前读数也参与比较：落盘是节流的，最新一个点可能还没写进 history
        var vals = today
        if let cur = dev.reading.temperature { vals.append(cur) }
        guard let lo = vals.min(), let hi = vals.max() else { return nil }
        return (lo, hi)
    }

    /// 清理长时间不出现、且从未有数据的历史设备
    func dropGhosts() {
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        for (id, d) in devices {
            if d.reading.isEmpty && d.lastSeen < cutoff {
                devices.removeValue(forKey: id)
                order.removeAll { $0 == id }
            }
        }
    }

    /// 清掉历史里已经存下的越界采样。
    ///
    /// 为什么需要单独一步：`prune` 只在 appendSample 时跑，
    /// 而那些 236° 的数据是旧版本就写进 state.json 的，
    /// 不触发新采样就永远不会被清掉 —— 实测启动后历史里仍有
    /// 236.3 / 236.5 / 235.8 一堆。曲线纵轴还是会被撑爆。
    /// 启动时先扫一遍，一次清干净。
    func scrubOutOfRangeHistory() {
        var removed = 0
        for d in devices.values {
            let before = d.history.count
            d.history.removeAll { s in
                if let t = s.temp, abs(t) > Reading.plausibleTempLimit { return true }
                if let h = s.hum, h < -5 || h > 105 { return true }
                return false
            }
            removed += before - d.history.count
        }
        if removed > 0 {
            NSLog("TempBar 启动清理：移除 \(removed) 条越界历史采样")
            persist()
        }
    }

    /// 清空所有设备（自检和"重置"用）
    func clearAll() {
        devices.removeAll()
        order.removeAll()
        primaryID = nil
        notifyChanged()
    }

    /// 给设备改一个用户自定义的名字。传 nil / 空字符串表示恢复成固件名。
    func setCustomName(_ name: String?, for deviceID: String) {
        guard let dev = devices[deviceID] else {
            // 以前这里静默 return：调用方以为改成功了，界面上什么都没变。
            // 留一条日志，出问题时能从控制台直接看出是"设备不在了"还是"名字没存"。
            NSLog("TempBar 改名失败：找不到设备 \(deviceID)")
            return
        }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        dev.customName = trimmed.isEmpty ? nil : trimmed
        persist()
        notifyChanged()
    }

    func notifyChanged() {
        onChange?()
    }

    // MARK: 持久化

    private struct Snapshot: Codable {
        var primaryID: String?
        var devices: [SavedDevice]
    }

    private struct SavedDevice: Codable {
        var id: String
        var name: String
        /// 老版本 state.json 里没有这个字段，解码成 nil 正好
        var customName: String?
        var history: [Sample]
    }

    private static var dir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        // 自检模式下用独立目录：否则跑一次测试就会把伪造设备写进用户真实的
        // state.json，把真实温度计的历史冲掉，下次启动还显示测试数据。
        let name = ProcessInfo.processInfo.environment["TEMPBAR_STATE_DIR"] ?? "TempBar"
        let d = base.appendingPathComponent(name, isDirectory: true)
        if !FileManager.default.fileExists(atPath: d.path) {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        return d
    }

    private static var file: URL { dir.appendingPathComponent("state.json") }

    private var saveWork: DispatchWorkItem?
    private var lastSaveAt = Date.distantPast

    /// 高频写入会拖慢主线程，攒几秒写一次。
    ///
    /// 注意不能用"每次取消上一个"的纯防抖：设备 10 秒广播一次、延迟 3 秒，
    /// 看起来没问题；但只要广播比延迟更密（或演示模式 2 秒一条），
    /// 每个任务都会在到期前被取消，结果一次都写不进去。
    /// 所以加一个兜底：距上次真正写盘超过 15 秒就立刻写。
    private func persistThrottled() {
        if Date().timeIntervalSince(lastSaveAt) > 15 {
            persist()
            return
        }
        guard saveWork == nil else { return }   // 已有排队的写入，不必重复安排
        let w = DispatchWorkItem { [weak self] in
            self?.saveWork = nil
            self?.persist()
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: w)
    }

    /// 自检收尾时置 false，阻止"退出时写盘"把刚删掉的测试目录又建回来
    static var persistEnabled = true

    func persist() {
        guard AppState.persistEnabled else { return }
        lastSaveAt = Date()
        let snap = Snapshot(
            primaryID: primaryID,
            devices: sortedDevices.map {
                SavedDevice(id: $0.id, name: $0.name,
                            customName: $0.customName, history: $0.history)
            }
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        // 写盘失败以前是彻底静默的：改名、历史全都不落盘，界面上又看不出来。
        // 留一条日志，用户截图控制台就能定位（权限、磁盘满、路径被挡）。
        do {
            try data.write(to: Self.file, options: .atomic)
        } catch {
            NSLog("TempBar state.json 写入失败：\(error)")
        }
        thresholds.save()
    }

    private func load() {
        thresholds = Thresholds.load()
        guard let data = try? Data(contentsOf: Self.file),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        // 只恢复名字和历史；读数要等真实广播，不拿旧值冒充"当前温度"
        for s in snap.devices {
            let d = Device(id: s.id, name: s.name)
            d.customName = s.customName
            d.history = s.history
            devices[s.id] = d
            order.append(s.id)
        }
        primaryID = snap.primaryID
    }
}

// MARK: - 阈值存储

extension Thresholds {
    private static let key = "tempbar.thresholds"

    static func load() -> Thresholds {
        guard let data = UserDefaults.standard.data(forKey: key),
              let t = try? JSONDecoder().decode(Thresholds.self, from: data) else {
            return Thresholds()
        }
        return t
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
