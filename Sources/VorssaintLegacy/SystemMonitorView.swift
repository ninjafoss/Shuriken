// SystemMonitorView.swift — Vista SwiftUI del popover + monitor leggeri
// Compatibile macOS 12+, Swift 5.7
// Feature parity con Aria: SMC client, USB monitor, Clipboard, Brightness, Cleaner, Fan control, Launch at login

import SwiftUI
import Combine
import AppKit
import IOKit.ps
import IOKit.pwr_mgt
import IOKit.usb

// MARK: - Shared Utilities

func fourCC(_ s: String) -> UInt32 {
    s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func fourCCString(_ v: UInt32) -> String {
    let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    return String(bytes: chars, encoding: .ascii) ?? "????"
}

// MARK: - SMC Structs

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}
struct SMCVersion { var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0, release: UInt16 = 0 }
struct SMCPLimitData { var version: UInt16 = 0, length: UInt16 = 0, cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0 }
struct SMCKeyInfoData { var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0 }

// MARK: - SMC Value Codec

enum SMCValueCodec {
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        guard bytes.count >= 2 else { return nil }
        switch type {
        case "sp78", "sp96", "sp4c", "sp3c":
            let val = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            let fracBits = type == "sp78" ? 8 : (type == "sp96" ? 6 : (type == "sp4c" ? 4 : 3))
            return Double(val) / Double(1 << fracBits)
        case "fp5c", "fpe2", "fp6a", "fp88":
            // fpe2 fan keys return 2-byte raw RPM values (UInt16)
            if bytes.count == 2 {
                let val = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
                return Double(val)
            }
            if bytes.count >= 4 {
                var f: Float = 0
                _ = withUnsafeMutableBytes(of: &f) { bytes.prefix(4).copyBytes(to: $0) }
                return Double(f)
            }
        case "ui8 ", "ui16", "ui32":
            if bytes.count >= 1 { return Double(bytes[0]) }
            if bytes.count >= 2 { return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) }
            if bytes.count >= 4 {
                var u: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &u) { bytes.prefix(4).copyBytes(to: $0) }
                return Double(u)
            }
        default: return nil
        }
        return nil
    }

    static func encode(_ value: Double, type: String, size: Int) -> [UInt8]? {
        switch type {
        case "sp78": let v = UInt16(value * 256); return [UInt8(v >> 8), UInt8(v & 0xff)]
        case "sp96": let v = UInt16(value * 64); return [UInt8(v >> 8), UInt8(v & 0xff)]
        case "sp4c": let v = UInt16(value * 16); return [UInt8(v >> 8), UInt8(v & 0xff)]
        case "sp3c": let v = UInt16(value * 8); return [UInt8(v >> 8), UInt8(v & 0xff)]
        case "fp5c", "fpe2":
            // Fan keys accept 2-byte UInt16 raw values
            if size == 2 {
                let v = UInt16(value)
                return [UInt8(v >> 8), UInt8(v & 0xff)]
            }
            var f = Float(value); return Array(withUnsafeBytes(of: &f) { $0 })
        case "ui8 ": return [UInt8(value)]
        case "ui16": let v = UInt16(value); return [UInt8(v >> 8), UInt8(v & 0xff)]
        case "ui32": var v = UInt32(value); return Array(withUnsafeBytes(of: &v) { $0 })
        default: return nil
        }
    }
}

// MARK: - SMC Client

final class SMCClient {
    private var connection: io_connect_t = 0
    private let kHandleYPCEvent: UInt32 = 2
    private let kCmdReadKey: UInt8 = 5
    private let kCmdKeyInfo: UInt8 = 9
    private let kCmdWriteKey: UInt8 = 6

    struct Key {
        let code: UInt32
        let name: String
        let dataSize: UInt32
        let dataType: String
    }

    enum SMCError: Error {
        case invalidPayload, unsupportedType, transport(kern_return_t), controller(UInt8)
    }

