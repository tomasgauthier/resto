import Foundation

struct UsageWindow {
    let usedPercent: Int
    let resetsAt: Date
}

struct UsageSnapshot {
    let provider: String
    /// La ventana de 5 h es el dato que la pebble muestra siempre; el semanal es contexto.
    let fiveHour: UsageWindow?
    let weekly: UsageWindow?
}

enum CodexUsageReader {
    static func read() async -> UsageSnapshot? {
        guard let executable = executablePath() else { return nil }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            write(["method": "initialize", "id": 1, "params": ["clientInfo": ["name": "resto", "version": "0.1"], "capabilities": [:]]], to: input)
            try? await Task.sleep(for: .milliseconds(200))
            write(["method": "initialized", "params": [:]], to: input)
            write(["method": "account/rateLimits/read", "id": 2], to: input)

            // La respuesta puede tardar varios segundos y cerrar stdin antes mata al servidor:
            // se lee hasta encontrarla, con el cierre programado como único tope.
            // ponytail: bloquea un hilo del pool hasta 15 s cada 2 min; a callbacks si molesta.
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
            process.terminate()
            return nil
        }
    }

    private static func executablePath() -> URL? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/codex").path()]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }

    private static func write(_ message: [String: Any], to pipe: Pipe) {
        guard let data = try? JSONSerialization.data(withJSONObject: message), var line = String(data: data, encoding: .utf8) else { return }
        line += "\n"
        pipe.fileHandleForWriting.write(Data(line.utf8))
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
