import Foundation
import Darwin
import IOKit
import IOKit.ps
import CoreAudio
import CoreMediaIO

// MARK: - Process listing

struct ProcInfo: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let cpu: Double      // percent of a single core
    let rss: UInt64
}

/// Instance-based so each monitor keeps its own delta baseline. A shared static
/// baseline breaks as soon as two monitors sample at different cadences — every
/// process then reports 0% because each call consumes the other's deltas.
final class ProcessProbe {
    private struct Raw { let pid: pid_t; let name: String; let cpuNs: UInt64; let rss: UInt64 }

    private var previous: [pid_t: UInt64] = [:]
    private var lastStamp: CFAbsoluteTime = 0

    /// Snapshot of every process we're permitted to inspect. Root-owned
    /// processes deny PROC_PIDTASKALLINFO to unprivileged callers and are skipped.
    private func raw() -> [Raw] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: capacity)
        guard proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, byteCount) > 0 else { return [] }

        var out: [Raw] = []
        out.reserveCapacity(capacity)
        let expected = Int32(MemoryLayout<proc_taskallinfo>.size)
        for pid in pids where pid > 0 {
            var info = proc_taskallinfo()
            let got = withUnsafeMutablePointer(to: &info) {
                proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, $0, expected)
            }
            guard got == expected else { continue }
            var nameBuf = info.pbsd.pbi_name
            let name = withUnsafeBytes(of: &nameBuf) { rawBuf -> String in
                guard let base = rawBuf.baseAddress else { return "?" }
                return String(cString: base.assumingMemoryBound(to: CChar.self))
            }
            out.append(Raw(pid: pid,
                           name: name.isEmpty ? "pid \(pid)" : name,
                           cpuNs: info.ptinfo.pti_total_user &+ info.ptinfo.pti_total_system,
                           rss: UInt64(info.ptinfo.pti_resident_size)))
        }
        return out
    }

    /// Returns (byCPU, byMemory, totalCount). CPU is derived by diffing
    /// cumulative task time against the previous call.
    func sample(limit: Int = 8) -> (cpu: [ProcInfo], mem: [ProcInfo], count: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = lastStamp == 0 ? 1.0 : max(now - lastStamp, 0.05)
        lastStamp = now

        let procs = raw()
        var next: [pid_t: UInt64] = [:]
        next.reserveCapacity(procs.count)

        var infos: [ProcInfo] = []
        infos.reserveCapacity(procs.count)
        for p in procs {
            next[p.pid] = p.cpuNs
            let before = previous[p.pid] ?? p.cpuNs
            let deltaNs = p.cpuNs >= before ? p.cpuNs - before : 0
            let pct = Double(deltaNs) / 1_000_000_000.0 / elapsed * 100.0
            infos.append(ProcInfo(id: p.pid, name: p.name, cpu: pct, rss: p.rss))
        }
        previous = next

        let byCPU = Array(infos.sorted { $0.cpu > $1.cpu }.prefix(limit))
        let byMem = Array(infos.sorted { $0.rss > $1.rss }.prefix(limit))
        return (byCPU, byMem, infos.count)
    }
}

// MARK: - Sensors

struct Sensors: Equatable {
    var hasBattery = false
    var percent: Int = 0
    var isCharging = false
    var onAC = true
    var cycleCount: Int = 0
    var voltage: Double = 0        // volts
    var amperage: Double = 0       // amps, signed (negative = discharging)
    var minutesRemaining: Int? = nil

    var cameraActive = false
    var cameraCount = 0
    var micActive = false
    var micName = "—"
    var micCount = 0

    var thermal: Int = 0           // 0 nominal … 3 critical
    var lowPower = false

    var thermalLabel: String {
        ["NOMINAL", "FAIR", "SERIOUS", "CRITICAL"][min(max(thermal, 0), 3)]
    }