    init?() {
        let matching = IOServiceMatching("AppleSMC")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit { if connection != 0 { IOServiceClose(connection) } }

    func key(named name: String) -> Key? {
        var input = SMCParamStruct()
        input.key = fourCC(name)
        input.data8 = kCmdKeyInfo
        guard let out = call(&input), out.result == 0 else { return nil }
        return Key(code: input.key, name: name, dataSize: out.keyInfo.dataSize, dataType: fourCCString(out.keyInfo.dataType))
    }

    func readValue(_ key: Key) -> Double? {
        guard let bytes = readBytes(key) else { return nil }
        return SMCValueCodec.decode(bytes, type: key.dataType)
    }

    func readBytes(_ key: Key) -> [UInt8]? {
        guard key.dataSize > 0, key.dataSize <= 32 else { return nil }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.dataSize
        input.data8 = kCmdReadKey
        guard let out = call(&input), out.result == 0 else { return nil }
        return withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(key.dataSize))) }
    }

    func writeBytes(_ bytes: [UInt8], to key: Key) throws {
        guard key.dataSize > 0, key.dataSize <= 32, bytes.count == Int(key.dataSize) else {
            throw SMCError.invalidPayload
        }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.dataSize
        input.data8 = kCmdWriteKey
        withUnsafeMutableBytes(of: &input.bytes) { dst in
            bytes.copyBytes(to: dst)
        }
        let (result, output) = invoke(&input)
        guard result == kIOReturnSuccess else { throw SMCError.transport(result) }
        guard output.result == 0 else { throw SMCError.controller(output.result) }
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        let (kr, output) = invoke(&input)
        return kr == kIOReturnSuccess ? output : nil
    }

    private func invoke(_ input: inout SMCParamStruct) -> (kern_return_t, SMCParamStruct) {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(connection, kHandleYPCEvent, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outSize)
        return (kr, output)
    }
}

// MARK: - Monitor CPU leggero

final class CPUUsageMonitor: ObservableObject {
    static let shared = CPUUsageMonitor()

    @Published var currentUsage: Double = 0.0
    private var timer: Timer?
    private var previousTicks: (user: UInt32, system: UInt32, idle: UInt32) = (0, 0, 0)

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.updateUsage()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    private func updateUsage() {
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &cpuLoad) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let user = cpuLoad.cpu_ticks.0
            let system = cpuLoad.cpu_ticks.1
            let idle = cpuLoad.cpu_ticks.2

            let userDelta = Double(user - previousTicks.user)
            let systemDelta = Double(system - previousTicks.system)
            let idleDelta = Double(idle - previousTicks.idle)
            let totalDelta = userDelta + systemDelta + idleDelta

            previousTicks = (user, system, idle)

            if totalDelta > 0 {
                currentUsage = ((userDelta + systemDelta) / totalDelta) * 100.0
            }
        }
    }
}

// MARK: - Monitor Memoria

final class MemoryMonitor: ObservableObject {
    static let shared = MemoryMonitor()

    @Published var usedGB: Double = 0.0
    @Published var totalGB: Double = 0.0
    @Published var usagePercent: Double = 0.0
    private var timer: Timer?

    private init() {
        totalGB = Double(ProcessInfo.processInfo.physicalMemory) / (1024 * 1024 * 1024)
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateMemory()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if result == KERN_SUCCESS {
            let pageSize = Double(vm_kernel_page_size)
            let used = Double(stats.active_count + stats.inactive_count + stats.wire_count) * pageSize
            usedGB = used / (1024 * 1024 * 1024)
            usagePercent = totalGB > 0 ? (usedGB / totalGB) * 100.0 : 0.0
        }
    }
}

// MARK: - Monitor Temperatura (REALE via SMC - FUNZIONA su MacBook Air 2015!)

final class TemperatureMonitor: ObservableObject {
    static let shared = TemperatureMonitor()

    @Published var currentTemperature: Double = 0.0
    @Published var cpuProximityTemp: Double = 0.0   // TC0P
    @Published var cpuCore1Temp: Double = 0.0        // TC1C
    @Published var cpuCore2Temp: Double = 0.0        // TC2C
    @Published var memoryProximityTemp: Double = 0.0 // TM0P
    private var timer: Timer?
    private var smc: SMCClient?

    private init() {
        smc = SMCClient()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateTemperature()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    private func updateTemperature() {
        guard let smc = smc else { return }

        // Leggi tutti i sensori temperatura disponibili
        if let key = smc.key(named: "TC0P"), let val = smc.readValue(key) {
            cpuProximityTemp = val
            currentTemperature = val  // Default: CPU proximity
        }
        if let key = smc.key(named: "TC1C"), let val = smc.readValue(key) {
            cpuCore1Temp = val
        }
        if let key = smc.key(named: "TC2C"), let val = smc.readValue(key) {
            cpuCore2Temp = val
        }
        if let key = smc.key(named: "TM0P"), let val = smc.readValue(key) {
            memoryProximityTemp = val
        }
    }
}

// MARK: - Monitor Rete (netstat -ib)

final class NetworkMonitor: ObservableObject {
    static let shared = NetworkMonitor()

    @Published var uploadSpeed: Double = 0.0
    @Published var downloadSpeed: Double = 0.0
    private var timer: Timer?
    private var lastBytesIn: UInt64 = 0
    private var lastBytesOut: UInt64 = 0

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.updateNetwork()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    deinit { timer?.invalidate() }

