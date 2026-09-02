import Foundation
import Darwin
import IOKit
import Combine

// MARK: - Snapshot

struct CoreLoad: Identifiable, Equatable {
    let id: Int
    let total: Double      // 0...1
    let user: Double
    let system: Double
    let isEfficiency: Bool
}

/// Fixed-capacity rolling series, newest last.
struct Series: Equatable {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 240) { self.capacity = capacity }

    mutating func push(_ v: Double) {
        values.append(v)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    /// Last `n` samples, left-padded with zeros so a trace always fills its frame.
    func tail(_ n: Int) -> [Double] {
        guard n > 1 else { return [] }
        if values.count >= n { return Array(values.suffix(n)) }
        return Array(repeating: 0, count: n - values.count) + values
    }

    var latest: Double { values.last ?? 0 }
    var peak: Double { values.max() ?? 0 }
    var mean: Double { values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count) }
}

struct Snapshot {
    // Identity
    var chip: String = "UNKNOWN"
    var hostName: String = ""
    var coreCount: Int = 0
    var efficiencyCores: Int = 0

    // CPU
    var cpuTotal: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cores: [CoreLoad] = []
    var cpuSeries = Series()
    var coreSeries: [Series] = []
    var loadAvg: (Double, Double, Double) = (0, 0, 0)

    // GPU
    var gpuAvailable = false
    var gpuUtil: Double = 0
    var gpuSeries = Series()

    // Memory
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var memSeries = Series()
    var pressureLevel: Int32 = 1
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    var pageIns: UInt64 = 0
    var pageOuts: UInt64 = 0
    var faults: UInt64 = 0

    // I/O
    var netRx: Double = 0
    var netTx: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var netRxSeries = Series()
    var netTxSeries = Series()
    var diskReadSeries = Series()
    var diskWriteSeries = Series()

    // Storage
    var volTotal: UInt64 = 0
    var volFree: UInt64 = 0

    // Processes
    var topCPU: [ProcInfo] = []
    var topMem: [ProcInfo] = []
    var procCount: Int = 0

    // Sensors
    var sensors = Sensors()

    var uptime: TimeInterval = 0
    /// Increments once per sample; drives motion without extra redraws.
    var tick: Int = 0

    // Derived
    var memFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }
    var swapFraction: Double { swapTotal > 0 ? Double(swapUsed) / Double(swapTotal) : 0 }
    var volFraction: Double { volTotal > 0 ? Double(volTotal - volFree) / Double(volTotal) : 0 }

    var isStressed: Bool {
        cpuTotal > 0.85 || pressureLevel > 1 || memFraction > 0.90 || sensors.thermal >= 2
    }

    var pressureLabel: String {
        switch pressureLevel {
        case 4: return "CRITICAL"
        case 2: return "WARNING"
        default: return "NOMINAL"
        }
    }
}

// MARK: - Monitor

final class SystemMonitor: ObservableObject {
    @Published private(set) var snap = Snapshot()

    private var fastTimer: Timer?
    private var slowTimer: Timer?
    private var fastInterval: TimeInterval =
        ProcessInfo.processInfo.environment["NEOSTAT_HZ"].flatMap(Double.init) ?? 0.6
    private let intervalLocked = ProcessInfo.processInfo.environment["NEOSTAT_HZ"] != nil
    private let slowInterval: TimeInterval = 2.0

    private var lastTicks: [[UInt32]] = []
    private var lastNet: (rx: UInt64, tx: UInt64) = (0, 0)
    private var lastDisk: (read: UInt64, write: UInt64) = (0, 0)
    private var lastStamp: CFAbsoluteTime = 0
    private let slowQueue = DispatchQueue(label: "neostat.slow", qos: .utility)
    private let processProbe = ProcessProbe()
    private var slowBusy = false

