import Foundation

enum KimiUsageReader {
    static func read() async -> Result<UsageSnapshot, UsageReadError> {
        let file = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".kimi-code/credentials/kimi-code.json")
        guard let data = try? Data(contentsOf: file),
              let credentials = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = credentials["access_token"] as? String,
              let expiry = credentials["expires_at"] as? TimeInterval else {
            return .failure(.init(message: "Inicia sesión con `kimi login`"))
        }
        guard Date(timeIntervalSince1970: expiry) > .now else {
            return .failure(.init(message: "Sesión vencida · ejecuta `kimi login`"))
        }
        var request = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12
        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            return .failure(.init(message: "No se pudo consultar la cuota"))
        }
        let rows = ([json["usage"]] + ((json["limits"] as? [[String: Any]])?.map { $0["detail"] } ?? [])).compactMap(window)
        guard let primary = rows.first else { return .failure(.init(message: "Kimi no entregó límites")) }
        return .success(UsageSnapshot(provider: "Kimi Code", fiveHour: primary, weekly: rows.dropFirst().first))
    }

    private static func window(_ value: Any?) -> UsageWindow? {
        guard let value = value as? [String: Any],
              let used = number(value["used"]), let limit = number(value["limit"]), limit > 0,
              let resetText = value["resetTime"] as? String,
              let reset = ISO8601DateFormatter().date(from: resetText) else { return nil }
        return UsageWindow(usedPercent: Int((used / limit * 100).rounded()), resetsAt: reset)
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? Double { return value }
        if let value = value as? String { return Double(value) }
        return nil
    }
}

struct UsageReadError: Error { let message: String }