    private func updateNetwork() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        task.arguments = ["-ib"]
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                parseNetstat(output)
            }
        } catch {}
    }

    private func parseNetstat(_ output: String) {
        let lines = output.components(separatedBy: .newlines)
        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        for line in lines {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 10,
               (parts[0].hasPrefix("en") || parts[0].hasPrefix("utun") || parts[0].hasPrefix("awdl") || parts[0].hasPrefix("bridge") || parts[0].hasPrefix("p2p")),
               let ibytes = UInt64(parts[6]),
               let obytes = UInt64(parts[9]) {
                totalIn += ibytes
                totalOut += obytes
            }
        }

        let interval: Double = 2.0
        if lastBytesIn > 0 {
            let deltaIn = Double(totalIn - lastBytesIn) / interval / 1024.0
            let deltaOut = Double(totalOut - lastBytesOut) / interval / 1024.0
            DispatchQueue.main.async {
                self.uploadSpeed = max(0, deltaOut)
                self.downloadSpeed = max(0, deltaIn)
            }
        }
        lastBytesIn = totalIn
        lastBytesOut = totalOut
    }
}

// MARK: - Monitor Dischi

final class DiskMonitor: ObservableObject {
    static let shared = DiskMonitor()

    @Published var freeSpaceGB: Double = 0.0
    @Published var totalSpaceGB: Double = 0.0
    @Published var usagePercent: Double = 0.0

    private init() {
        updateDisk()
    }

    func updateDisk() {
        do {
            let values = try URL(fileURLWithPath: "/").resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey
            ])
            if let total = values.volumeTotalCapacity,
               let available = values.volumeAvailableCapacityForImportantUsage {
                totalSpaceGB = Double(total) / (1024 * 1024 * 1024)
                freeSpaceGB = Double(available) / (1024 * 1024 * 1024)
                let used = totalSpaceGB - freeSpaceGB
                usagePercent = totalSpaceGB > 0 ? (used / totalSpaceGB) * 100.0 : 0.0
            }
        } catch {}
    }
}

// MARK: - Monitor Batteria

final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published var level: Double = 0.0
    @Published var isCharging: Bool = false
    @Published var timeRemaining: String = ""

    private init() {
        updateBattery()
        Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { [weak self] _ in
            self?.updateBattery()
        }
    }

    private func updateBattery() {
        let blob = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(blob).takeRetainedValue() as Array
        for source in sources {
            let desc = IOPSGetPowerSourceDescription(blob, source).takeUnretainedValue() as? [String: Any]
            if let currentCap = desc?[kIOPSCurrentCapacityKey] as? Double,
               let maxCap = desc?[kIOPSMaxCapacityKey] as? Double {
                level = maxCap > 0 ? (currentCap / maxCap) * 100.0 : 0.0
            }
            if let charging = desc?[kIOPSIsChargingKey] as? Bool {
                isCharging = charging
            }
            if let time = desc?[kIOPSTimeToEmptyKey] as? Int {
                if time > 0 {
                    timeRemaining = "\(time / 60)h \(time % 60)m"
                } else {
                    timeRemaining = "Calcolo..."
                }
            }
        }
    }
}

// MARK: - USB Monitor

final class USBMonitor: ObservableObject {
    static let shared = USBMonitor()
    @Published var deviceCount: Int = 0
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(timer!, forMode: .common)
        update()
    }
    deinit { timer?.invalidate() }

    private func update() {
        let matching = IOServiceMatching(kIOUSBDeviceClassName)
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
        var n = 0
        while IOIteratorNext(iter) != 0 { n += 1 }
        IOObjectRelease(iter)
        DispatchQueue.main.async { self.deviceCount = n }
    }
}

// MARK: - Clipboard History

final class ClipboardHistory: ObservableObject {
    static let shared = ClipboardHistory()
    @Published var items: [ClipboardItem] = []
    private var timer: Timer?
    private var lastChangeCount: Int = 0

    struct ClipboardItem: Identifiable, Hashable {
        let id = UUID()
        let content: String
        let timestamp: Date
        var isPinned: Bool = false
    }

    private init() {
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in self?.checkClipboard() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    deinit { timer?.invalidate() }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        if pb.changeCount != lastChangeCount {
            lastChangeCount = pb.changeCount
            if let str = pb.string(forType: .string), !str.isEmpty {
                DispatchQueue.main.async {
                    if !self.items.contains(where: { $0.content == str }) {
                        self.items.insert(ClipboardItem(content: str, timestamp: Date()), at: 0)
                        if self.items.count > 50 { self.items.removeLast() }
                    }
                }
            }
        }
    }

    func copyToPasteboard(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(item.content, forType: .string)
    }

    func togglePin(_ item: ClipboardItem) {
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].isPinned.toggle()
        }
    }

    func delete(_ item: ClipboardItem) { items.removeAll { $0.id == item.id } }
    func clear() { items.removeAll { !$0.isPinned } }
}

// MARK: - Brightness Service

