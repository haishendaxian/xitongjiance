import Cocoa
import IOKit
import Darwin

// MARK: - SMC 读取（功耗）

struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt16 = 0
    var status: UInt16 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// 只读访问 AppleSMC，用于取 CPU 封装功耗等 SMC 键
final class SMCReader {
    private var conn: io_connect_t = 0
    private(set) var available = false

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return }
        available = true
    }

    deinit { close() }

    func close() {
        if conn != 0 { IOServiceClose(conn); conn = 0 }
        available = false
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        var outSize = MemoryLayout<SMCKeyData>.size
        return IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<SMCKeyData>.size, &output, &outSize) == KERN_SUCCESS
    }

    private func keyInfo(_ key: String) -> SMCKeyDataKeyInfo? {
        guard key.utf8.count == 4 else { return nil }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.data8 = 9
        guard call(&input, &output), output.keyInfo.dataSize > 0 else { return nil }
        return output.keyInfo
    }

    /// 读一个 4 字符键，返回原始字节
    func rawRead(_ key: String) -> [UInt8]? {
        guard let info = keyInfo(key) else { return nil }
        var input = SMCKeyData(), output = SMCKeyData()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }
        input.data8 = 5
        input.keyInfo.dataSize = info.dataSize
        guard call(&input, &output) else { return nil }
        var out: [UInt8] = []
        withUnsafeBytes(of: output.bytes) { buf in
            for i in 0..<Int(min(info.dataSize, 32)) { out.append(buf[i]) }
        }
        return out
    }

    /// sp96：有符号定点数，小数点后 6 位
    func readSp96(_ key: String) -> Double? {
        guard let b = rawRead(key), b.count >= 2 else { return nil }
        let raw = Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))
        let v = Double(raw) / 64.0
        return v > 0 ? v : nil
    }
}

// MARK: - 数据结构

struct VMStats64 {
    var free_count: UInt32 = 0
    var active_count: UInt32 = 0
    var inactive_count: UInt32 = 0
    var wire_count: UInt32 = 0
    var zero_fill_count: UInt64 = 0
    var reactivations: UInt64 = 0
    var pageins: UInt64 = 0
    var pageouts: UInt64 = 0
    var faults: UInt64 = 0
    var cow_faults: UInt64 = 0
    var lookups: UInt64 = 0
    var hits: UInt64 = 0
    var purges: UInt64 = 0
    var purgeable_count: UInt32 = 0
    var speculative_count: UInt32 = 0
    var decompressions: UInt64 = 0
    var compressions: UInt64 = 0
    var swapins: UInt64 = 0
    var swapouts: UInt64 = 0
    var compressor_page_count: UInt32 = 0
    var throttled_count: UInt32 = 0
    var external_page_count: UInt32 = 0
    var internal_page_count: UInt32 = 0
    var total_uncompressed_pages_in_compressor: UInt64 = 0
}

struct SwapUsage {
    var total: UInt64 = 0
    var avail: UInt64 = 0
    var used: UInt64 = 0
    var pagesize: UInt32 = 0
    var encrypted: UInt32 = 0
}

struct Sample {
    var cpuTotal: Double = 0
    var perCore: [Double] = []
    var load: [Double] = [0, 0, 0]
    var memUsed: Double = 0
    var memTotal: Double = 0
    var memFreeMB: Double = 0
    var memCompressed: Double = 0
    var memWired: Double = 0
    var memActive: Double = 0
    var swapUsedMB: Double = 0
    var diskUsed: Double = 0
    var diskTotal: Double = 0
    var diskFree: Double = 0
    var gpuMemMB: Double? = nil
    var gartMB: Double? = nil
    var gpuUtil: Double? = nil      // 按提交速率估算的活动度
    var cpuFreqMHz: Double? = nil    // CPU 当前平均频率（powermetrics）
    var gpuSubRate: Double = 0      // 每秒提交次数
    var tempText: String = "—"
    var tempValue: Double? = nil
    var netUp: Double = 0
    var netDown: Double = 0
    // 电源
    var batteryPct: Double = 0
    var batteryCharging = false
    var batteryPlugged = false
    var batteryFull = false
    var chargePower: Double? = nil      // 充电功率 W（电池净充电）
    var dischargePower: Double? = nil   // 功耗 W（电池放电）
    var cpuPower: Double? = nil         // CPU 封装功耗 W（SMC PCPT）
    var systemPower: Double? = nil      // 整机功耗 W（SMC 有 PSTR/PDTR 时）
    var packagePower: Double? = nil     // 封装功耗 W（powermetrics CPU+GPU 封装）
    var adapterWatts: Double? = nil
    var batteryTempC: Double? = nil
    var batteryMinutes: Double? = nil   // 剩余/需充满分钟