    init() {
        snap.chip = Self.chipBrand()
        snap.hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        snap.efficiencyCores = Self.sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        snap.memTotal = UInt64(Self.sysctlInt("hw.memsize") ?? 0)

        lastTicks = Self.cpuTicks()
        lastNet = Self.networkBytes()
        lastDisk = Self.diskBytes()
        lastStamp = CFAbsoluteTimeGetCurrent()
        snap.coreCount = lastTicks.count
        snap.coreSeries = (0..<lastTicks.count).map { _ in Series() }
        snap.uptime = Self.uptime()
        snap.gpuAvailable = GPUProbe.utilization() != nil
    }

    func start() {
        guard fastTimer == nil, !Perf.noSample else { return }

        let f = Timer.scheduledTimer(withTimeInterval: fastInterval, repeats: true) { [weak self] _ in
            self?.sampleFast()
        }
        RunLoop.main.add(f, forMode: .common)
        fastTimer = f

        let s = Timer.scheduledTimer(withTimeInterval: slowInterval, repeats: true) { [weak self] _ in
            self?.sampleSlow()
        }
        RunLoop.main.add(s, forMode: .common)
        slowTimer = s

        sampleSlow()
    }

    /// Re-times the fast sampler. Cost per update scales with how much layout
    /// the current mode has to rebuild, so a bigger HUD ticks a little slower.
    func setInterval(_ seconds: TimeInterval) {
        guard !intervalLocked, abs(seconds - fastInterval) > 0.01 else { return }
        fastInterval = seconds
        guard fastTimer != nil else { return }
        fastTimer?.invalidate()
        let f = Timer.scheduledTimer(withTimeInterval: fastInterval, repeats: true) { [weak self] _ in
            self?.sampleFast()
        }
        RunLoop.main.add(f, forMode: .common)
        fastTimer = f
    }

    func stop() {
        fastTimer?.invalidate(); fastTimer = nil
        slowTimer?.invalidate(); slowTimer = nil
    }

    // MARK: Fast path — CPU, memory, GPU, I/O

    private func sampleFast() {
        // performDrag runs a modal loop that still services common-mode timers;
        // skip the work so the drag has the main thread to itself.
        let win = WindowManager.shared
        if win.isDragging { return }
        // Hidden or occluded, the HUD stops sampling — unless a phone, tablet
        // or watch is reading, in which case the window is beside the point.
        if !win.isVisible && !Broadcast.shared.hasDemand { return }

        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = max(now - lastStamp, 0.001)
        lastStamp = now

        var s = snap

        // ---- CPU ----
        let ticks = Self.cpuTicks()
        if ticks.count == lastTicks.count, !ticks.isEmpty {
            if s.coreSeries.count != ticks.count {
                s.coreSeries = (0..<ticks.count).map { _ in Series() }
            }
            var cores: [CoreLoad] = []
            var sumUser = 0.0, sumSys = 0.0, sumTotal = 0.0
            for i in 0..<ticks.count {
                let dUser = Double(ticks[i][0] &- lastTicks[i][0])
                let dSys  = Double(ticks[i][1] &- lastTicks[i][1])
                let dIdle = Double(ticks[i][2] &- lastTicks[i][2])
                let dNice = Double(ticks[i][3] &- lastTicks[i][3])
                let denom = dUser + dSys + dIdle + dNice
                let busy = denom > 0 ? (dUser + dSys + dNice) / denom : 0
                let u = denom > 0 ? (dUser + dNice) / denom : 0
                let sy = denom > 0 ? dSys / denom : 0
                // On Apple Silicon the efficiency cluster is reported first.
                cores.append(CoreLoad(id: i, total: busy, user: u, system: sy,
                                      isEfficiency: i < s.efficiencyCores))
                s.coreSeries[i].push(busy)
                sumUser += u; sumSys += sy; sumTotal += busy
            }
            let n = Double(cores.count)
            s.cores = cores
            s.cpuTotal = sumTotal / n
            s.cpuUser = sumUser / n
            s.cpuSystem = sumSys / n
            s.coreCount = cores.count
            s.cpuSeries.push(s.cpuTotal)
        }
        lastTicks = ticks

        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        s.loadAvg = (la[0], la[1], la[2])

        // ---- GPU ----
        if let g = GPUProbe.utilization() {
            s.gpuAvailable = true
            s.gpuUtil = g
            s.gpuSeries.push(g)
        }

        // ---- MEMORY ----
        if let m = Self.memory() {
            s.memApp = m.app
            s.memWired = m.wired
            s.memCompressed = m.compressed
            s.memCached = m.cached
            s.memUsed = m.app &+ m.wired &+ m.compressed
            s.pressureLevel = m.pressure
            s.pageIns = m.pageIns
            s.pageOuts = m.pageOuts
            s.faults = m.faults
            s.memSeries.push(s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0)
        }
        if let sw = Self.swap() {
            s.swapUsed = sw.used
            s.swapTotal = sw.total
        }

        // ---- NETWORK ----
        let net = Self.networkBytes()
        if net.rx >= lastNet.rx { s.netRx = Double(net.rx - lastNet.rx) / elapsed }
        if net.tx >= lastNet.tx { s.netTx = Double(net.tx - lastNet.tx) / elapsed }
        lastNet = net
        s.netRxSeries.push(s.netRx)
        s.netTxSeries.push(s.netTx)

        // ---- DISK ----
        let disk = Self.diskBytes()
        if disk.read >= lastDisk.read { s.diskRead = Double(disk.read - lastDisk.read) / elapsed }
        if disk.write >= lastDisk.write { s.diskWrite = Double(disk.write - lastDisk.write) / elapsed }
        lastDisk = disk
        s.diskReadSeries.push(s.diskRead)
        s.diskWriteSeries.push(s.diskWrite)

        s.uptime = Self.uptime()
        s.tick &+= 1
        snap = s
        Broadcast.shared.publish(s)
    }