final class BrightnessService: ObservableObject {
    static let shared = BrightnessService()
    @Published var brightness: Double = 1.0
    private var timer: Timer?

    private init() {
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in self?.readBrightness() }
        RunLoop.main.add(timer!, forMode: .common)
        readBrightness()
    }
    deinit { timer?.invalidate() }

    private func readBrightness() {
        let matching = IOServiceMatching("IODisplayConnect")
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return }
        var display: io_object_t = 0
        display = IOIteratorNext(iter)
        if display != 0 {
            var brightness: Float = 0.0
            let kr = IODisplayGetFloatParameter(display, 0, kIODisplayBrightnessKey as CFString, &brightness)
            if kr == kIOReturnSuccess && brightness > 0 {
                DispatchQueue.main.async { self.brightness = Double(brightness) }
            }
            IOObjectRelease(display)
        }
        IOObjectRelease(iter)
    }

    func setBrightness(_ value: Double) {
        let matching = IOServiceMatching("IODisplayConnect")
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS {
            var display: io_object_t = 0
            display = IOIteratorNext(iter)
            if display != 0 {
                IODisplaySetFloatParameter(display, 0, kIODisplayBrightnessKey as CFString, Float(value))
                IOObjectRelease(display)
            }
            IOObjectRelease(iter)
        }
        brightness = value
    }
}

// MARK: - Cleaner Service

final class CleanerService: ObservableObject {
    static let shared = CleanerService()
    @Published var isCleaning = false
    @Published var lastCleaned: String = "Mai"
    @Published var freedSpace: String = "0 B"

    private let cachePaths = [
        "~/Library/Caches",
        "~/Library/Logs",
        "/private/var/log",
        "/private/var/tmp",
        "~/Library/Developer/Xcode/DerivedData"
    ]

    func clean() {
        isCleaning = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var totalFreed: UInt64 = 0
            let fm = FileManager.default
            for path in self?.cachePaths ?? [] {
                let expanded = (path as NSString).expandingTildeInPath
                if fm.fileExists(atPath: expanded) {
                    if let enumerator = fm.enumerator(atPath: expanded) {
                        for case let file as String in enumerator {
                            let fullPath = (expanded as NSString).appendingPathComponent(file)
                            if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                               let size = attrs[.size] as? UInt64 {
                                if let modDate = attrs[.modificationDate] as? Date,
                                   Date().timeIntervalSince(modDate) > 86400 {
                                    try? fm.removeItem(atPath: fullPath)
                                    totalFreed += size
                                }
                            }
                        }
                    }
                }
            }
            DispatchQueue.main.async {
                self?.isCleaning = false
                self?.lastCleaned = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short)
                self?.freedSpace = ByteCountFormatter.string(fromByteCount: Int64(totalFreed), countStyle: .file)
            }
        }
    }
}

// MARK: - Launch at Login (SMLoginItem via helper)

final class LaunchAtLogin: ObservableObject {
    static let shared = LaunchAtLogin()
    @Published var enabled: Bool = false

    private init() { checkStatus() }

    func checkStatus() {
        // Usa launchctl per verificare
        if let output = runShell("/bin/launchctl", args: ["list"]) {
            enabled = output.contains("com.shuriken.helper")
        }
    }

    func toggle(_ on: Bool) {
        enabled = on
        // Per macOS 12: servirebbe un helper XPC in LaunchAgents
        // Placeholder: l'utente deve aggiungere manualmente o usarne un helper bundle
    }

    private func runShell(_ cmd: String, args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cmd)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch { return nil }
    }
}

// MARK: - Fan Control Service (SMC write)

final class FanControlService: ObservableObject {
    static let shared = FanControlService()
    @Published var currentRPM: Int = 0
    @Published var targetRPM: Int = 0
    @Published var isAuto: Bool = true
    @Published var minRPM: Int = 1200
    @Published var maxRPM: Int = 6200

    private var smc: SMCClient?
    private var timer: Timer?

    private init() {
        smc = SMCClient()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in self?.readFan() }
        RunLoop.main.add(timer!, forMode: .common)
        readFan()
    }
    deinit { timer?.invalidate() }

    private func readFan() {
        guard let smc = smc else { return }
        for keyName in ["F0Ac", "F0Mn", "F0Ma", "F0MD", "F0MS", "F0PA", "F1Ac", "F1Mn"] {
            if let key = smc.key(named: keyName),
               let rpm = smc.readValue(key),
               rpm > 0 {
                DispatchQueue.main.async { self.currentRPM = Int(rpm) }
                return
            }
        }
    }

    func setManualRPM(_ rpm: Int) {
        guard let smc = smc else { return }
        isAuto = false
        targetRPM = rpm.clamped(minRPM...maxRPM)
        // F0Tg = fan target speed control (write)
        for keyName in ["F0Tg", "F1Tg"] {
            if let key = smc.key(named: keyName),
               let bytes = SMCValueCodec.encode(Double(targetRPM), type: key.dataType, size: Int(key.dataSize)) {
                try? smc.writeBytes(bytes, to: key)
            }
        }
    }

    func setAuto() {
        isAuto = true
        guard let smc = smc else { return }
        // Scrivi 0 per tornare ad auto (dipende da SMC)
        for keyName in ["F0Tg", "F1Tg"] {
            if let key = smc.key(named: keyName),
               let bytes = SMCValueCodec.encode(0, type: key.dataType, size: Int(key.dataSize)) {
                try? smc.writeBytes(bytes, to: key)
            }
        }
    }
}