    /// 菜单栏与详情页展示用的「功耗」
    var displayPower: Double? {
        if batteryPlugged {
            return systemPower ?? packagePower ?? cpuPower
        }
        return dischargePower ?? packagePower ?? cpuPower
    }
}

// MARK: - 采集器

final class Reader {
    private var prevTicks: [UInt32] = []
    private let pageSize: UInt64
    private var gpuServices: [io_object_t] = []
    private var prevUp: UInt64 = 0
    private var prevDown: UInt64 = 0
    private var prevNetTime: Double = 0
    private var prevSubmissions: Double = 0
    private var prevGpuTime: Double = 0
    private var batteryService: io_object_t = 0
    private var smc: SMCReader?
    private var smcRetryAt: Double = 0
    private var smcFails = 0
    private var lastCpuPower: (v: Double, t: Double)?
    private var statsCache: (mtime: Date, temp: Double?, gpu: Double?, power: Double?, freq: Double?)?

    init() {
        var ps: vm_size_t = 0
        host_page_size(mach_host_self(), &ps)
        pageSize = UInt64(ps)
        smc = SMCReader()
        batteryService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        for className in ["IntelAccelerator", "IOAccelerator"] {
            var iter: io_iterator_t = 0
            if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iter) == KERN_SUCCESS {
                while case let svc = IOIteratorNext(iter), svc != 0 {
                    gpuServices.append(svc)
                }
                IOObjectRelease(iter)
            }
        }
        let n = netCounters()
        prevUp = n.up; prevDown = n.down
        prevNetTime = CACurrentMediaTime()
        prevGpuTime = prevNetTime
        if let sub = readSubmissions() { prevSubmissions = sub }
    }

    private func netCounters() -> (up: UInt64, down: UInt64) {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return (0, 0) }
        defer { freeifaddrs(ifap) }
        var up: UInt64 = 0, down: UInt64 = 0
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let ifa = cur.pointee
            if let addr = ifa.ifa_addr, Int32(addr.pointee.sa_family) == AF_LINK, let data = ifa.ifa_data {
                let name = String(cString: ifa.ifa_name)
                if name.hasPrefix("en") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    down += UInt64(d.ifi_ibytes)
                    up += UInt64(d.ifi_obytes)
                }
            }
            ptr = ifa.ifa_next
        }
        return (up, down)
    }

    private func readStats() -> (temp: Double?, gpu: Double?, power: Double?, freq: Double?) {
        let path = "/var/run/xitongjiance.stats"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let m = attrs[.modificationDate] as? Date else { return (nil, nil, nil, nil) }
        if let c = statsCache, c.mtime == m { return (c.temp, c.gpu, c.power, c.freq) }
        var temp: Double?, gpu: Double?, power: Double?, freq: Double?
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let k = String(parts[0]).trimmingCharacters(in: .whitespaces)
                let raw = String(parts[1]).trimmingCharacters(in: .whitespaces)
                let num = Double(raw.components(separatedBy: " ").first ?? raw)
                switch k {
                case "temp": temp = num
                case "gpu": gpu = num
                case "power": power = num
                case "freq": freq = num
                default: break
                }
            }
        }
        statsCache = (m, temp, gpu, power, freq)
        return (temp, gpu, power, freq)
    }

    private func gpuStats() -> [String: Any]? {
        guard !gpuServices.isEmpty else { return nil }
        var merged: [String: Any] = [:]
        for svc in gpuServices {
            for prop in ["PerformanceStatistics", "AGCInfo"] {
                if let raw = IORegistryEntryCreateCFProperty(svc, prop as CFString, kCFAllocatorDefault, 0),
                   let d = raw.takeRetainedValue() as? [String: Any] {
                    for (k, v) in d { merged[k] = v }
                }
            }
        }
        return merged.isEmpty ? nil : merged
    }

    private func readSubmissions() -> Double? {
        guard let d = gpuStats(), let n = d["fSubmissionsSinceLastCheck"] as? NSNumber else { return nil }
        return n.doubleValue
    }

    // MARK: 电源

    private var smoothCharge: Double?
    private var smoothDischarge: Double?

    private func batteryProperties() -> [String: Any]? {
        guard batteryService != 0 else { return nil }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(batteryService, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = unmanaged?.takeRetainedValue() as? [String: Any] else { return nil }
        return dict
    }

    private func ema(_ prev: inout Double?, _ value: Double) -> Double {
        guard let p = prev else { prev = value; return value }
        let v = p + (value - p) * 0.35
        prev = v
        return v
    }

    private func applyPower(to s: inout Sample) {
        guard let d = batteryProperties() else { return }
        func num(_ k: String) -> Double? { (d[k] as? NSNumber)?.doubleValue }
        func flag(_ k: String) -> Bool { (d[k] as? NSNumber)?.boolValue ?? false }

        s.batteryCharging = flag("IsCharging")
        s.batteryPlugged = flag("ExternalConnected")
        s.batteryFull = flag("FullyCharged")
        if let cur = num("CurrentCapacity"), let maxCap = num("MaxCapacity"), maxCap > 0 {
            s.batteryPct = max(0, min(100, cur / maxCap * 100))
        }
        if let t = num("Temperature") {
            let c = t / 10.0 - 273.15
            if c > -20, c < 120 { s.batteryTempC = c }
        }
        if let a = d["AdapterDetails"] as? [String: Any], let w = (a["Watts"] as? NSNumber)?.doubleValue, w > 0 {
            s.adapterWatts = w
        }

        let voltageV = (num("Voltage") ?? 0) / 1000.0
        var amps = num("InstantAmperage") ?? num("Amperage") ?? 0
        if abs(amps) > 20000 { amps = num("Amperage") ?? 0 }   // 个别机型瞬时值异常，退回 Amperage
        let watts = abs(voltageV * amps / 1000.0)

        if s.batteryCharging, voltageV > 1, watts < 150 {
            s.chargePower = ema(&smoothCharge, watts)
        } else if s.batteryPlugged {
            s.chargePower = 0   // 已接电源但未充电（已充满或暂停充电）
        }
        if !s.batteryPlugged, voltageV > 1, watts < 150 {
            s.dischargePower = ema(&smoothDischarge, watts)
        }

        // 剩余 / 充满时间
        if s.batteryCharging, let full = num("AvgTimeToFull"), full > 0, full < 2000 {
            s.batteryMinutes = full
        } else if !s.batteryPlugged, let empty = num("AvgTimeToEmpty"), empty > 0, empty < 2000 {
            s.batteryMinutes = empty
        }

        // SMC 功耗：整机总功耗（若机型提供）与 CPU 封装功耗
        let now = CACurrentMediaTime()
        if smc == nil, now >= smcRetryAt {
            smcRetryAt = now + 5
            smc = SMCReader()
            smcFails = 0
        }
        if let smc = smc, smc.available {
            if let p = smc.readSp96("PCPT") ?? smc.readSp96("PCTR") {
                s.cpuPower = p
                lastCpuPower = (p, now)
                smcFails = 0
            } else {
                smcFails += 1
                if let last = lastCpuPower, now - last.t < 8 { s.cpuPower = last.v }
                if smcFails >= 3 {   // 连接失效，重建
                    smc.close()
                    self.smc = nil
                    smcRetryAt = now + 4
                }
            }
            s.systemPower = smc.readSp96("PSTR") ?? smc.readSp96("PDTR")
        }
        if s.packagePower == nil { s.packagePower = s.cpuPower }
        if s.cpuPower == nil { s.cpuPower = s.packagePower }
    }

    func sample() -> Sample {
        var s = Sample()

        // CPU
        var info: processor_info_array_t?
        var numInfo: mach_msg_type_number_t = 0
        var numCPU: natural_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &numInfo) == KERN_SUCCESS, let p = info {
            let count = Int(numCPU) * 4
            if prevTicks.count == count {
                var busyAll: Double = 0, totalAll: Double = 0
                for c in 0..<Int(numCPU) {
                    let base = c * 4
                    var busy: Double = 0, total: Double = 0
                    for k in 0..<4 {
                        let now = UInt32(p[base + k]), old = prevTicks[base + k]
                        let d = now >= old ? Double(now - old) : 0
                        total += d
                        if k != 2 { busy += d }
                    }
                    busyAll += busy; totalAll += total
                    s.perCore.append(total > 0 ? busy / total * 100 : 0)
                }
                s.cpuTotal = totalAll > 0 ? busyAll / totalAll * 100 : 0
            } else {
                s.perCore = [Double](repeating: 0, count: Int(numCPU))
            }
            var ticks = [UInt32](repeating: 0, count: count)
            for i in 0..<count { ticks[i] = UInt32(p[i]) }
            prevTicks = ticks
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: p), vm_size_t(numInfo) * vm_size_t(MemoryLayout<integer_t>.size))
        }
        var loads = [Double](repeating: 0, count: 3)
        loads.withUnsafeMutableBufferPointer { _ = getloadavg($0.baseAddress, 3) }
        s.load = loads

        // 内存
        var vm = VMStats64()
        var vmCount = mach_msg_type_number_t(MemoryLayout<VMStats64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) {
                host_statistics64(mach_host_self(), 4, $0, &vmCount)
            }
        }
        s.memTotal = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if kr == KERN_SUCCESS {
            let active = Double(vm.active_count) * Double(pageSize)
            let wired = Double(vm.wire_count) * Double(pageSize)
            let comp = Double(vm.compressor_page_count) * Double(pageSize)
            s.memActive = active / 1_073_741_824.0
            s.memUsed = (active + wired + comp) / 1_073_741_824.0
            s.memWired = wired / 1_073_741_824.0
            s.memCompressed = comp / 1_073_741_824.0
            s.memFreeMB = Double(vm.free_count) * Double(pageSize) / 1_048_576.0
        }
        var sw = SwapUsage()
        var swSize = MemoryLayout<SwapUsage>.size
        var mib: [Int32] = [CTL_VM, 5]
        if sysctl(&mib, 2, &sw, &swSize, nil, 0) == 0 { s.swapUsedMB = Double(sw.used) / 1_048_576.0 }

        // 硬盘
        var st = statfs()
        if statfs("/", &st) == 0 {
            let b = Double(st.f_bsize)
            s.diskTotal = Double(st.f_blocks) * b / 1_073_741_824.0
            s.diskFree = Double(st.f_bavail) * b / 1_073_741_824.0
            s.diskUsed = s.diskTotal - s.diskFree
        }

        // 后台守护采集：CPU 温度、GPU 使用率、封装功耗
        let lst = readStats()
        if let t = lst.temp {
            s.tempValue = t
            s.tempText = String(format: "%.0f°", t)
        }
        if let g = lst.gpu { s.gpuUtil = max(0, min(100, g)) }
        if let p = lst.power { s.packagePower = p }
        if let f = lst.freq { s.cpuFreqMHz = f }

        // GPU
        if let d = gpuStats() {
            if let n = d["inUseSysMemoryBytes"] as? NSNumber {
                let v = abs(n.doubleValue)
                if v < 1e13 { s.gpuMemMB = v / 1_048_576.0 }
            }
            if let n = d["gartUsedBytes"] as? NSNumber { s.gartMB = n.doubleValue / 1_048_576.0 }
            // 驱动若提供真实占用率则优先
            if s.gpuUtil == nil, let u = (d["Device Utilization %"] as? NSNumber)?.doubleValue, u > 0 {
                s.gpuUtil = max(0, min(100, u))
            }
        }

        // 兜底：提交速率估算（仅有 IOAccelerator 数据时）
        let now = CACurrentMediaTime()
        if let sub = readSubmissions(), now - prevGpuTime > 0.2 {
            let rate = (sub >= prevSubmissions) ? (sub - prevSubmissions) / (now - prevGpuTime) : 0
            s.gpuSubRate = rate
            if s.gpuUtil == nil { s.gpuUtil = max(0, min(100, (rate - 130) / 28.0)) }
            prevSubmissions = sub
        }
        prevGpuTime = now

        // 网络
        let n = netCounters()
        let dt = now - prevNetTime
        if dt > 0.3, n.up >= prevUp, n.down >= prevDown {
            s.netUp = Double(n.up - prevUp) / dt
            s.netDown = Double(n.down - prevDown) / dt
        }
        prevUp = n.up; prevDown = n.down; prevNetTime = now

        // 电源
        applyPower(to: &s)
        return s
    }

    deinit { for s in gpuServices { IOObjectRelease(s) }
        if batteryService != 0 { IOObjectRelease(batteryService) } }
}

