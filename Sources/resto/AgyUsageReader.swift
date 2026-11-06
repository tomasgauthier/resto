import Foundation

/// `agy` no guarda la cuota en ningún lado: sólo la entrega al statusline en cada render, y
/// `~/.gemini/antigravity-cli/statusline.sh` la vuelca acá. Envejece si no hay sesión abierta.
enum AgyUsageReader {
    static let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state/servicios/agy-usage.json")

    static func read(now: Date = .now) -> Result<UsageSnapshot, UsageReadError> {
        guard let data = try? Data(contentsOf: file) else {
            return .failure(.init(message: "Abre agy para actualizar la cuota"))
        }
        guard let usage = parse(data, now: now) else { return .failure(.init(message: "agy no entregó cuota")) }
        return .success(usage)
    }

    /// Los baldes vienen por familia de modelo (`gemini-5h`, `3p-5h`, `gemini-argon-wtu-weekly`…):
    /// por cada ventana manda el más apretado, que es el que corta primero.
    static func parse(_ data: Data, now: Date) -> UsageSnapshot? {
        guard let buckets = try? JSONSerialization.jsonObject(with: data) as? [String: [String: Any]] else { return nil }
        func tightest(_ suffix: String) -> UsageWindow? {
            buckets.filter { $0.key.hasSuffix(suffix) }.values.compactMap { bucket -> UsageWindow? in
                guard let left = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue,
                      let text = bucket["reset_time"] as? String,
                      let reset = ISO8601DateFormatter().date(from: text), reset > now else { return nil }
                return UsageWindow(usedPercent: Int(((1 - left) * 100).rounded()), resetsAt: reset)
            }.max { $0.usedPercent < $1.usedPercent }
        }
        let fiveHour = tightest("-5h"), weekly = tightest("weekly")
        guard fiveHour != nil || weekly != nil else { return nil }
        return UsageSnapshot(provider: "Antigravity", fiveHour: fiveHour, weekly: weekly)
    }

    static func selfCheck() -> Bool {
        let now = ISO8601DateFormatter().date(from: "2026-11-06T15:00:00Z")!
        let sample = Data("""
        {"gemini-5h": {"remaining_fraction": 1, "reset_time": "2026-11-06T19:41:41Z"},
         "3p-5h": {"remaining_fraction": 0.8, "reset_time": "2026-11-06T18:00:00Z"},
         "gemini-weekly": {"remaining_fraction": 1, "reset_time": "2026-11-13T14:41:41Z"},
         "gemini-argon-wtu-weekly": {"remaining_fraction": 0.98688626, "reset_time": "2026-11-13T14:36:50Z"}}
        """.utf8)
        // C1: cada ventana toma el balde más apretado, con su propio reinicio.
        guard let usage = parse(sample, now: now),
              usage.fiveHour?.usedPercent == 20,
              usage.fiveHour?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-06T18:00:00Z"),
              usage.weekly?.usedPercent == 1,
              usage.weekly?.resetsAt == ISO8601DateFormatter().date(from: "2026-11-13T14:36:50Z") else { return false }
        // C2: una ventana ya reiniciada no se muestra; el porcentaje es de la anterior.
        let later = now.addingTimeInterval(6 * 3600)
        guard let stale = parse(sample, now: later), stale.fiveHour == nil, stale.weekly != nil else { return false }
        // Sin baldes no hay cuota que mostrar.
        return parse(Data("{}".utf8), now: now) == nil
    }
}