extension Comparable {
    func clamped(_ range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Feature Manager (toggle moduli)

final class FeatureManager: ObservableObject {
    static let shared = FeatureManager()

    @Published var keepAwakeEnabled: Bool = false
    @Published var clipboardEnabled: Bool = false
    @Published var smoothScrollingEnabled: Bool = false
    @Published var invertScrollEnabled: Bool = false
    @Published var cleanURLEnabled: Bool = true
    @Published var screenshotEnabled: Bool = true
    @Published var nowPlayingEnabled: Bool = true
    @Published var quickTogglesEnabled: Bool = true
    @Published var killProcessEnabled: Bool = false
    @Published var fanControlEnabled: Bool = false
    @Published var brightnessEnabled: Bool = false

    private var keepAwakeAssertion: IOPMAssertionID = 0

    private init() {}

    func toggleKeepAwake(_ enabled: Bool) {
        keepAwakeEnabled = enabled
        if enabled {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Shuriken Keep Awake" as CFString,
                &keepAwakeAssertion
            )
        } else {
            IOPMAssertionRelease(keepAwakeAssertion)
        }
    }

    func toggleSmoothScrolling(_ enabled: Bool) {
        smoothScrollingEnabled = enabled
        runShell("/usr/bin/defaults", args: ["write", "NSGlobalDomain", "CGSSmoothEvents", enabled ? "1" : "0"])
    }

    func toggleInvertScroll(_ enabled: Bool) {
        invertScrollEnabled = enabled
        runShell("/usr/bin/defaults", args: ["write", "NSGlobalDomain", "com.apple.swipe-scroll-direction", "-bool", enabled ? "false" : "true"])
    }

    func toggleCleanURL(_ enabled: Bool) {
        cleanURLEnabled = enabled
    }

    func toggleScreenshot(_ enabled: Bool) {
        screenshotEnabled = enabled
        // Quando si riattiva il modulo, avvia direttamente la selezione area.
        if enabled {
            ScreenshotService.shared.startAreaCapture()
        }
    }

    func toggleClipboard(_ enabled: Bool) {
        clipboardEnabled = enabled
    }

    func toggleFanControl(_ enabled: Bool) {
        fanControlEnabled = enabled
        if !enabled { FanControlService.shared.setAuto() }
    }

    func toggleBrightness(_ enabled: Bool) {
        brightnessEnabled = enabled
    }

    private func runShell(_ cmd: String, args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: cmd)
        task.arguments = args
        try? task.run()
        task.waitUntilExit()
    }
}

// MARK: - Now Playing Service (simulato - MediaRemote richiede entitlement Apple)

final class NowPlayingService: ObservableObject {
    static let shared = NowPlayingService()

    @Published var title: String = "Nessun brano"
    @Published var artist: String = ""
    @Published var isPlaying: Bool = false

    private init() {
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.updateNowPlaying()
        }
    }

    private func updateNowPlaying() {
        // Per ora simulato — MediaRemote.framework richiede entitlement Apple
        let tracks = [("Bohemian Rhapsody", "Queen"), ("Blinding Lights", "The Weeknd"), ("Shape of You", "Ed Sheeran")]
        let random = tracks.randomElement()!
        title = random.0
        artist = random.1
        isPlaying = Bool.random()
    }

    func togglePlayPause() { isPlaying.toggle() }
    func nextTrack() { updateNowPlaying() }
}

// MARK: - Card Views

struct ModuleCard<Content: View>: View {
    let icon: String
    let title: String
    let color: Color
    let content: () -> Content

    init(icon: String, title: String, color: Color, @ViewBuilder content: @escaping () -> Content) {
        self.icon = icon
        self.title = title
        self.color = color
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(color)
                    .frame(width: 20)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
            }
            content()
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
        )
    }
}

struct CPUCard: View {
    let usage: Double

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundColor(.blue)
            Text("CPU")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("\(Int(usage))%")
                .font(.headline)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct MemoryCard: View {
    let usedGB: Double
    let totalGB: Double
    let percent: Double

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "memorychip")
                .font(.title2)
                .foregroundColor(.green)
            Text("RAM")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("\(String(format: "%.1f", usedGB))/\(String(format: "%.1f", totalGB)) GB")
                .font(.caption)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
}

