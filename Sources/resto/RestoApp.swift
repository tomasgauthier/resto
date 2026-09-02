import SwiftUI
import AppKit
import Observation

@main
struct RestoApp: App {
    @State private var monitor = Monitor()

    init() {
        if CommandLine.arguments.contains("--self-test") {
            precondition(LocalSession.selfCheck())
            precondition(MemoryReader.selfCheck())
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            WatcherView(monitor: monitor)
        } label: {
            Image(systemName: monitor.activeCount > 0 ? "timer" : "timer.circle")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class Monitor {
    private(set) var agents: [AgentStatus] = []
    private(set) var usages: [Agent: UsageSnapshot] = [:]
    private(set) var usageErrors: [Agent: String] = [:]
    private(set) var systemMemory: (used: UInt64, total: UInt64)?
    var pebbleVisible = true

    /// Qué filas van en la pebble. Se elige desde el menu bar y sobrevive al reinicio.
    var pebbleAgents: Set<Agent> { didSet { persistPebble() } }
    var pebbleShowsMemory: Bool { didSet { persistPebble() } }

    private var timer: Timer?
    private var lastUsageRefresh = Date.distantPast
    private static let agentsKey = "pebbleAgents"
    private static let memoryKey = "pebbleShowsMemory"

    init() {
        let defaults = UserDefaults.standard
        pebbleAgents = (defaults.array(forKey: Self.agentsKey) as? [String])
            .map { Set($0.compactMap(Agent.named)) } ?? [.claude, .codex]
        pebbleShowsMemory = defaults.object(forKey: Self.memoryKey) as? Bool ?? true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        DispatchQueue.main.async { PebbleController.shared.show(monitor: self) }
    }

    var activeCount: Int { agents.filter(\.hasRecentSession).count }
    /// Nunca menos de una fila: una píldora vacía se ve como un bug.
    var pebbleRowCount: Int { max(1, pebbleAgents.count + (pebbleShowsMemory ? 1 : 0)) }
    var pebbleOrder: [Agent] { Agent.allCases.filter(pebbleAgents.contains) }

    private func persistPebble() {
        UserDefaults.standard.set(pebbleAgents.map(\.command), forKey: Self.agentsKey)
        UserDefaults.standard.set(pebbleShowsMemory, forKey: Self.memoryKey)
        PebbleController.shared.resize(rows: pebbleRowCount)
    }

    func refresh(force: Bool = false) {
        // Escanear los historiales recorre miles de archivos: nunca en el hilo principal.
        // ponytail: rescan completo cada 30 s; cachear por mtime del directorio si algún día pesa.
        Task.detached { [weak self] in
            let memory = MemoryReader.perCommand()
            let scanned = Agent.allCases.map { AgentStatus(agent: $0, memory: memory) }
            let system = MemoryReader.system()
            await MainActor.run {
                self?.agents = scanned
                self?.systemMemory = system
            }
        }
        guard force || Date.now.timeIntervalSince(lastUsageRefresh) > 120 else { return }
        lastUsageRefresh = .now
        Task.detached { [weak self] in
            guard let usage = await CodexUsageReader.read() else {
                await MainActor.run { self?.usageErrors[.codex] = "No respondió `codex app-server`" }
                return
            }
            await MainActor.run {
                self?.usages[.codex] = usage
                self?.usageErrors[.codex] = nil
            }
        }
        Task { [weak self] in
            if let usage = await ClaudeUsageReader.read() {
                self?.usages[.claude] = usage
                self?.usageErrors[.claude] = nil
            } else {
                self?.usageErrors[.claude] = "Abre Claude Code para actualizar la cuota"
            }
        }
        Task { [weak self] in
            switch await KimiUsageReader.read() {
            case .success(let usage):
                self?.usages[.kimi] = usage
                self?.usageErrors[.kimi] = nil
            case .failure(let error): self?.usageErrors[.kimi] = error.message
            }
        }
        usageErrors[.agy] = "Cuota no expuesta por `agy`"
        for agent in [Agent.gemini, .opencode, .copilot] {
            usageErrors[agent] = "Sin cuota real: sólo historial local"
        }
    }
}

private struct WatcherView: View {
    @Bindable var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("resto").font(.title3.weight(.semibold))
                    Text(monitor.activeCount == 0 ? "Sin actividad reciente" : "\(monitor.activeCount) con actividad reciente")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { monitor.refresh(force: true) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).accessibilityLabel("Actualizar")
            }

            if let memory = monitor.systemMemory {
                HStack(spacing: 8) {
                    SystemMemoryLine(used: memory.used, total: memory.total)
                    PebblePin(isOn: $monitor.pebbleShowsMemory, label: "RAM del sistema")
                }
            }

            Text("El alfiler elige qué va en la pebble.")
                .font(.caption2).foregroundStyle(.tertiary)

            // El detalle completo vive acá: la pebble sólo muestra lo que quede alfilerado.
            // Sin ScrollView a propósito: dentro de un MenuBarExtra(.window) mide cero y la
            // lista sale en blanco. Son siete filas fijas, caben.
            VStack(alignment: .leading, spacing: 14) {
                ForEach(monitor.agents) { status in
                    AgentRow(
                        status: status,
                        usage: monitor.usages[status.agent],
                        error: monitor.usageErrors[status.agent],
                        pinned: Binding(
                            get: { monitor.pebbleAgents.contains(status.agent) },
                            set: { if $0 { monitor.pebbleAgents.insert(status.agent) } else { monitor.pebbleAgents.remove(status.agent) } }
                        )
                    )
                }
            }

            Divider()
            Button(monitor.pebbleVisible ? "Ocultar pebble" : "Mostrar pebble") {
                monitor.pebbleVisible.toggle()
                monitor.pebbleVisible ? PebbleController.shared.show(monitor: monitor) : PebbleController.shared.hide()
            }
            .buttonStyle(.borderless)
            Text("La ventana de 5 h es una estimación local salvo donde el proveedor entrega su cuota real.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Salir de resto") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .padding(18)
        .frame(width: 360)
    }
}

private struct PebblePin: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Button { isOn.toggle() } label: {
            Image(systemName: isOn ? "pin.fill" : "pin")
                .font(.caption)
                .foregroundStyle(isOn ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .help(isOn ? "Quitar de la pebble" : "Mostrar en la pebble")
        .accessibilityLabel("\(label) en la pebble")
    }
}

/// La pebble es un titular fijo y arrastrable: el detalle y la configuración están en el menu bar.
private struct PebbleView: View {
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: PebbleController.rowSpacing) {
            ForEach(monitor.pebbleOrder) { agent in
                PebbleUsageLine(agent: agent,
                                usage: monitor.usages[agent],
                                residentBytes: monitor.agents.first { $0.agent == agent }?.residentBytes)
            }
            if let memory = monitor.systemMemory, monitor.pebbleShowsMemory {
                PebbleMemoryLine(used: memory.used, total: memory.total)
            }
            if monitor.pebbleOrder.isEmpty && !monitor.pebbleShowsMemory {
                Text("Nada alfilerado").font(.caption2).foregroundStyle(.tertiary)
                    .frame(height: PebbleController.rowHeight)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, PebbleController.verticalPadding)
        .frame(width: PebbleController.pillWidth, alignment: .leading)
        .background {
            ZStack {
                pill.fill(Color(nsColor: .windowBackgroundColor))
                if let alertTint { pill.fill(alertTint.opacity(0.28)) }
            }
        }
        .overlay(pill.stroke(alertTint?.opacity(0.45) ?? Color(nsColor: .separatorColor), lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
        // La sombra se dibuja dentro de la vista: sin este margen la ventana la recorta en cuadrado.
        .padding(PebbleController.shadowMargin)
        .accessibilityLabel("Cuota restante")
    }

    private var pill: RoundedRectangle { RoundedRectangle(cornerRadius: 20) }

    /// Manda el peor de los alfilerados: si a cualquiera le queda poco, la pebble entera avisa.
    private var alertTint: Color? {
        let remaining = monitor.pebbleOrder
            .compactMap { monitor.usages[$0]?.fiveHour.map { 100 - $0.usedPercent } }.min()
        switch remaining {
        case .some(...10): return .red
        case .some(...25): return .orange
        case .some(...50): return .yellow
        default: return nil
        }
    }
}

@MainActor
private final class PebbleController {
    static let shared = PebbleController()
    static let pillWidth: CGFloat = 240
    static let barWidth: CGFloat = 88
    static let rowHeight: CGFloat = 14
    static let rowSpacing: CGFloat = 5
    static let verticalPadding: CGFloat = 9
    /// Aire transparente alrededor de la píldora para que quepa la sombra sin recortarse.
    static let shadowMargin: CGFloat = 14
    private static let windowWidth = pillWidth + shadowMargin * 2
    static func windowHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowSpacing + verticalPadding * 2 + shadowMargin * 2
    }
    private var panel: NSPanel?

    func show(monitor: Monitor) {
        let height = Self.windowHeight(rows: monitor.pebbleRowCount)
        if let panel {
            panel.contentView = NSHostingView(rootView: PebbleView(monitor: monitor))
            panel.setContentSize(NSSize(width: Self.windowWidth, height: height))
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: height),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.appearance = NSAppearance(named: .aqua)  // la pebble siempre en claro
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // la sombra la dibuja SwiftUI sobre la píldora, no AppKit sobre el marco
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: PebbleView(monitor: monitor))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: screen.visibleFrame.maxX - Self.windowWidth - 8,
                                         y: screen.visibleFrame.minY + 28 - Self.shadowMargin))
        }
        panel.setFrameAutosaveName("pebble")
        // El autosave restaura el alto viejo: la altura la manda siempre el número de filas.
        panel.setFrameUsingName("pebble")
        panel.setContentSize(NSSize(width: Self.windowWidth, height: height))
        self.panel = panel
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func resize(rows: Int) {
        panel?.setContentSize(NSSize(width: Self.windowWidth, height: Self.windowHeight(rows: rows)))
    }
}

