import Foundation

struct UsageWindow {
    let usedPercent: Int
    let resetsAt: Date

    /// Un proveedor puede reportar más de 100 (Kimi calcula `used/limit` sin tope): acotado
    /// acá, ninguna vista muestra un "queda -5 %".
    init(usedPercent: Int, resetsAt: Date) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
    }
}

struct UsageSnapshot {
    let provider: String
    /// La ventana de 5 h es el dato que la pebble muestra siempre; el semanal es contexto.
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

extension UsageSnapshot {
    /// Al cambiar de ventana la lectura llega a medias: la API deja `five_hour` en blanco y el
    /// caché en disco ya venció. Pisar lo anterior con eso manda la fila de la pebble a
    /// "en RAM" hasta el siguiente tick, así que se conserva lo último conocido de cada ventana.
    /// Lo heredado sólo vale mientras su ventana siga abierta: una que ya reinició mostraría el
    /// porcentaje de la anterior (un "90 % usado" que en verdad está en cero).
    func merging(over previous: UsageSnapshot?, now: Date = .now) -> UsageSnapshot {
        func open(_ window: UsageWindow?) -> UsageWindow? { window.flatMap { $0.resetsAt > now ? $0 : nil } }
        return UsageSnapshot(provider: provider,
                             fiveHour: fiveHour ?? open(previous?.fiveHour),
                             weekly: weekly ?? open(previous?.weekly))
    }

    static func selfCheck() -> Bool {
        let now = Date.now, later = now.addingTimeInterval(3600)
        let old = UsageSnapshot(provider: "viejo",
                                fiveHour: UsageWindow(usedPercent: 4, resetsAt: later),
                                weekly: UsageWindow(usedPercent: 27, resetsAt: later))
        let partial = UsageSnapshot(provider: "nuevo", fiveHour: nil, weekly: old.weekly)
        let merged = partial.merging(over: old, now: now)
        let fresh = UsageSnapshot(provider: "nuevo",
                                  fiveHour: UsageWindow(usedPercent: 9, resetsAt: later),
                                  weekly: nil)
        // Una ventana que ya reinició no se hereda: su porcentaje es de la ventana anterior.
        let expired = UsageSnapshot(provider: "viejo",
                                    fiveHour: UsageWindow(usedPercent: 90, resetsAt: now.addingTimeInterval(-1)),
                                    weekly: old.weekly)
        return merged.fiveHour?.usedPercent == 4 && merged.provider == "nuevo"
            && fresh.merging(over: old, now: now).fiveHour?.usedPercent == 9
            && fresh.merging(over: old, now: now).weekly?.usedPercent == 27
            && partial.merging(over: nil, now: now).fiveHour == nil
            && partial.merging(over: expired, now: now).fiveHour == nil
            && partial.merging(over: expired, now: now).weekly?.usedPercent == 27
    }
}

enum CodexUsageReader {
    /// Síncrono a propósito: el bucle de lectura bloquea el hilo, así que quien llame
    /// debe envolverlo en `blocking` y mantenerlo fuera del pool cooperativo.
    static func read() -> UsageSnapshot? {
        guard let executable = executablePath() else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Un `codex` instalado por npm es un script con `#!/usr/bin/env node`, y el PATH que
        // hereda una app de GUI no trae node: sin esto el hijo muere apenas parte.
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = AgentStatus.loginPath
        process.environment = environment

        do {
            try process.run()
            let opened = write(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "resto", "version": "0.1"], "capabilities": [:]]], to: input)
            Thread.sleep(forTimeInterval: 0.2)
            // Si el CLI no arrancó, acá el pipe ya está roto: se corta la lectura en vez de seguir.
            guard opened,
                  write(["method": "initialized", "params": [:]], to: input),
                  write(["method": "account/rateLimits/read", "id": 2], to: input) else {
                process.terminate()
                return nil
            }

            // La respuesta puede tardar varios segundos y cerrar stdin antes mata al servidor:
            // se lee hasta encontrarla, con el cierre programado como único tope.
            // ponytail: bloquea un hilo de GCD hasta 15 s cada 2 min; a callbacks si molesta.
            let stdin = input.fileHandleForWriting
            DispatchQueue.global().asyncAfter(deadline: .now() + 15) { try? stdin.close() }
            var buffer = Data()
            while true {
                let chunk = output.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                if let snapshot = decode(buffer) {
                    try? stdin.close()
                    process.terminate()
                    return snapshot
                }
            }
            try? stdin.close()
            process.waitUntilExit()
            return decode(buffer)
        } catch {
            // `run()` falló: el proceso nunca partió, y `terminate()` sobre uno así lanza una
            // excepción de Objective-C que Swift no atrapa.
            return nil
        }
    }

    private static func executablePath() -> URL? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex").path()]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    /// `write(contentsOf:)` y no `write(_:)`: con SIGPIPE ignorado, el que no lanza convierte el
    /// EPIPE en una excepción de ObjC que Swift no puede atrapar, y ahí muere igual.
    private static func write(_ message: [String: Any], to pipe: Pipe) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: message), var line = String(data: data, encoding: .utf8) else { return false }
        line += "\n"
        return (try? pipe.fileHandleForWriting.write(contentsOf: Data(line.utf8))) != nil
    }

    /// Escribirle a un hijo que ya murió da EPIPE. Sin SIGPIPE ignorado eso mataba la app entera
    /// —sin siquiera dejar reporte de crash— y basta con que el CLI no arranque para gatillarlo.
    static func selfCheck() -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/false")
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return write(["method": "ping"], to: input) == false
    }

    private static func decode(_ data: Data) -> UsageSnapshot? {
        for line in data.split(separator: 10) {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  (json["id"] as? Int) == 2,
                  let result = json["result"] as? [String: Any],
                  let limits = result["rateLimits"] as? [String: Any],
                  let fiveHour = window(limits["primary"]) else { continue }
            let plan = (limits["planType"] as? String)?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Cuenta"
            return UsageSnapshot(provider: "ChatGPT \(plan)", fiveHour: fiveHour, weekly: window(limits["secondary"]))
        }
        return nil
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = value["usedPercent"] as? Int,
              let reset = value["resetsAt"] as? TimeInterval else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: Date(timeIntervalSince1970: reset))
    }
}