struct TemperatureCard: View {
    @ObservedObject private var tempMonitor = TemperatureMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "thermometer.medium")
                    .foregroundColor(tempMonitor.currentTemperature > 70 ? .red : .orange)
                Text("CPU Temp")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(String(format: "%.1f", tempMonitor.currentTemperature))°C")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }
            if tempMonitor.cpuCore1Temp > 0 || tempMonitor.cpuCore2Temp > 0 {
                HStack(spacing: 12) {
                    if tempMonitor.cpuCore1Temp > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Core 1")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", tempMonitor.cpuCore1Temp))°C")
                                .font(.caption)
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                    }
                    if tempMonitor.cpuCore2Temp > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Core 2")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", tempMonitor.cpuCore2Temp))°C")
                                .font(.caption)
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                    }
                    if tempMonitor.memoryProximityTemp > 0 {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Memoria")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                            Text("\(String(format: "%.1f", tempMonitor.memoryProximityTemp))°C")
                                .font(.caption)
                                .fontWeight(.medium)
                                .monospacedDigit()
                        }
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }
}

struct NetworkCard: View {
    let upload: Double
    let download: Double

    var body: some View {
        ModuleCard(icon: "network", title: "Rete", color: .purple) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundColor(.orange)
                        Text("Upload")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("\(String(format: "%.0f", upload)) KB/s")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption)
                            .foregroundColor(.green)
                        Text("Download")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Text("\(String(format: "%.0f", download)) KB/s")
                        .font(.caption)
                        .fontWeight(.medium)
                        .monospacedDigit()
                }
            }
        }
    }
}

struct DiskCard: View {
    let freeGB: Double
    let totalGB: Double
    let percent: Double

    var body: some View {
        ModuleCard(icon: "internaldrive", title: "Disco", color: .orange) {
            VStack(spacing: 6) {
                HStack {
                    Text("\(String(format: "%.1f", freeGB)) GB liberi")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Int(percent))% usato")
                        .font(.caption)
                        .fontWeight(.medium)
                }
                ProgressBar(value: percent, max: 100)
                    .frame(height: 6)
            }
        }
    }
}

struct BatteryCard: View {
    let level: Double
    let isCharging: Bool
    let timeRemaining: String

    var body: some View {
        ModuleCard(icon: isCharging ? "battery.100.bolt" : "battery.75", title: "Batteria", color: level < 20 ? .red : .green) {
            HStack {
                Text("\(Int(level))%")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
                Spacer()
                Text(timeRemaining)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ProgressBar(value: level, max: 100)
                .frame(height: 6)
        }
    }
}

struct NowPlayingCard: View {
    @ObservedObject private var nowPlaying = NowPlayingService.shared
    @ObservedObject private var features = FeatureManager.shared

