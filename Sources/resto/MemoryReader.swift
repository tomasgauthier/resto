import Foundation

enum MemoryReader {
    /// RSS sumado por comando. Se pregunta a `ps` una sola vez: resolver el ejecutable con
    /// `proc_pidpath` no sirve acá porque los CLIs son bundles de node y todos dirían "node".
    static func perCommand() -> [String: UInt64] {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/ps")
        process.arguments = ["-axo", "rss=,command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Cada línea es `<rss en KiB> <argv0> <resto>`; la llave es el basename de argv0, que es
    /// como se presentan `claude`, `codex` y compañía. Un argv0 con espacios (una .app) parte
    /// en la primera palabra y por eso nunca colisiona con el comando de un CLI.
    static func parse(_ psOutput: String) -> [String: UInt64] {
        var totals: [String: UInt64] = [:]
        for line in psOutput.split(separator: "\n") {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 2, let kib = UInt64(fields[0]) else { continue }
            let name = URL(filePath: String(fields[1])).lastPathComponent
            totals[name, default: 0] += kib * 1024
        }
        return totals
    }

    /// Lo mismo que el Monitor de Actividad llama "memoria usada": activa + reservada + comprimida.
    static func system() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return nil }
        var page: vm_size_t = 0
        host_page_size(mach_host_self(), &page)
        let pageSize = UInt64(page)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        return (used, ProcessInfo.processInfo.physicalMemory)
    }

    static func text(_ bytes: UInt64) -> String {
        Int64(bytes).formatted(.byteCount(style: .memory, allowedUnits: [.mb, .gb], spellsOutZero: false))
    }

    static func selfCheck() -> Bool {
        let sample = """
          3728 /Applications/Claude.app/Contents/Helpers/chrome-native-host chrome-extension://x/
         83040 /Applications/Microsoft Teams.app/Contents/MacOS/Teams --flag
        366768 claude
          1024 claude --resume
         23440 /opt/homebrew/bin/agy
        """
        let totals = parse(sample)
        guard let system = system() else { return false }
        return totals["claude"] == (366_768 + 1024) * 1024
            && totals["agy"] == 23_440 * 1024
            && totals["Claude"] == nil          // la .app de escritorio no se cuela
            && totals["Microsoft"] != nil       // argv0 con espacios parte en la primera palabra
            && system.used > 0 && system.used < system.total
    }
}