// MARK: - 菜单栏

struct Cell {
    var top: String
    var bottom: String
    var topIsValue: Bool = false
    /// 该列固定占用宽度（避免数值变长变短时整条状态项伸缩）
    var minWidth: CGFloat? = nil
    /// 分隔符（画一条细竖线，用于给指标分组）
    var separator: Bool = false
    /// 该列自定义文字颜色（未设置则用默认标签色）
    var color: NSColor? = nil
}

final class BarView: NSView {
    var cells: [Cell] = []
    var onHover: ((Bool) -> Void)?
    var onRightClick: (() -> Void)?
    let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
    private var tracking: NSTrackingArea?

    private func font(_ isValue: Bool) -> NSFont { isValue ? valueFont : labelFont }

    private func width(_ s: String, _ f: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: f]).width
    }

    private var padding: CGFloat { 8 }
    private var separatorWidth: CGFloat { 9 }

    private func cellWidth(_ c: Cell) -> CGFloat {
        if c.separator { return separatorWidth }
        let base = max(width(c.top, font(c.topIsValue)), width(c.bottom, valueFont)) + padding
        return max(base, c.minWidth ?? 0)
    }

    func reserve(_ widestValue: String) -> CGFloat {
        width(widestValue, valueFont) + padding
    }

    /// 预留宽度取「标签宽、最宽取值宽」中的较大者
    func fixedWidth(top: String, widestValue: String) -> CGFloat {
        max(width(top, labelFont), width(widestValue, valueFont)) + padding
    }

    func desiredWidth() -> CGFloat {
        var w: CGFloat = 6
        for c in cells { w += cellWidth(c) }
        return ceil(w)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func rightMouseDown(with event: NSEvent) { onRightClick?() }

    override func draw(_ dirtyRect: NSRect) {
        guard !cells.isEmpty else { return }
        let widths = cells.map { cellWidth($0) }
        let total = widths.reduce(0, +)
        var x = (bounds.width - total) / 2
        let h = bounds.height
        let topY = h / 2 + 1
        let botY = h / 2 - 10.5
        let color = NSColor.labelColor
        for (i, c) in cells.enumerated() {
            let cw = widths[i]
            if c.separator {
                let line = NSRect(x: x + cw / 2, y: 3, width: 1, height: h - 6)
                NSColor.separatorColor.withAlphaComponent(0.30).setFill()
                line.fill()
                x += cw
                continue
            }
            let base = c.color ?? color
            let topColor = c.topIsValue ? base : base.withAlphaComponent(0.68)
            let top = NSAttributedString(string: c.top, attributes: [.font: font(c.topIsValue), .foregroundColor: topColor])
            top.draw(at: NSPoint(x: x + (cw - top.size().width) / 2, y: topY))
            let bot = NSAttributedString(string: c.bottom, attributes: [.font: valueFont, .foregroundColor: base])
            bot.draw(at: NSPoint(x: x + (cw - bot.size().width) / 2, y: botY))
            x += cw
        }
    }
}