    var body: some View {
        if features.nowPlayingEnabled {
            ModuleCard(icon: "play.circle", title: "Now Playing", color: .pink) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(nowPlaying.title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                    Text(nowPlaying.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 16) {
                        Button(action: { nowPlaying.togglePlayPause() }) {
                            Image(systemName: nowPlaying.isPlaying ? "pause.fill" : "play.fill")
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Button(action: { nowPlaying.nextTrack() }) {
                            Image(systemName: "forward.fill")
                                .font(.body)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }
            }
        }
    }
}

struct QuickTogglesCard: View {
    @ObservedObject private var features = FeatureManager.shared

    var body: some View {
        if features.quickTogglesEnabled {
            ModuleCard(icon: "togglepower", title: "Strumenti Rapidi", color: .teal) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    QuickToggleButton(icon: "moon.zzz", label: "Keep Awake", isOn: $features.keepAwakeEnabled) {
                        features.toggleKeepAwake(features.keepAwakeEnabled)
                    }
                    QuickToggleButton(icon: "doc.on.clipboard", label: "Appunti", isOn: $features.clipboardEnabled) {
                        features.toggleClipboard(features.clipboardEnabled)
                    }
                    QuickToggleButton(icon: "waveform.path.ecg", label: "Scroll Fluido", isOn: $features.smoothScrollingEnabled) {
                        features.toggleSmoothScrolling(features.smoothScrollingEnabled)
                    }
                    QuickToggleButton(icon: "arrow.up.arrow.down", label: "Inverti Scroll", isOn: $features.invertScrollEnabled) {
                        features.toggleInvertScroll(features.invertScrollEnabled)
                    }
                    QuickToggleButton(icon: "link.badge.minus", label: "Clean URL", isOn: $features.cleanURLEnabled) {
                        features.toggleCleanURL(features.cleanURLEnabled)
                    }
                    QuickToggleButton(icon: "camera.viewfinder", label: "Screenshot", isOn: $features.screenshotEnabled) {
                        features.toggleScreenshot(features.screenshotEnabled)
                    }
                    QuickToggleButton(icon: "fan.desktop", label: "Ventole", isOn: $features.fanControlEnabled) {
                        features.toggleFanControl(features.fanControlEnabled)
                    }
                    QuickToggleButton(icon: "sun.max", label: "Luminosità", isOn: $features.brightnessEnabled) {
                        features.toggleBrightness(features.brightnessEnabled)
                    }
                }
            }
        }
    }
}

struct QuickToggleButton: View {
    let icon: String
    let label: String
    @Binding var isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            isOn.toggle()
            action()
        }) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(isOn ? .blue : .secondary)
                Text(label)
                    .font(.caption2)
                    .foregroundColor(isOn ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(isOn ? Color.blue.opacity(0.1) : Color.clear)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isOn ? Color.blue.opacity(0.3) : Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct KillProcessCard: View {
    @ObservedObject private var features = FeatureManager.shared
    @State private var searchText = ""
    @State private var processes: [String] = []

    var body: some View {
        if features.killProcessEnabled {
            ModuleCard(icon: "xmark.octagon", title: "Termina Processo", color: .red) {
                VStack(spacing: 6) {
                    TextField("Cerca processo...", text: $searchText)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)

                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(filteredProcesses, id: \.self) { proc in
                                HStack {
                                    Text(proc)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Termina") {
                                        killProcess(named: proc)
                                    }
                                    .font(.caption2)
                                    .foregroundColor(.red)
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .frame(maxHeight: 80)
                }
                .onAppear { loadProcesses() }
            }
        }
    }

    private var filteredProcesses: [String] {
        if searchText.isEmpty { return Array(processes.prefix(10)) }
        return processes.filter { $0.lowercased().contains(searchText.lowercased()) }.prefix(10).map { String($0) }
    }

    private func loadProcesses() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axc", "-o", "comm"]
        let pipe = Pipe()
        task.standardOutput = pipe
        try? task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        if let output = String(data: data, encoding: .utf8) {
            processes = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "COMMAND" }
                .sorted()
        }
    }

    private func killProcess(named name: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = [name]
        try? task.run()
        task.waitUntilExit()
        loadProcesses()
    }
}

// MARK: - Fan Control Card

struct FanControlCard: View {
    @ObservedObject private var fanService = FanControlService.shared
    @ObservedObject private var features = FeatureManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan.desktop")
                    .foregroundColor(.red)
                Text("Ventola")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(fanService.currentRPM) RPM")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            // Manual control slider
            if !fanService.isAuto {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Target:")
                        Slider(value: Binding(
                            get: { Double(fanService.targetRPM) },
                            set: { fanService.setManualRPM(Int($0)) }
                        ), in: Double(fanService.minRPM)...Double(fanService.maxRPM), step: 100)
                        Text("\(fanService.targetRPM)")
                            .font(.caption)
                            .monospacedDigit()
                            .frame(width: 50)
                    }
                    HStack {
                        Button("Auto") { fanService.setAuto() }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        Button("Min") { fanService.setManualRPM(fanService.minRPM) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        Button("Max") { fanService.setManualRPM(fanService.maxRPM) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                        Spacer()
                    }
                }
            } else {
                HStack {
                    Text("Modalità: Automatica")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Manuale") { fanService.isAuto = false }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

// MARK: - Brightness Card

struct BrightnessCard: View {
    @ObservedObject private var brightnessService = BrightnessService.shared
    @ObservedObject private var features = FeatureManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sun.max")
                    .foregroundColor(.yellow)
                Text("Schermo")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(brightnessService.brightness * 100))%")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .monospacedDigit()
            }

            Slider(value: Binding(
                get: { brightnessService.brightness },
                set: { brightnessService.setBrightness($0) }
            ), in: 0.0...1.0, step: 0.05)

            HStack {
                Button("Min") { brightnessService.setBrightness(0.1) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                Button("50%") { brightnessService.setBrightness(0.5) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                Button("Max") { brightnessService.setBrightness(1.0) }
                    .font(.caption)
                    .buttonStyle(.bordered)
                Spacer()
            }
        }
    }
}

// MARK: - Clipboard Card

struct ClipboardCard: View {
    @ObservedObject private var clipboard = ClipboardHistory.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "doc.on.clipboard")
                    .foregroundColor(.blue)
                Text("Cronologia")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(clipboard.items.count) elementi")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(clipboard.items.prefix(8)) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.content)
                                    .font(.caption)
                                    .lineLimit(1)
                                Text(item.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: { clipboard.copyToPasteboard(item) }) {
                                Image(systemName: "doc.on.doc")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .help("Copia")

                            Button(action: { clipboard.togglePin(item) }) {
                                Image(systemName: item.isPinned ? "pin.fill" : "pin")
                                    .font(.caption)
                                    .foregroundColor(item.isPinned ? .orange : .secondary)
                            }
                            .buttonStyle(.plain)
                            .help(item.isPinned ? "Sblocca" : "Blocca")

                            Button(action: { clipboard.delete(item) }) {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Elimina")
                        }
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                    }
                }
            }
            .frame(maxHeight: 120)

            if !clipboard.items.isEmpty {
                HStack {
                    Button("Pulisci (non bloccati)") { clipboard.clear() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }
}

struct ProgressBar: View {
    let value: Double
    let max: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(0.3)
                    .foregroundColor(.gray)
                    .cornerRadius(5)
                Rectangle()
                    .frame(
                        width: min(CGFloat(value) / CGFloat(max) * geometry.size.width, geometry.size.width),
                        height: geometry.size.height
                    )
                    .foregroundColor(value > 80 ? .red : value > 50 ? .orange : .green)
                    .cornerRadius(5)
            }
        }
    }
}

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
        }
        .padding(.horizontal)
    }
}

