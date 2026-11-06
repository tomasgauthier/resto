import SwiftUI
import AppKit
import Observation

@main
struct RestoApp: App {
    @State private var monitor = Monitor()

    init() {
        // Escribirle a un CLI que ya murió da EPIPE, y con la disposición por omisión eso mata
        // la app entera sin dejar reporte de crash. Ignorado, el error vuelve como `write` fallida.
        signal(SIGPIPE, SIG_IGN)
        if CommandLine.arguments.contains("--self-test") {
            precondition(LocalSession.selfCheck())
            precondition(MemoryReader.selfCheck())
            precondition(BatteryReader.selfCheck())
            precondition(PebblePalette.selfCheck())
            precondition(UsageSnapshot.selfCheck())
            precondition(CodexUsageReader.selfCheck())
            precondition(AgyUsageReader.selfCheck())
            precondition(blockingSelfCheck())
            precondition(capturedOutputSelfCheck())
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

/// Corre trabajo que bloquea el hilo (subprocesos, pipes) fuera del pool cooperativo de Swift.
/// El pool tiene un hilo por core: un `docker ps` colgado después de un sueño se los va comiendo
/// tick a tick, y ahí la app se queda con los datos viejos sin volver nunca.
/// ponytail: fuga a lo más un hilo de GCD por lector colgado; `readabilityHandler` si molesta.
func blocking<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(returning: work()) }
    }
}

/// Más lecturas colgadas que cores: si `blocking` corriera en el pool cooperativo, la última
/// tarea no alcanzaría a partir nunca y esto se quedaría esperando.
private func blockingSelfCheck() -> Bool {
    let hung = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    let count = ProcessInfo.processInfo.activeProcessorCount + 2
    for _ in 0..<count {
        Task.detached { _ = await blocking { hung.wait(); return 0 } }
    }
    Task.detached { _ = await blocking { 1 }; done.signal() }
    let ok = done.wait(timeout: .now() + 5) == .success
    for _ in 0..<count { hung.signal() }
    return ok
}

@MainActor
@Observable
final class Monitor {
    private(set) var agents: [AgentStatus] = []
    private(set) var usages: [Agent: UsageSnapshot] = [:]
    private(set) var usageErrors: [Agent: String] = [:]
    private(set) var systemMemory: (used: UInt64, total: UInt64)?
    private(set) var battery: Battery?
    var pebbleVisible = true

    /// Qué filas van en la pebble. Se elige desde el menu bar y sobrevive al reinicio.
    var pebbleAgents: Set<Agent> { didSet { persistPebble() } }
    var pebbleShowsMemory: Bool { didSet { persistPebble() } }
    var pebbleShowsBattery: Bool { didSet { persistPebble() } }

    private var timer: Timer?
    private var lastUsageRefresh = Date.distantPast
    /// Una lectura colgada no debe encolar la siguiente: el tick se salta y ya.
    private var scanning = false
    private var readingCodex = false
    private var readingClaude = false
    private static let agentsKey = "pebbleAgents"
    private static let memoryKey = "pebbleShowsMemory"
    private static let batteryKey = "pebbleShowsBattery"