private struct AgentRow: View {
    let status: AgentStatus
    let usage: UsageSnapshot?
    let error: String?
    @Binding var pinned: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: status.agent.symbol)
                    .foregroundStyle(status.installed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(status.agent.title).font(.headline)
                Spacer()
                if let bytes = status.residentBytes {
                    Label(MemoryReader.text(bytes), systemImage: "memorychip")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                } else {
                    Text(status.installed ? "Instalado" : "No instalado")
                        .font(.caption.weight(.medium)).foregroundStyle(status.installed ? .secondary : .tertiary)
                }
                PebblePin(isOn: $pinned, label: status.agent.title)
            }
            if let usage {
                if usage.provider != status.agent.title {
                    Text(usage.provider).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
                if let fiveHour = usage.fiveHour { UsageLine(label: "Ventana de 5 h", window: fiveHour) }
                if let weekly = usage.weekly { UsageLine(label: "Semanal", window: weekly) }
            } else if let error, status.installed {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            if let session = status.session {
                HStack(alignment: .lastTextBaseline) {
                    Label("Activo \(session.ageText)", systemImage: "clock")
                    Spacer()
                    if let remaining = session.remainingText {
                        Text(remaining).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if let fraction = session.windowFraction {
                    ProgressView(value: 1 - fraction).tint(fraction > 0.8 ? .orange : .accentColor)
                }
            } else if status.installed {
                Text("Sin historial local reciente").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct SystemMemoryLine: View {
    let used: UInt64
    let total: UInt64

    private var fraction: Double { Double(used) / Double(total) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("RAM del sistema", systemImage: "memorychip")
                Spacer()
                Text("\(Int((fraction * 100).rounded()))% · \(MemoryReader.text(used)) de \(MemoryReader.text(total))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: fraction).tint(fraction > 0.85 ? .orange : .accentColor)
        }
    }
}

private struct UsageLine: View {
    let label: String
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(label): queda \(100 - window.usedPercent)%")
                Spacer()
                Text("reinicia \(window.resetsAt.formatted(date: .omitted, time: .shortened))")
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: Double(100 - window.usedPercent), total: 100).tint(window.usedPercent > 80 ? .orange : .accentColor)
        }
    }
}

/// Muestra el % de la ventana de 5 h; si el proveedor no entrega cuota, cae a la RAM del proceso.
private struct PebbleUsageLine: View {
    let agent: Agent
    let usage: UsageSnapshot?
    let residentBytes: UInt64?

    private var remaining: Int? { usage?.fiveHour.map { 100 - $0.usedPercent } }
    /// Amarillo lo pone el fondo de la pebble; la barra salta el paso para no perderse encima.
    private var barColor: Color {
        switch remaining ?? 100 {
        case ...10: .red
        case ...25: .orange
        default: .blue
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.shortTitle).font(.caption2.weight(.semibold))
                .frame(width: 52, alignment: .leading).lineLimit(1)
            if let remaining {
                // ProgressView pierde el color en un panel que nunca es key: barra propia.
                Capsule().fill(.quaternary).frame(width: PebbleController.barWidth, height: 5)
                    .overlay(alignment: .leading) {
                        Capsule().fill(barColor).frame(width: PebbleController.barWidth * Double(remaining) / 100, height: 5)
                    }
                Spacer(minLength: 0)
                Text("\(remaining)%")
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(remaining <= 25 ? AnyShapeStyle(barColor) : AnyShapeStyle(.secondary))
                    .frame(width: 46, alignment: .trailing)
            } else {
                Text(residentBytes == nil ? "sin cuota" : "en RAM")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(residentBytes.map(MemoryReader.text) ?? "—")
                    .font(.caption2.weight(.medium)).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 46, alignment: .trailing)
            }
        }
        .frame(height: PebbleController.rowHeight)
    }
}

private struct PebbleMemoryLine: View {
    let used: UInt64
    let total: UInt64

    private var fraction: Double { Double(used) / Double(total) }

    var body: some View {
        HStack(spacing: 8) {
            Text("RAM").font(.caption2.weight(.semibold)).frame(width: 52, alignment: .leading)
            Capsule().fill(.quaternary).frame(width: PebbleController.barWidth, height: 5)
                .overlay(alignment: .leading) {
                    Capsule().fill(fraction > 0.85 ? Color.orange : .blue)
                        .frame(width: PebbleController.barWidth * fraction, height: 5)
                }
            Spacer(minLength: 0)
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption2.weight(.medium)).monospacedDigit()
                .foregroundStyle(fraction > 0.85 ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                .frame(width: 46, alignment: .trailing)
        }
        .frame(height: PebbleController.rowHeight)
    }
}