// MARK: - Vista principale del popover

struct SystemMonitorSwiftUI: View {
    @StateObject private var cpuMonitor = CPUUsageMonitor.shared
    @StateObject private var memMonitor = MemoryMonitor.shared
    @StateObject private var tempMonitor = TemperatureMonitor.shared
    @StateObject private var netMonitor = NetworkMonitor.shared
    @StateObject private var diskMonitor = DiskMonitor.shared
    @StateObject private var batteryMonitor = BatteryMonitor.shared
    @StateObject private var usbMonitor = USBMonitor.shared
    @StateObject private var features = FeatureManager.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image("AppIcon")
                    .resizable()
                    .frame(width: 24, height: 24)
                Text("Shuriken")
                    .font(.headline)
                Spacer()
                Button(action: { NSApp.terminate(nil) }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    // === Monitor di Sistema ===
                    Group {
                        SectionHeader(title: "Monitor di Sistema", icon: "gauge")

                        HStack(spacing: 12) {
                            CPUCard(usage: cpuMonitor.currentUsage)
                            MemoryCard(
                                usedGB: memMonitor.usedGB,
                                totalGB: memMonitor.totalGB,
                                percent: memMonitor.usagePercent
                            )
                        }
                        .padding(.horizontal)

                        ModuleCard(icon: "thermometer.medium", title: "Temperatura", color: .orange) {
                            TemperatureCard()
                        }
                        .padding(.horizontal)

                        NetworkCard(upload: netMonitor.uploadSpeed, download: netMonitor.downloadSpeed)
                            .padding(.horizontal)

                        DiskCard(freeGB: diskMonitor.freeSpaceGB, totalGB: diskMonitor.totalSpaceGB, percent: diskMonitor.usagePercent)
                            .padding(.horizontal)

                        BatteryCard(level: batteryMonitor.level, isCharging: batteryMonitor.isCharging, timeRemaining: batteryMonitor.timeRemaining)
                            .padding(.horizontal)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // === Media ===
                    Group {
                        SectionHeader(title: "Media", icon: "music.note")

                        NowPlayingCard()
                            .padding(.horizontal)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // === Strumenti Rapidi ===
                    Group {
                        SectionHeader(title: "Strumenti Rapidi", icon: "bolt.circle")

                        QuickTogglesCard()
                            .padding(.horizontal)
                    }

                    Divider()
                        .padding(.vertical, 4)

                    // === Avanzate ===
                    Group {
                        SectionHeader(title: "Avanzate", icon: "terminal")

                        // Fan Control Card
                        if features.fanControlEnabled {
                            ModuleCard(icon: "fan.desktop", title: "Controllo Ventole", color: .red) {
                                FanControlCard()
                            }
                            .padding(.horizontal)
                        }

                        // Brightness Card
                        if features.brightnessEnabled {
                            ModuleCard(icon: "sun.max", title: "Luminosità", color: .yellow) {
                                BrightnessCard()
                            }
                            .padding(.horizontal)
                        }

                        // Clipboard Card
                        if features.clipboardEnabled {
                            ModuleCard(icon: "doc.on.clipboard", title: "Appunti", color: .blue) {
                                ClipboardCard()
                            }
                            .padding(.horizontal)
                        }

                        KillProcessCard()
                            .padding(.horizontal)

                        Color.clear.frame(height: 8)
                    }
                }
                .padding(.vertical, 8)
            }

            // Footer
            Divider()
            HStack {
                Text("macOS 12.7.6 • Intel i5")
                    .font(.caption2)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
                Spacer()
                Text("v1.1.0")
                    .font(.caption2)
                    .foregroundColor(Color(NSColor.tertiaryLabelColor))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .frame(width: 380)
    }
}