func rate(_ bps: Double) -> String {
    if bps < 1024 { return String(format: "%.0fB/s", bps) }
    if bps < 1_048_576 { let k = bps / 1024; return k < 100 ? String(format: "%.1fK/s", k) : String(format: "%.0fK/s", k) }
    let m = bps / 1_048_576
    return m < 100 ? String(format: "%.1fM/s", m) : String(format: "%.0fM/s", m)
}

/// 按固定列宽模板组装菜单栏单元格
func makeCells(_ s: Sample, fitting bv: BarView) -> [Cell] {
    let memPct = s.memTotal > 0 ? s.memUsed / s.memTotal * 100 : 0
    let diskPct = s.diskTotal > 0 ? s.diskUsed / s.diskTotal * 100 : 0
    let gpuUtil = s.gpuUtil.map { String(format: "%.0f%%", $0) } ?? "—"
    let chargeText = s.chargePower.map { String(format: "%.1fW", $0) } ?? (s.batteryPlugged ? "0.0W" : "—")
    let powerText = s.displayPower.map { String(format: "%.1fW", $0) } ?? "—"
    return [
        Cell(top: "处理器", bottom: String(format: "%.0f%%", s.cpuTotal),
             minWidth: bv.fixedWidth(top: "处理器", widestValue: "100%")),
        Cell(top: "显卡", bottom: gpuUtil,
             minWidth: bv.fixedWidth(top: "显卡", widestValue: "100%")),
        Cell(top: "显存", bottom: s.gpuMemMB.map { String(format: "%.0fM", $0) } ?? "—",
             minWidth: bv.fixedWidth(top: "显存", widestValue: "9999M")),
        Cell(top: "内存", bottom: String(format: "%.0f%%", memPct),
             minWidth: bv.fixedWidth(top: "内存", widestValue: "100%")),
        Cell(top: "硬盘", bottom: String(format: "%.0f%%", diskPct),
             minWidth: bv.fixedWidth(top: "硬盘", widestValue: "100%")),
        Cell(top: "", bottom: "", separator: true),
        Cell(top: "充电", bottom: chargeText,
             minWidth: bv.fixedWidth(top: "充电", widestValue: "99.9W")),
        Cell(top: "功耗", bottom: powerText,
             minWidth: bv.fixedWidth(top: "功耗", widestValue: "99.9W")),
        Cell(top: "", bottom: "", separator: true),
        Cell(top: "温度", bottom: s.tempText,
             minWidth: bv.fixedWidth(top: "温度", widestValue: "100°"),
             color: tempColor(s.tempValue)),
        Cell(top: "", bottom: "", separator: true),
        Cell(top: "↑" + rate(s.netUp), bottom: "↓" + rate(s.netDown), topIsValue: true,
             minWidth: bv.fixedWidth(top: "↑99.9M/s", widestValue: "↓99.9M/s")),
    ]
}

