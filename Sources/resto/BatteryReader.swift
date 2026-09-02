import Foundation
import IOKit.ps

struct Battery {
    let percent: Int
    let isCharging: Bool
    let isPlugged: Bool
    /// Minutos que estima el sistema; nil mientras todavía está calculando.
    let minutesRemaining: Int?
    let cycles: Int?
    /// Porcentaje de la capacidad de diseño, tal como lo muestra macOS en Ajustes.
    let maxCapacity: Int?
    let condition: String?

    var stateText: String {
        if isCharging { return "cargando" }
        return isPlugged ? "enchufada" : "a batería"
    }

    var timeText: String? {
        guard let minutesRemaining, minutesRemaining > 0 else { return nil }
        let text = "\(minutesRemaining / 60):\(String(format: "%02d", minutesRemaining % 60))"
        return isCharging ? "\(text) para carga completa" : "\(text) de autonomía"
    }

    var healthText: String? {
        var parts: [String] = []
        if let cycles { parts.append("\(cycles) ciclos") }
        if let maxCapacity { parts.append("capacidad máxima \(maxCapacity)%") }
        if let condition, condition != "Normal" { parts.append(condition) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum BatteryReader {
    /// Carga y estado salen de IOKit: es instantáneo y no gasta un proceso cada 30 s.
    /// La salud no: ciclos y capacidad máxima sólo cuadran con lo que muestra macOS si se
    /// leen de `system_profiler`, que tarda ~1 s. Como son números que no se mueven en
    /// horas, se consultan una vez al día.
    static func read() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                  info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = info[kIOPSIsChargingKey] as? Bool ?? false
            let plugged = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let minutes = info[charging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            let health = cachedHealth()
            return Battery(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: charging,
                isPlugged: plugged,
                // El sistema manda -1 mientras todavía no sabe estimar.
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil,
                cycles: health.cycles,
                maxCapacity: health.maxCapacity,
                condition: health.condition
            )
        }
        return nil   // equipo de escritorio
    }

    struct Health { var cycles: Int?; var maxCapacity: Int?; var condition: String? }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: (health: Health, at: Date)?

    private static func cachedHealth() -> Health {
        lock.lock()
        if let cache, Date.now.timeIntervalSince(cache.at) < 86_400 {
            defer { lock.unlock() }
            return cache.health
        }
        lock.unlock()
        let fresh = readHealth()
        lock.lock()
        cache = (fresh, .now)
        lock.unlock()
        return fresh
    }

    private static func readHealth() -> Health {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
        process.arguments = ["SPPowerDataType"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return Health() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parseHealth(String(decoding: data, as: UTF8.self))
    }

    static func parseHealth(_ text: String) -> Health {
        var health = Health()
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "Cycle Count": health.cycles = Int(pair[1])
            case "Maximum Capacity": health.maxCapacity = Int(pair[1].replacingOccurrences(of: "%", with: ""))
            case "Condition": health.condition = pair[1]
            default: continue
            }
        }
        return health
    }

    static func selfCheck() -> Bool {
        let sample = """
              Charging: No
              State of Charge (%): 100
              Cycle Count: 403
              Condition: Normal
              Maximum Capacity: 87%
        """
        let health = parseHealth(sample)
        let sinTiempo = Battery(percent: 100, isCharging: false, isPlugged: true, minutesRemaining: nil,
                                cycles: health.cycles, maxCapacity: health.maxCapacity, condition: health.condition)
        let cargando = Battery(percent: 42, isCharging: true, isPlugged: true, minutesRemaining: 95,
                               cycles: nil, maxCapacity: nil, condition: nil)
        return health.cycles == 403 && health.maxCapacity == 87 && health.condition == "Normal"
            && sinTiempo.healthText == "403 ciclos · capacidad máxima 87%"   // "Normal" no se muestra
            && sinTiempo.timeText == nil && sinTiempo.stateText == "enchufada"
            && cargando.timeText == "1:35 para carga completa"
            && cargando.stateText == "cargando" && cargando.healthText == nil
    }
}