    init() {
        let defaults = UserDefaults.standard
        pebbleAgents = (defaults.array(forKey: Self.agentsKey) as? [String])
            .map { Set($0.compactMap(Agent.named)) } ?? [.claude, .codex]
        pebbleShowsMemory = defaults.object(forKey: Self.memoryKey) as? Bool ?? true
        pebbleShowsBattery = defaults.object(forKey: Self.batteryKey) as? Bool ?? true
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        DispatchQueue.main.async { PebbleController.shared.show(monitor: self) }
        // Al despertar, la primera pasada cae con la red todavía abajo y las cuotas quedan en
        // error hasta que se cumplan los 120 s. Se reintenta sola cuando ya hay Wi-Fi.
        // 20 s y no 10: el lector de codex se toma hasta 15 s, y si todavía está adentro el
        // reintento se lo salta y esa fila queda en error igual de larga.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self?.refresh(force: true)
            }
        }
    }

    var activeCount: Int { agents.filter(\.hasRecentSession).count }
    /// Nunca menos de una fila: una píldora vacía se ve como un bug.
    var pebbleRowCount: Int {
        max(1, pebbleAgents.count + (pebbleShowsMemory ? 1 : 0) + (pebbleShowsBattery && battery != nil ? 1 : 0))
    }
    var pebbleOrder: [Agent] { Agent.allCases.filter(pebbleAgents.contains) }

    private func persistPebble() {
        UserDefaults.standard.set(pebbleAgents.map(\.command), forKey: Self.agentsKey)
        UserDefaults.standard.set(pebbleShowsMemory, forKey: Self.memoryKey)
        UserDefaults.standard.set(pebbleShowsBattery, forKey: Self.batteryKey)
        PebbleController.shared.resize(rows: pebbleRowCount)
    }

    /// Único punto donde entra una lectura de cuota: fusiona con lo anterior para que una
    /// lectura a medias no borre la ventana que ya se mostraba (ver `UsageSnapshot.merging`).
    private func store(_ usage: UsageSnapshot, for agent: Agent) {
        usages[agent] = usage.merging(over: usages[agent])
        usageErrors[agent] = nil
    }

    /// Una lectura fallida no trae ventanas nuevas, pero las viejas igual vencen: sin podarlas,
    /// una cuota ya reiniciada seguiría en pantalla y taparía el error.
    private func fail(_ message: String, for agent: Agent) {
        usageErrors[agent] = message
        guard let previous = usages[agent] else { return }
        let open = UsageSnapshot(provider: previous.provider, fiveHour: nil, weekly: nil).merging(over: previous)
        usages[agent] = open.fiveHour == nil && open.weekly == nil ? nil : open
    }

    func refresh(force: Bool = false) {
        // Escanear los historiales recorre miles de archivos y `ps` bloquea el hilo: ni el
        // principal ni el pool cooperativo (ver `blocking`).
        // ponytail: rescan completo cada 30 s; cachear por mtime del directorio si algún día pesa.
        if !scanning {
            scanning = true
            Task { [weak self] in
                let memory = await blocking { MemoryReader.perCommand() }
                let scanned = await blocking { Agent.allCases.map { AgentStatus(agent: $0, memory: memory) } }
                let fresh = await blocking { BatteryReader.read() }
                let system = MemoryReader.system()
                guard let self else { return }
                scanning = false
                agents = scanned
                systemMemory = system
                if battery == nil && fresh != nil { PebbleController.shared.resize(rows: pebbleRowCount + 1) }
                battery = fresh
            }
        }
        guard force || Date.now.timeIntervalSince(lastUsageRefresh) > 120 else { return }
        lastUsageRefresh = .now
        if !readingCodex {
            readingCodex = true
            Task { [weak self] in
                let usage = await blocking { CodexUsageReader.read() }
                guard let self else { return }
                readingCodex = false
                guard let usage else {
                    fail("No respondió `codex app-server`", for: .codex)
                    return
                }
                store(usage, for: .codex)
            }
        }
        if !readingClaude {
            readingClaude = true
            Task { [weak self] in
                let usage = await ClaudeUsageReader.read()
                guard let self else { return }
                readingClaude = false
                if let usage {
                    store(usage, for: .claude)
                } else {
                    fail("Abre Claude Code para actualizar la cuota", for: .claude)
                }
            }
        }
        Task { [weak self] in
            switch await KimiUsageReader.read() {
            case .success(let usage):
                self?.store(usage, for: .kimi)
            case .failure(let error): self?.fail(error.message, for: .kimi)
            }
        }
        switch AgyUsageReader.read() {
        case .success(let usage): store(usage, for: .agy)
        case .failure(let error): fail(error.message, for: .agy)
        }
        for agent in [Agent.gemini, .opencode, .copilot] {
            usageErrors[agent] = "Sin cuota real: sólo historial local"
        }
    }
}

