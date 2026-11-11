import Foundation
import CoreBluetooth

/// 一次广播里解析出来的读数。字段都可能缺失：不同固件、不同广播格式带的数据不一样。
struct Reading: Codable, Equatable {
    var temperature: Double?
    var humidity: Double?
    var battery: Int?
    var voltage: Double?
    var packetID: Int?

    var isEmpty: Bool { temperature == nil && humidity == nil }

    /// 物理上不可能的读数一律丢掉。
    ///
    /// 背景：之前图表出现过 "23.5° — 236.5°"，还有一条 236 度的曲线。
    /// 抓原始字节确认过解码是对的，问题出在广播本身被干扰/固件算错，
    /// 吐出一个 2365（÷100 后 23.65 才对，但某次 device_info 位不同就被当成别的格式）。
    /// 不管原因，这种值留在界面上只会让人以为是程序坏了，
    /// 也会把曲线的纵轴撑爆、把最高最低温算歪，所以入口就掐掉。
    ///
    /// 阈值取 ±200，比地球上任何室温量程都宽，不会误杀正常读数。
    static let plausibleTempLimit: Double = 200

    /// 返回一个经过合理性检查的读数。越界的字段置 nil，其余保留。
    func sanitized() -> Reading {
        var r = self
        if let t = r.temperature, !(-Self.plausibleTempLimit...Self.plausibleTempLimit).contains(t) {
            r.temperature = nil
        }
        // 湿度 0~100 是硬定义。留一点余量给固件的四舍五入。
        if let h = r.humidity, !(-5.0...105.0).contains(h) {
            r.humidity = nil
        }
        // 电量同理
        if let b = r.battery, !(0...100).contains(b) {
            r.battery = nil
        }
        return r
    }

    /// 温度是否是一个可信值（历史清洗时用）
    var hasSaneTemp: Bool {
        guard let t = temperature else { return false }
        return abs(t) <= Self.plausibleTempLimit
    }
}

/// 广播格式解析。
///
/// 支持两种，因为 pvvx 固件两种都能输出：
///   - BTHome v2（service data UUID 0xFCD2）—— 你现在刷的这个
///   - ATC1441（service data UUID 0x181A）—— pvvx 的 "Custom" 格式，留作兼容
enum BLEFormat {
    static let bthome = CBUUID(string: "FCD2")
    static let atc = CBUUID(string: "181A")

    /// 需要订阅的 service UUID，扫描时用来过滤，减少无关回调
    static var scanServices: [CBUUID] { [bthome, atc] }

    static func parse(serviceData: [CBUUID: Data]) -> Reading? {
        for (uuid, data) in serviceData {
            let bytes = [UInt8](data)
            if uuid == bthome, let r = decodeBTHome(bytes), !r.isEmpty { return r }
            if uuid == atc, let r = decodeATC(bytes), !r.isEmpty { return r }
        }
        return nil
    }

    // MARK: - BTHome v2

    /// payload 从 service data 的 value 开始（不含 UUID）。
    /// 结构：[device_info][object_id][data]...
    static func decodeBTHome(_ p: [UInt8]) -> Reading? {
        guard let first = p.first else { return nil }
        // bit5 是加密标志。pvvx 默认不加密，如果开了加密这里直接放弃，
        // 宁可显示"无数据"也不显示一个错数。
        if first & 0x20 != 0 { return nil }

        var r = Reading()
        var i = 1
        while i < p.count {
            let oid = p[i]
            switch oid {
            case 0x00: // packet id, uint8
                guard i + 1 < p.count else { return r }
                r.packetID = Int(p[i + 1]); i += 2

            case 0x01: // battery, uint8, %
                guard i + 1 < p.count else { return r }
                r.battery = Int(p[i + 1]); i += 2

            case 0x02: // temperature, sint16, 0.01
                guard i + 2 < p.count else { return r }
                r.temperature = Double(le16Signed(p, i + 1)) / 100.0; i += 3

            case 0x03: // humidity, uint16, 0.01
                guard i + 2 < p.count else { return r }
                r.humidity = Double(le16(p, i + 1)) / 100.0; i += 3

            case 0x04, 0x05: // pressure / illuminance, uint24 —— 本设备用不到，跳过
                guard i + 3 < p.count else { return r }
                i += 4

            case 0x08: // dewpoint, sint16, 0.01 —— 跳过
                guard i + 2 < p.count else { return r }
                i += 3

            case 0x0C: // voltage, uint16, 0.001 V
                guard i + 2 < p.count else { return r }
                r.voltage = Double(le16(p, i + 1)) / 1000.0; i += 3

            case 0x2E: // humidity, uint8, 1%
                guard i + 1 < p.count else { return r }
                r.humidity = Double(p[i + 1]); i += 2

            case 0x45: // temperature, sint16, 0.1
                guard i + 2 < p.count else { return r }
                r.temperature = Double(le16Signed(p, i + 1)) / 10.0; i += 3

            default:
                // 遇到不认识的 object id 就停：后面的长度未知，继续解析必然错位。
                return r
            }
        }
        return r
    }

    // MARK: - ATC1441

    /// [mac(6)][temp int16 /10][hum uint8][bat uint8][mV uint16][counter uint16]
    static func decodeATC(_ p: [UInt8]) -> Reading? {
        guard p.count >= 13 else { return nil }
        var r = Reading()
        r.temperature = Double(le16Signed(p, 6)) / 10.0
        r.humidity = Double(p[8])
        r.battery = Int(p[9])
        r.voltage = Double(le16(p, 10)) / 1000.0
        return r
    }

    // MARK: - 小工具

    private static func le16(_ p: [UInt8], _ i: Int) -> UInt16 {
        UInt16(p[i]) | (UInt16(p[i + 1]) << 8)
    }

    private static func le16Signed(_ p: [UInt8], _ i: Int) -> Int16 {
        Int16(bitPattern: le16(p, i))
    }
}