    // MARK: Slow path — processes and sensors (off the main thread)

    private func sampleSlow() {
        guard !slowBusy else { return }
        slowBusy = true
        slowQueue.async { [weak self] in
            guard let probe = self?.processProbe else { return }
            let procs = probe.sample(limit: 10)
            let sensors = SensorProbe.sample()
            let vol = SystemMonitor.volume()
            DispatchQueue.main.async {
                guard let self else { return }
                var s = self.snap
                s.topCPU = procs.cpu
                s.topMem = procs.mem
                s.procCount = procs.count
                s.sensors = sensors
                s.volTotal = vol.total
                s.volFree = vol.free
                self.snap = s
                self.slowBusy = false
            }
        }
    }

    // MARK: - Raw sources

    static func cpuTicks() -> [[UInt32]] {
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                     &cpuCount, &info, &infoCount)
        guard kr == KERN_SUCCESS, let data = info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: data),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        var out: [[UInt32]] = []
        out.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            out.append([
                UInt32(bitPattern: data[base + Int(CPU_STATE_USER)]),
                UInt32(bitPattern: data[base + Int(CPU_STATE_SYSTEM)]),
                UInt32(bitPattern: data[base + Int(CPU_STATE_IDLE)]),
                UInt32(bitPattern: data[base + Int(CPU_STATE_NICE)]),
            ])
        }
        return out
    }

    struct MemStats {
        var app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64
        var pressure: Int32
        var pageIns: UInt64, pageOuts: UInt64, faults: UInt64
    }

    static func memory() -> MemStats? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }
        let ps = UInt64(vm_kernel_page_size)
        // Mirrors Activity Monitor's breakdown.
        let app = (UInt64(stats.internal_page_count) &- UInt64(stats.purgeable_count)) &* ps
        let wired = UInt64(stats.wire_count) &* ps
        let compressed = UInt64(stats.compressor_page_count) &* ps
        let cached = (UInt64(stats.external_page_count) &+ UInt64(stats.purgeable_count)) &* ps
        var pressure: Int32 = 1
        var psz = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &psz, nil, 0)
        return MemStats(app: app, wired: wired, compressed: compressed, cached: cached,
                        pressure: pressure,
                        pageIns: stats.pageins, pageOuts: stats.pageouts,
                        faults: UInt64(stats.faults))
    }

    static func swap() -> (used: UInt64, total: UInt64)? {
        var xsw = xsw_usage()
        var sz = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &xsw, &sz, nil, 0) == 0 else { return nil }
        return (xsw.xsu_used, xsw.xsu_total)
    }

    static func volume() -> (total: UInt64, free: UInt64) {
        var fs = statfs()
        guard statfs("/", &fs) == 0 else { return (0, 0) }
        return (UInt64(fs.f_blocks) * UInt64(fs.f_bsize),
                UInt64(fs.f_bavail) * UInt64(fs.f_bsize))
    }

    static func networkBytes() -> (rx: UInt64, tx: UInt64) {
        var rx: UInt64 = 0, tx: UInt64 = 0
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = cursor {
            defer { cursor = cur.pointee.ifa_next }
            guard let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_LINK) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            // Skip loopback and tunnels so the readout reflects real link traffic.
            if name.hasPrefix("lo") || name.hasPrefix("gif")
                || name.hasPrefix("stf") || name.hasPrefix("utun") { continue }
            guard let raw = cur.pointee.ifa_data else { continue }
            let d = raw.assumingMemoryBound(to: if_data.self)
            rx &+= UInt64(d.pointee.ifi_ibytes)
            tx &+= UInt64(d.pointee.ifi_obytes)
        }
        return (rx, tx)
    }

    static func diskBytes() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0, wrote: UInt64 = 0
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDriver"),
                                           &iter) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        while case let drive = IOIteratorNext(iter), drive != 0 {
            defer { IOObjectRelease(drive) }
            guard let raw = IORegistryEntryCreateCFProperty(
                    drive, "Statistics" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any] else { continue }
            read  &+= (stats["Bytes (Read)"]  as? UInt64) ?? 0
            wrote &+= (stats["Bytes (Write)"] as? UInt64) ?? 0
        }
        return (read, wrote)
    }

    static func uptime() -> TimeInterval {
        var tv = timeval()
        var sz = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &sz, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    static func chipBrand() -> String {
        var sz = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &sz, nil, 0) == 0, sz > 0 else {
            return "UNKNOWN"
        }
        var buf = [CChar](repeating: 0, count: sz)
        sysctlbyname("machdep.cpu.brand_string", &buf, &sz, nil, 0)
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var sz = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &sz, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}