private struct WatcherView: View {
    @Bindable var monitor: Monitor
    @State private var showAll = false

    /// Un CLI "con datos" es el que tiene cuota real o sesión local; el resto se pliega para
    /// que el panel no crezca con siete filas que no dicen nada.
    private var withData: [AgentStatus] {
        monitor.agents.filter { $0.installed && (monitor.usages[$0.agent] != nil || $0.session != nil) }
    }
    private var withoutData: [AgentStatus] {
        monitor.agents.filter { !($0.installed && (monitor.usages[$0.agent] != nil || $0.session != nil)) }
    }

    private func row(_ status: AgentStatus) -> some View {
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
            if let battery = monitor.battery {
                HStack(spacing: 8) {
                    BatteryLine(battery: battery)
                    PebblePin(isOn: $monitor.pebbleShowsBattery, label: "Batería")
                }
            }

            Text("El alfiler elige qué va en la pebble.")
                .font(.caption2).foregroundStyle(.tertiary)

            // El detalle completo vive acá: la pebble sólo muestra lo que quede alfilerado.
            // Sin ScrollView a propósito: dentro de un MenuBarExtra(.window) mide cero y la
            // lista sale en blanco. Son siete filas fijas, caben.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(withData) { status in row(status) }
            }
            if !withoutData.isEmpty {
                DisclosureGroup(isExpanded: $showAll) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(withoutData) { status in row(status) }
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Mostrar \(withoutData.count) sin datos")
                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
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
        // El panel de MenuBarExtra viene con vibrancy: sobre un fondo blanco el texto se
        // lava. Un color opaco encima la tapa y deja el panel legible sobre lo que sea.
        .background(Color(nsColor: .windowBackgroundColor))
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

/// La gota es un titular fijo pegado al borde: el detalle y la configuración están en el menu bar.
private struct PebbleView: View {
    let monitor: Monitor
    @State private var dragStart: (mouse: CGFloat, origin: CGFloat)?

    private var gauges: [PebbleGauge] {
        var all = monitor.pebbleOrder.map { agent in
            let usage = monitor.usages[agent]
            return PebbleGauge.quota(agent: agent,
                                     fiveHourLeft: usage?.fiveHour.map { 100 - $0.usedPercent },
                                     weeklyLeft: usage?.weekly.map { 100 - $0.usedPercent })
        }
        if let memory = monitor.systemMemory, monitor.pebbleShowsMemory {
            all.append(.memory(used: Double(memory.used) / Double(memory.total)))
        }
        if let battery = monitor.battery, monitor.pebbleShowsBattery { all.append(.battery(battery)) }
        return all
    }

    var body: some View {
        VStack(spacing: PebbleController.rowSpacing) {
            ForEach(Array(gauges.enumerated()), id: \.offset) { _, gauge in PebbleRing(gauge: gauge) }
            if gauges.isEmpty {
                Image(systemName: "pin.slash").font(.caption).foregroundStyle(PebblePalette.dim.color)
                    .frame(height: PebbleController.rowHeight).help("Nada alfilerado")
            }
        }
        .padding(.vertical, PebbleController.verticalPadding)
        .frame(width: PebbleController.pillWidth)
        .background(drop.fill(PebblePalette.ground.color))
        .overlay(drop.stroke(.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        // La sombra se dibuja dentro de la vista: sin este margen la ventana la recorta en cuadrado.
        .padding(PebbleController.shadowMargin)
        // Sólo en vertical: el borde derecho es su lugar. Se sigue al mouse en pantalla y no a
        // la traslación del gesto, que se mide contra una ventana que se está moviendo.
        .gesture(DragGesture(minimumDistance: 1)
            .onChanged { _ in
                let mouse = NSEvent.mouseLocation.y
                let start = dragStart ?? (mouse, PebbleController.shared.originY)
                dragStart = start
                PebbleController.shared.dock(y: start.origin + mouse - start.mouse)
            }
            .onEnded { _ in dragStart = nil })
    }

    /// Recta del lado de la pantalla, redonda hacia adentro: una gota que cuelga del borde.
    private var drop: UnevenRoundedRectangle {
        let r = PebbleController.pillWidth / 2
        return UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r,
                                      bottomTrailingRadius: 0, topTrailingRadius: 0)
    }
}

/// El medidor del iPhone: número arriba, ícono al centro, arco partido a los costados y la
/// cuota semanal en puntos abajo. El arco se llena desde abajo, sube por la izquierda y baja
/// por la derecha.
private struct PebbleRing: View {
    let gauge: PebbleGauge
    static let diameter: CGFloat = 34 * PebbleController.scale
    private static let line: CGFloat = 3.5 * PebbleController.scale
    /// Medio hueco arriba y abajo, en fracción de vuelta: el lugar del número y de los puntos.
    private static let gap = 0.11

    var body: some View {
        let half = 0.5 - 2 * Self.gap
        let filled = max(0, min(1, gauge.fraction)) * 2 * half
        ZStack {
            segment(from: Self.gap, length: half, [PebblePalette.track])
            segment(from: 0.5 + Self.gap, length: half, [PebblePalette.track])
            if filled > 0 { segment(from: Self.gap, length: min(filled, half), gauge.arc) }
            if filled > half { segment(from: 0.5 + Self.gap, length: filled - half, gauge.arc) }
            Image(systemName: gauge.symbol)
                .font(.system(size: 11 * PebbleController.scale, weight: .semibold))
                .foregroundStyle(PebblePalette.label.color)
            Text(gauge.text)
                .font(.system(size: 10 * PebbleController.scale, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(gauge.ink.color)
                .offset(y: -Self.diameter / 2)
            if let dots = gauge.dots {
                HStack(spacing: 2 * PebbleController.scale) {
                    ForEach(0..<4, id: \.self) { i in
                        Circle().fill((i < dots ? PebblePalette.label : PebblePalette.track).color)
                            .frame(width: 3 * PebbleController.scale, height: 3 * PebbleController.scale)
                    }
                }
                .offset(y: Self.diameter / 2)
            }
        }
        .frame(width: Self.diameter + Self.line, height: PebbleController.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(gauge.accessibility)
    }

    /// El trim de un círculo parte a las 3 en punto; rotado 90° parte abajo.
    /// Con varios colores el degradado da la vuelta completa al círculo, así cada tramo lleno
    /// muestra la parte del arcoíris que le toca; se cierra con el primero para no dejar costura.
    private func segment(from start: Double, length: Double, _ inks: [PebblePalette.RGB]) -> some View {
        let colors = inks.map(\.color)
        return Circle().trim(from: start, to: start + length)
            .rotation(.degrees(90))
            .stroke(AngularGradient(colors: colors.count > 1 ? colors + [colors[0]] : colors + colors, center: .center),
                    style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
            .frame(width: Self.diameter, height: Self.diameter)
    }
}

@MainActor
private final class PebbleController {
    static let shared = PebbleController()
    /// La perilla del tamaño: todo lo que mide la gota se multiplica por esto.
    static let scale: CGFloat = 0.85
    static let pillWidth: CGFloat = 52 * scale
    /// Un anillo con su número arriba y sus puntos abajo.
    static let rowHeight: CGFloat = PebbleRing.diameter + 12 * scale
    static let rowSpacing: CGFloat = 4 * scale
    static let verticalPadding: CGFloat = 10 * scale
    /// Aire transparente alrededor de la gota para que quepa la sombra sin recortarse.
    static let shadowMargin: CGFloat = 14
    private static let windowWidth = pillWidth + shadowMargin * 2
    static func windowHeight(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(0, rows - 1)) * rowSpacing + verticalPadding * 2 + shadowMargin * 2
    }
    private var panel: NSPanel?

    var originY: CGFloat { panel?.frame.minY ?? 0 }

    func show(monitor: Monitor) {
        let height = Self.windowHeight(rows: monitor.pebbleRowCount)
        if let panel {
            panel.contentView = NSHostingView(rootView: PebbleView(monitor: monitor))
            panel.setContentSize(NSSize(width: Self.windowWidth, height: height))
            dock()
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
        panel.appearance = NSAppearance(named: .darkAqua)  // la gota siempre en oscuro
        panel.isMovableByWindowBackground = false  // el arrastre lo maneja la vista, sólo en vertical
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // la sombra la dibuja SwiftUI sobre la gota, no AppKit sobre el marco
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: PebbleView(monitor: monitor))
        if let screen = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: 0, y: screen.visibleFrame.midY - height / 2))
        }
        // El autosave guarda la altura elegida; el ancho y la x los manda siempre el borde.
        panel.setFrameAutosaveName("pebble")
        panel.setFrameUsingName("pebble")
        panel.setContentSize(NSSize(width: Self.windowWidth, height: height))
        self.panel = panel
        dock()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { _ in Task { @MainActor in PebbleController.shared.dock() } }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    func resize(rows: Int) {
        panel?.setContentSize(NSSize(width: Self.windowWidth, height: Self.windowHeight(rows: rows)))
        dock()
    }

    /// Pega la gota al borde derecho de su pantalla, a la altura pedida y sin salirse de ella.
    /// La sombra puede quedar fuera de la pantalla; la gota no.
    func dock(y: CGFloat? = nil) {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let lowest = visible.minY - Self.shadowMargin
        let highest = visible.maxY - panel.frame.height + Self.shadowMargin
        let wanted = y ?? panel.frame.minY
        panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.pillWidth - Self.shadowMargin,
                                     y: max(lowest, min(highest, wanted))))
    }
}

private struct AgentRow: View {
    let status: AgentStatus
    let usage: UsageSnapshot?
    let error: String?
    @Binding var pinned: Bool
    @State private var expanded = false

    /// Lo único que se ve plegado: el número con el que uno decide si sigue o para.
    private var headline: Text {
        if let remaining = usage?.fiveHour.map({ 100 - $0.usedPercent }) {
            return Text("queda \(remaining)%")
        }
        if let bytes = status.residentBytes { return Text(MemoryReader.text(bytes)) }
        return Text(status.installed ? "Instalado" : "No instalado")
    }

    private var hasDetail: Bool {
        usage != nil || status.session != nil || (error != nil && status.installed)
    }

    var body: some View {
        if hasDetail {
            DisclosureGroup(isExpanded: $expanded) { detail } label: { header }
        } else {
            header
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: status.agent.symbol)
                .foregroundStyle(status.installed ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text(status.agent.title).font(.headline)
            Spacer()
            headline
                .font(.caption.weight(.medium)).monospacedDigit()
                .foregroundStyle(status.installed ? .secondary : .tertiary)
            PebblePin(isOn: $pinned, label: status.agent.title)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 7) {
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
            }
        }
        .padding(.top, 6).padding(.leading, 4)
    }
}

/// Los colores de las barras que no son cuota: si todo fuera azul, un 90% de RAM se leería
/// como "te queda 90%", que es justo lo contrario.
enum RestoBar {
    static func memory(_ fraction: Double) -> Color { fraction > 0.85 ? .orange : .purple }

    static func battery(_ battery: Battery) -> Color {
        if battery.isCharging || battery.isPlugged { return .green }
        switch battery.percent {
        case ...10: return .red
        case ...20: return .orange
        default: return .green
        }
    }
}

private struct BatteryLine: View {
    let battery: Battery

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("Batería \(battery.percent)% · \(battery.stateText)",
                      systemImage: battery.isPlugged ? "battery.100.bolt" : "battery.50")
                Spacer()
                if let time = battery.timeText { Text(time) }
            }
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            ProgressView(value: Double(battery.percent), total: 100).tint(RestoBar.battery(battery))
            if let health = battery.healthText {
                Text(health).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
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
            ProgressView(value: fraction).tint(RestoBar.memory(fraction))
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