// MARK: - 详情页控件

/// 圆形百分比环：轨道 + 进度弧 + 中心数值与名称
final class RingGauge: NSView {
    var fraction: CGFloat = 0 { didSet { needsDisplay = true } }
    var ringColor: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var lineWidth: CGFloat = 7

    /// 悬停时展示的详情文本（由 DetailView 写入）
    var detail: String = ""
    /// 鼠标进入/离开回调
    var onHover: ((Bool) -> Void)?
    private var tracking: NSTrackingArea?

    private let valueLabel = NSTextField(labelWithString: "—")
    private let titleLabel = NSTextField(labelWithString: "")

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 10, weight: .medium)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .semibold)
        valueLabel.textColor = .labelColor
        valueLabel.alignment = .center
        for v in [valueLabel, titleLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            valueLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -5),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            titleLabel.topAnchor.constraint(equalTo: valueLabel.bottomAnchor, constant: 1),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 设置百分比（nil 显示“—”且不画弧）
    func set(_ pct: Double?, color: NSColor) {
        ringColor = color
        if let p = pct {
            fraction = CGFloat(min(100, max(0, p))) / 100
            valueLabel.stringValue = String(format: "%.0f%%", p)
            valueLabel.textColor = color
        } else {
            fraction = 0
            valueLabel.stringValue = "—"
            valueLabel.textColor = .secondaryLabelColor
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let lw = lineWidth
        let d = min(bounds.width, bounds.height) - lw - 4
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let radius = d / 2

        let track = NSBezierPath()
        track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
        track.lineWidth = lw
        NSColor.white.withAlphaComponent(0.13).setStroke()
        track.stroke()

        guard fraction > 0 else { return }
        let start: CGFloat = 90
        let sweep: CGFloat = 360 * min(1, fraction)
        let arc = NSBezierPath()
        arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: start - sweep, clockwise: true)
        arc.lineWidth = lw
        arc.lineCapStyle = .round
        (ringColor.blended(withFraction: 0.12, of: .white) ?? ringColor).setStroke()
        arc.stroke()
    }
}