// MARK: - Formatting

enum Fmt {
    static func rate(_ bytesPerSec: Double) -> String {
        let b = max(bytesPerSec, 0)
        if b < 1024 { return String(format: "%.0f B", b) }
        if b < 1_048_576 { return String(format: "%.1f K", b / 1024) }
        if b < 1_073_741_824 { return String(format: "%.1f M", b / 1_048_576) }
        return String(format: "%.2f G", b / 1_073_741_824)
    }

    static func bytes(_ v: UInt64) -> String {
        let d = Double(v)
        if d < 1_048_576 { return String(format: "%.0fK", d / 1024) }
        if d < 1_073_741_824 { return String(format: "%.0fM", d / 1_048_576) }
        return String(format: "%.1fG", d / 1_073_741_824)
    }

    static func gb(_ bytes: UInt64) -> String {
        String(format: "%.2f", Double(bytes) / 1_073_741_824)
    }

    static func gb0(_ bytes: UInt64) -> String {
        String(format: "%.0f", Double(bytes) / 1_073_741_824)
    }

    static func pct(_ f: Double) -> String {
        String(format: "%.0f", min(max(f, 0), 1) * 100)
    }

    static func uptime(_ t: TimeInterval) -> String {
        let total = Int(max(t, 0))
        let d = total / 86400
        let h = (total % 86400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if d > 0 { return String(format: "%dD %02d:%02d:%02d", d, h, m, s) }
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    /// "Apple M1 Pro" -> "M1 PRO"
    static func shortChip(_ brand: String) -> String {
        brand.replacingOccurrences(of: "Apple ", with: "").uppercased()
    }

    static func clip(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(max(0, n - 1))) + "…"
    }
}