    var powerLabel: String {
        if !hasBattery { return "AC" }
        if isCharging { return "CHARGING" }
        return onAC ? "AC POWER" : "BATTERY"
    }
}

enum SensorProbe {

    static func sample() -> Sensors {
        var s = Sensors()
        readPower(&s)
        readBatteryDetail(&s)
        readCamera(&s)
        readMicrophone(&s)
        s.thermal = ProcessInfo.processInfo.thermalState.rawValue
        s.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        return s
    }

    private static func readPower(_ s: inout Sensors) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(blob, src)?.takeUnretainedValue()
                    as? [String: Any] else { continue }
            s.hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            s.percent = max > 0 ? Int((Double(cur) / Double(max)) * 100) : cur
            s.isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
            s.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            // -1 means "still calculating"; 65535 is the sentinel for unknown.
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0, t < 60_000, !s.onAC {
                s.minutesRemaining = t
            }
            if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0, t < 60_000, s.isCharging {
                s.minutesRemaining = t
            }
        }
    }

    private static func readBatteryDetail(_ s: inout Sensors) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("AppleSmartBattery"),
                                           &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let d = props?.takeRetainedValue() as? [String: Any] else { continue }
            s.cycleCount = d["CycleCount"] as? Int ?? s.cycleCount
            if let mv = d["Voltage"] as? Int { s.voltage = Double(mv) / 1000.0 }
            if let ma = d["Amperage"] as? Int { s.amperage = Double(ma) / 1000.0 }
        }
    }

    private static func readCamera(_ s: inout Sensors) {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject),
                                            &addr, 0, nil, &size) == OSStatus(kCMIOHardwareNoError),
              size > 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),
                                        &addr, 0, nil, size, &used, &devices)
                == OSStatus(kCMIOHardwareNoError) else { return }
        s.cameraCount = devices.count
        for dev in devices {
            var running: UInt32 = 0
            var got: UInt32 = 0
            var rAddr = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            guard CMIOObjectGetPropertyData(dev, &rAddr, 0, nil,
                                            UInt32(MemoryLayout<UInt32>.size), &got, &running)
                    == OSStatus(kCMIOHardwareNoError) else { continue }
            if running != 0 { s.cameraActive = true }
        }
    }

    private static func readMicrophone(_ s: inout Sensors) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr else { return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return }

        for dev in ids {
            // An empty input stream configuration means it's an output-only device.
            var scAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var scSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(AudioObjectID(dev), &scAddr, 0, nil, &scSize) == noErr,
                  scSize > UInt32(MemoryLayout<UInt32>.size) else { continue }
            s.micCount += 1

            var rAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var running: UInt32 = 0
            var rSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectHasProperty(AudioObjectID(dev), &rAddr),
                  AudioObjectGetPropertyData(AudioObjectID(dev), &rAddr, 0, nil, &rSize, &running) == noErr
            else { continue }

            if running != 0 {
                s.micActive = true
                s.micName = deviceName(dev) ?? "ACTIVE"
            }
        }
    }

    private static func deviceName(_ dev: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var name: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(dev), &addr, 0, nil, &size, &name) == noErr
        else { return nil }
        return name as String?
    }
}

// MARK: - GPU

enum GPUProbe {
    /// Apple Silicon exposes accelerator utilization unprivileged via IORegistry.
    ///
    /// Reads the single "PerformanceStatistics" key rather than dumping every
    /// property on the accelerator — the full dictionary is large and this runs
    /// on the fast sampling timer.
    static func utilization() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }
        var best: Double? = nil
        while case let svc = IOIteratorNext(iter), svc != 0 {
            defer { IOObjectRelease(svc) }
            guard let raw = IORegistryEntryCreateCFProperty(
                    svc, "PerformanceStatistics" as CFString,
                    kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let stats = raw as? [String: Any],
                  let util = stats["Device Utilization %"] as? Int else { continue }
            best = max(best ?? 0, Double(util) / 100.0)
        }
        return best
    }
}