/// 负载越高颜色越偏红（绿 → 橙 → 红）
func gaugeColor(_ pct: Double) -> NSColor {
    let f = CGFloat(min(1, max(0, pct / 100)))
    return NSColor(calibratedHue: 0.34 - 0.34 * f, saturation: 0.62, brightness: 0.98, alpha: 1)
}

/// 每核负载的细竖条
final class CoreBars: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let gap: CGFloat = 2
        let n = CGFloat(values.count)
        let w = (bounds.width - gap * (n - 1)) / n
        for (i, v) in values.enumerated() {
            let h = bounds.height
            let bg = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: h)
            NSColor.white.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 1.5, yRadius: 1.5).fill()
            let frac = min(1, v / 100)
            guard frac > 0 else { continue }
            let fh = max(2, h * CGFloat(frac))
            let fg = NSRect(x: bg.minX, y: 0, width: w, height: fh)
            let c = NSColor(calibratedHue: 0.56 - 0.56 * CGFloat(frac), saturation: 0.72, brightness: 0.98, alpha: 1)
            c.setFill()
            NSBezierPath(roundedRect: fg, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

final class Divider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.withAlphaComponent(0.26).setFill()
        NSRect(x: 0, y: bounds.midY, width: bounds.width, height: 1).fill()
    }
}

/// 一行：左边标签，右边数值
final class KeyRow: NSView {
    let titleLabel = NSTextField(labelWithString: "")
    let valueLabel = NSTextField(labelWithString: "")

    init(title: String, big: Bool = false) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: big ? 13 : 11.5, weight: big ? .semibold : .medium)
        titleLabel.textColor = big ? .labelColor : .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: big ? 15 : 12.5, weight: .semibold)
        valueLabel.alignment = .right
        valueLabel.textColor = .labelColor
        for v in [titleLabel, valueLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            heightAnchor.constraint(equalToConstant: big ? 22 : 19),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class HoverEffect: NSVisualEffectView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

final class DetailPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 详情页

/// 温度配色
func tempColor(_ v: Double?) -> NSColor {
    guard let v = v else { return .secondaryLabelColor }
    if v < 55 { return .systemGreen }
    if v < 75 { return .labelColor }
    if v < 88 { return .systemOrange }
    return .systemRed
}

/// 内存三段图例（带色点）
func legendAttr(_ s: Sample) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
    let dim = NSColor.secondaryLabelColor
    let out = NSMutableAttributedString()
    func dot(_ c: NSColor) {
        out.append(NSAttributedString(string: "● ", attributes: [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: c]))
    }
    func txt(_ t: String) {
        out.append(NSAttributedString(string: t, attributes: [.font: font, .foregroundColor: dim]))
    }
    dot(.systemBlue); txt(String(format: "活跃 %.1f    ", s.memActive))
    dot(.systemRed); txt(String(format: "有线 %.1f    ", s.memWired))
    dot(.systemPurple); txt(String(format: "压缩 %.1f GB", s.memCompressed))
    return out
}

