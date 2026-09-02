import Foundation
import SQLite3

enum Agent: CaseIterable, Identifiable {
    case claude, codex, kimi, agy, gemini, opencode, copilot

    var id: String { command }
    var title: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .kimi: "Kimi Code"
        case .agy: "Antigravity"
        case .gemini: "Gemini CLI"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot"
        }
    }
    var command: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .kimi: "kimi"
        case .agy: "agy"
        case .gemini: "gemini"
        case .opencode: "opencode"
        case .copilot: "copilot"
        }
    }
    /// Nombre corto para la pebble, donde no cabe el título completo.
    var shortTitle: String {
        switch self {
        case .claude: "Claude"
        case .codex: "ChatGPT"
        case .kimi: "Kimi"
        case .agy: "Agy"
        case .gemini: "Gemini"
        case .opencode: "OpenCode"
        case .copilot: "Copilot"
        }
    }
    static func named(_ command: String) -> Agent? { allCases.first { $0.command == command } }
    var symbol: String { "terminal" }
    var sessionDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claude: return home.appending(path: ".claude/projects")
        case .codex: return home.appending(path: ".codex/sessions")
        case .kimi: return home.appending(path: ".kimi/user-history")
        // ponytail: `agy` aún no deja historial local; si algún día lo hace acá aparece solo.
        case .agy: return home.appending(path: ".agy/sessions")
        case .gemini: return home.appending(path: ".gemini/tmp")
        case .opencode: return home.appending(path: ".local/share/opencode")
        case .copilot: return home.appending(path: ".copilot/session-state")
        }
    }
}

struct AgentStatus: Identifiable {
    let agent: Agent
    let installed: Bool
    let session: LocalSession?
    /// RSS sumado de los procesos vivos del CLI; nil cuando no hay ninguno corriendo.
    let residentBytes: UInt64?
    var id: Agent { agent }
    var hasRecentSession: Bool { session?.isRecent == true }

    init(agent: Agent, now: Date = .now, memory: [String: UInt64] = [:]) {
        self.agent = agent
        installed = Self.commandExists(agent.command)
        residentBytes = memory[agent.command]
        // OpenCode guarda las sesiones en SQLite, no en jsonl.
        session = agent == .opencode
            ? LocalSession.openCode(in: agent.sessionDirectory, now: now)
            : LocalSession.latest(in: agent.sessionDirectory, now: now)
    }

    /// El PATH que hereda una app de GUI es mínimo, así que se pregunta al shell de login.
    /// ponytail: se resuelve una vez por lanzamiento (~40 ms); reinicia la app si instalas un CLI nuevo.
    private static let searchPaths: [String] = {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/zsh")
        process.arguments = ["-lc", "printf %s \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let shellPath = (try? { try process.run(); return output.fileHandleForReading.readDataToEndOfFile() }())
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let fallbacks = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                         FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin").path()]
        let env = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return Array(Set((shellPath + ":" + env).split(separator: ":").map(String.init) + fallbacks))
    }()

    private static func commandExists(_ command: String) -> Bool {
        searchPaths.contains { FileManager.default.isExecutableFile(atPath: URL(filePath: $0).appending(path: command).path()) }
    }
}

struct LocalSession {
    let startedAt: Date
    let lastActivity: Date
    let isRecent: Bool
    private static let window: TimeInterval = 5 * 60 * 60

    var ageText: String { lastActivity.formatted(.relative(presentation: .named)) }
    /// Fracción consumida de la ventana de 5 h (0 = recién empezada, 1 = agotada).
    var windowFraction: Double? {
        guard Date.now.timeIntervalSince(startedAt) < Self.window else { return nil }
        return max(0, Date.now.timeIntervalSince(startedAt) / Self.window)
    }
    var remainingText: String? {
        let remaining = Self.window - Date.now.timeIntervalSince(startedAt)
        guard remaining > 0 else { return nil }
        return "Quedan \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))"
    }

    static func selfCheck() -> Bool {
        let now = Date.now
        let fresh = LocalSession(startedAt: now.addingTimeInterval(-60), lastActivity: now, isRecent: true)
        let spent = LocalSession(startedAt: now.addingTimeInterval(-window - 1), lastActivity: now, isRecent: true)
        let almost = LocalSession(startedAt: now.addingTimeInterval(-window * 0.9), lastActivity: now, isRecent: true)
        return fresh.remainingText != nil && spent.remainingText == nil
            && (fresh.windowFraction ?? 1) < 0.8 && (almost.windowFraction ?? 0) > 0.8 && spent.windowFraction == nil
    }

    static func latest(in directory: URL, now: Date = .now) -> LocalSession? {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return nil }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "jsonl" }
        guard let latest = files.max(by: { modificationDate($0) < modificationDate($1) }) else { return nil }
        let modified = modificationDate(latest)
        let start = firstTimestamp(in: latest) ?? modified
        return LocalSession(startedAt: start, lastActivity: modified, isRecent: now.timeIntervalSince(modified) < 15 * 60)
    }

    /// OpenCode no escribe jsonl: la sesión más reciente vive en `opencode.db` (ms desde epoch).
    static func openCode(in directory: URL, now: Date = .now) -> LocalSession? {
        var db: OpaquePointer?
        let path = directory.appending(path: "opencode.db").path()
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        let query = "select time_created, time_updated from session order by time_updated desc limit 1"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let started = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000)
        let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 1)) / 1000)
        return LocalSession(startedAt: started, lastActivity: updated, isRecent: now.timeIntervalSince(updated) < 15 * 60)
    }

    private static func modificationDate(_ file: URL) -> Date {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func firstTimestamp(in file: URL) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: file),
              let data = try? handle.read(upToCount: 32_768),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for line in text.split(separator: "\n") {
            if let event = try? decoder.decode(TimestampEvent.self, from: Data(line.utf8)), let timestamp = event.timestamp {
                return timestamp
            }
        }
        return nil
    }
}

private struct TimestampEvent: Decodable { let timestamp: Date? }
