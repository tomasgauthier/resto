import Foundation

enum ClaudeUsageReader {
    /// La API manda el dato real; el JSON del statusline sólo sirve de respaldo, porque su
    /// bloque `five_hour` puede quedarse en una ventana ya vencida durante toda la sesión.
    static func read() async -> UsageSnapshot? {
        if let live = await liveUsage() { return live }
        let cached = cachedRateLimits()
        guard cached.fiveHour != nil || cached.weekly != nil else { return nil }
        return UsageSnapshot(provider: "Claude Code", fiveHour: cached.fiveHour, weekly: cached.weekly)
    }

    private static func liveUsage() async -> UsageSnapshot? {
        guard let oauth = credentials(),
              let token = oauth["accessToken"] as? String,
              let requestURL = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }
        var request = URLRequest(url: requestURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Claude Code", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 12
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else { return nil }
        let fiveHour = window(json["five_hour"])
        let weekly = window(json["seven_day"])
        guard fiveHour != nil || weekly != nil else { return nil }
        let plan = (oauth["subscriptionType"] as? String)?.capitalized ?? "Cuenta"
        return UsageSnapshot(provider: "Claude \(plan)", fiveHour: fiveHour, weekly: weekly)
    }

    /// El token vigente vive en el Llavero; `~/.claude/.credentials.json` suele quedar vencido.
    private static func credentials() -> [String: Any]? {
        let candidates = [keychainCredentials(), fileCredentials()].compactMap { $0 }
        return candidates.first(where: isUsable) ?? candidates.first
    }

    private static func isUsable(_ oauth: [String: Any]) -> Bool {
        guard let expiry = oauth["expiresAt"] as? TimeInterval else { return false }
        return Date(timeIntervalSince1970: expiry / 1000) > .now
    }

    /// Vía `security` y no `SecItemCopyMatching`: la ACL del ítem ya autoriza a la shell, mientras
    /// que un binario firmado ad-hoc cambia de identidad en cada build y pediría permiso cada vez.
    /// El token viaja por el pipe, nunca como argumento.
    private static func keychainCredentials() -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-w", "-s", "Claude Code-credentials", "-a", NSUserName()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return oauth(in: data)
    }

    private static func fileCredentials() -> [String: Any]? {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/.credentials.json")
        return (try? Data(contentsOf: file)).flatMap(oauth)
    }

    private static func oauth(in data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return root["claudeAiOauth"] as? [String: Any]
    }

    private static func cachedRateLimits() -> (fiveHour: UsageWindow?, weekly: UsageWindow?) {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state/servicios/claude-usage.json")
        guard let data = try? Data(contentsOf: file),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any] else { return (nil, nil) }
        return (cachedWindow(limits["five_hour"]), cachedWindow(limits["seven_day"]))
    }

    private static func cachedWindow(_ value: Any?) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = value["used_percentage"] as? Int,
              let reset = value["resets_at"] as? TimeInterval else { return nil }
        let date = Date(timeIntervalSince1970: reset)
        guard date > .now else { return nil }
        return UsageWindow(usedPercent: used, resetsAt: date)
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = value["utilization"] as? Double,
              let resetText = value["resets_at"] as? String,
              // La API manda seis decimales de segundo e ISO8601DateFormatter los rechaza.
              let reset = ISO8601DateFormatter().date(from: resetText.replacing(/\.\d+/, with: "")) else { return nil }
        return UsageWindow(usedPercent: Int(used.rounded()), resetsAt: reset)
    }
}