/// 网络上下行（彩色箭头）
func netAttr(_ s: Sample) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    let out = NSMutableAttributedString()
    out.append(NSAttributedString(string: "网络   ", attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
    out.append(NSAttributedString(string: "↑ " + rate(s.netUp), attributes: [.font: font, .foregroundColor: NSColor.systemGreen]))
    out.append(NSAttributedString(string: "     ", attributes: [.font: font]))
    out.append(NSAttributedString(string: "↓ " + rate(s.netDown), attributes: [.font: font, .foregroundColor: NSColor.systemBlue]))
    return out
}

final class DetailView: NSView {
    private let contentWidth: CGFloat = 292
    private let gaugeSize: CGFloat = 84

    private var headerRow = KeyRow(title: "系统监测", big: true)
    private var cpuRing = RingGauge(title: "处理器")
    private var memRing = RingGauge(title: "内存")
    private var gpuRing = RingGauge(title: "显卡")
    private var batRing = RingGauge(title: "电池")
    private var diskRing = RingGauge(title: "硬盘")
    private var netRow = NSTextField(labelWithString: "")
    private var hoverLabel = NSTextField(labelWithString: "")
    private weak var hoveredRing: RingGauge?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 250))
        wantsLayer = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 13, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        let bottom = stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        bottom.priority = .defaultLow
        bottom.isActive = true

        netRow.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        hoverLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        hoverLabel.textColor = NSColor.white.withAlphaComponent(0.75)
        hoverLabel.alignment = .center
        hoverLabel.lineBreakMode = .byCharWrapping
        hoverLabel.maximumNumberOfLines = 2
        hoverLabel.cell?.wraps = true

        func fit(_ v: NSView, _ h: CGFloat) {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
            v.heightAnchor.constraint(equalToConstant: h).isActive = true
            stack.addArrangedSubview(v)
        }

        func rule() {
            let d = Divider()
            fit(d, 1)
            stack.setCustomSpacing(9, after: d)
        }

        // 顶部：名称 + 温度
        headerRow.valueLabel.stringValue = "—"
        fit(headerRow, 22)
        rule()

        // 第一组圆环：处理器 / 内存 / 显卡
        let row1 = ringRow([cpuRing, memRing, gpuRing], gap: 20)
        fit(row1, gaugeSize)
        stack.setCustomSpacing(16, after: row1)

        // 第二组圆环：电池 / 硬盘
        fit(ringRow([batRing, diskRing], gap: 64), gaugeSize)

        // 悬停信息区：默认空白，鼠标移到圆环上才显示
        fit(hoverLabel, 32)

        for r in [cpuRing, memRing, gpuRing, batRing, diskRing] {
            r.onHover = { [weak self, weak r] inside in
                guard let self = self, let r = r else { return }
                if inside {
                    self.hoveredRing = r
                    self.hoverLabel.stringValue = r.detail
                } else if self.hoveredRing === r {
                    self.hoveredRing = nil
                    self.hoverLabel.stringValue = ""
                }
            }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 一排圆环：按数量自动排布并占满内容宽度
    private func ringRow(_ rings: [RingGauge], gap: CGFloat) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        for r in rings {
            r.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(r)
            NSLayoutConstraint.activate([
                r.widthAnchor.constraint(equalToConstant: gaugeSize),
                r.heightAnchor.constraint(equalToConstant: gaugeSize),
                r.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            ])
        }
        switch rings.count {
        case 0: break
        case 1:
            rings[0].centerXAnchor.constraint(equalTo: holder.centerXAnchor).isActive = true
        case 2:
            rings[0].centerXAnchor.constraint(equalTo: holder.centerXAnchor, constant: -(gaugeSize + gap) / 2).isActive = true
            rings[1].centerXAnchor.constraint(equalTo: holder.centerXAnchor, constant: (gaugeSize + gap) / 2).isActive = true
        default:
            rings[0].leadingAnchor.constraint(equalTo: holder.leadingAnchor).isActive = true
            for i in 1..<rings.count {
                rings[i].leadingAnchor.constraint(equalTo: rings[i - 1].trailingAnchor, constant: gap).isActive = true
            }
            rings[rings.count - 1].trailingAnchor.constraint(equalTo: holder.trailingAnchor).isActive = true
        }
        return holder
    }

    func update(_ s: Sample) {
        headerRow.valueLabel.stringValue = ""

        // 处理器
        cpuRing.set(s.cpuTotal, color: gaugeColor(s.cpuTotal))
        cpuRing.detail = s.cpuFreqMHz.map { String(format: "频率 %.2f GHz", $0 / 1000) } ?? "频率 —"

        // 内存
        let memPct = s.memTotal > 0 ? s.memUsed / s.memTotal * 100 : 0
        memRing.set(memPct, color: .systemBlue)
        memRing.detail = String(format: "%.1f / %.0f GB · 空闲 %.0f MB · 交换 %.0f MB",
                                s.memUsed, s.memTotal, s.memFreeMB, s.swapUsedMB)

        // 显卡
        gpuRing.set(s.gpuUtil, color: .systemTeal)
        gpuRing.detail = s.gpuMemMB.map { String(format: "显存 %.0f MB", $0) } ?? "无独立显卡数据"

        // 电池
        batRing.set(s.batteryPct, color: s.batteryCharging ? .systemGreen : (s.batteryPct < 20 ? .systemRed : gaugeColor(100 - s.batteryPct)))
        var state: [String] = []
        state.append(s.batteryCharging ? "充电中" : (s.batteryPlugged ? "已接通电源" : "放电中"))
        if s.batteryFull { state.append("已充满") }
        if let w = s.adapterWatts, s.batteryPlugged { state.append(String(format: "适配器 %.0fW", w)) }
        if let m = s.batteryMinutes, m > 0 {
            state.append(String(format: "%@ %d 分钟", s.batteryCharging ? "充满还需" : "剩余可用", Int(m)))
        }
        batRing.detail = state.joined(separator: "   ·   ")

        // 硬盘
        let diskPct = s.diskTotal > 0 ? s.diskUsed / s.diskTotal * 100 : 0
        diskRing.set(diskPct, color: .systemIndigo)
        diskRing.detail = String(format: "已用 %.0f / 共 %.0f GB · 可用 %.0f GB", s.diskUsed, s.diskTotal, s.diskFree)

        // 网络
        _ = s.netUp

        // 悬停中的圆环同步刷新说明
        if let r = hoveredRing { hoverLabel.stringValue = r.detail }
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var reader: Reader!
    private var timer: Timer?
    private var latest = Sample()
    private var statusItem: NSStatusItem!
    private let barView = BarView()
    private var panel: DetailPanel?
    private var detailView: DetailView?
    private var showWork: DispatchWorkItem?
    private var hideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        reader = Reader()
        statusItem = NSStatusBar.system.statusItem(withLength: 300)
        if let b = statusItem.button {
            barView.frame = b.bounds
            barView.autoresizingMask = [.width, .height]
            b.addSubview(barView)
            b.title = ""
        }
        barView.onHover = { [weak self] inside in
            if inside { self?.scheduleShow() } else { self?.scheduleHide() }
        }
        barView.onRightClick = { [weak self] in self?.showContextMenu() }

        refresh()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            autoreleasepool { self?.refresh() }
        }
        t.tolerance = 0.8
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    private func refresh() {
        let s = reader.sample()
        latest = s
        barView.cells = makeCells(s, fitting: barView)
        barView.needsDisplay = true
        let w = barView.desiredWidth()
        if abs(statusItem.length - w) > 0.5 { statusItem.length = w }
        if panel?.isVisible == true { detailView?.update(s) }
    }

    private func scheduleShow() {
        hideWork?.cancel()
        showWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.showPanel() }
        showWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private func scheduleHide() {
        showWork?.cancel()
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hidePanel() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func showPanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        if panel == nil {
            let p = DetailPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 1),
                                styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .statusBar
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let effect = HoverEffect(frame: NSRect(x: 0, y: 0, width: 320, height: 1))
            effect.onEnter = { [weak self] in self?.scheduleShow() }
            effect.onExit = { [weak self] in self?.scheduleHide() }
            effect.material = .hudWindow
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 14
            effect.layer?.masksToBounds = true
            effect.layer?.borderWidth = 1
            effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.09).cgColor
            let dv = DetailView()
            dv.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(dv)
            NSLayoutConstraint.activate([
                dv.topAnchor.constraint(equalTo: effect.topAnchor),
                dv.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                dv.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                dv.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            p.contentView = effect
            panel = p
            detailView = dv
        }
        detailView?.update(latest)
        panel?.contentView?.layoutSubtreeIfNeeded()
        let fit = detailView?.fittingSize.height ?? 320
        let size = NSSize(width: 320, height: max(260, fit + 14))
        let btnRect = win.convertToScreen(button.convert(button.bounds, to: nil))
        let origin = NSPoint(x: min(btnRect.maxX - size.width, (NSScreen.main?.visibleFrame.maxX ?? btnRect.maxX) - 8),
                             y: btnRect.minY - size.height - 4)
        panel?.setFrame(NSRect(origin: origin, size: size), display: true)
        panel?.orderFrontRegardless()
    }

    private func hidePanel() { panel?.orderOut(nil) }

    private func showContextMenu() {
        let menu = NSMenu()
        let q = NSMenuItem(title: "退出系统监测", action: #selector(quit), keyEquivalent: "")
        q.target = self
        menu.addItem(q)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// 单实例保护：已有同名应用在跑就不再启动
if let bid = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bid).count > 1 {
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
