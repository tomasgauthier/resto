import SwiftUI

/// Un anillo de la gota, ya decidido: la vista sólo lo dibuja. Separado de la vista para que
/// `selfCheck` pueda probar qué número, qué arco y cuántos puntos sale de cada lectura.
struct PebbleGauge {
    let symbol: String
    /// Lo que dice el número; `nil` cuando no hay dato y no se inventa uno.
    let value: Int?
    /// Cuánto del arco va lleno, 0…1.
    let fraction: Double
    let ink: PebblePalette.RGB
    /// Puntos encendidos de 4; `nil` = el anillo no lleva puntos.
    let dots: Int?
    let accessibility: String

    var text: String { value.map(String.init) ?? "—" }

    static func quota(agent: Agent, fiveHourLeft: Int?, weeklyLeft: Int?) -> PebbleGauge {
        let symbol = switch agent {
        case .claude: "asterisk"
        case .codex: "hexagon"
        case .kimi: "moon"
        case .agy: "sparkle"
        default: "terminal"
        }
        guard let left = fiveHourLeft else {
            return PebbleGauge(symbol: symbol, value: nil, fraction: 0, ink: PebblePalette.dim, dots: nil,
                               accessibility: "\(agent.shortTitle): sin cuota")
        }
        // Hacia arriba: un 3% semanal todavía es algo, y un punto apagado diría que no queda nada.
        let dots = weeklyLeft.map { Int((Double(max(0, min(100, $0))) / 25).rounded(.up)) }
        let week = weeklyLeft.map { ", semana \($0)%" } ?? ""
        return PebbleGauge(symbol: symbol, value: left, fraction: Double(left) / 100,
                           ink: PebblePalette.Severity.remaining(left).ink, dots: dots,
                           accessibility: "\(agent.shortTitle): queda \(left)%\(week)")
    }

    /// Ojo: la RAM cuenta lo USADO, al revés que las cuotas; por eso va en otro color.
    static func memory(used fraction: Double) -> PebbleGauge {
        let percent = Int((fraction * 100).rounded())
        return PebbleGauge(symbol: "memorychip", value: percent, fraction: fraction,
                           ink: PebblePalette.memory(fraction), dots: nil, accessibility: "RAM usada \(percent)%")
    }

    static func battery(_ battery: Battery) -> PebbleGauge {
        PebbleGauge(symbol: battery.isCharging ? "bolt.fill" : "battery.75", value: battery.percent,
                    fraction: Double(battery.percent) / 100, ink: PebblePalette.battery(battery), dots: nil,
                    accessibility: "Batería \(battery.percent)%")
    }
}

/// La gota está fijada en oscuro, así que sus colores no dependen del tema y se pueden
/// verificar de verdad: `selfCheck` mide cada tinta contra el fondo. Las tintas son también
/// el color del número, así que piden el piso de texto (4.5:1), no el de gráficos (3:1).
enum PebblePalette {
    struct RGB: Equatable {
        let r, g, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }

        /// Luminancia relativa según WCAG 2.1.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    // ── superficie ───────────────────────────────────────────────────────
    /// Casi negro con un sesgo azul mínimo, como la cápsula de dictado de macOS.
    static let ground = RGB(r: 0.11, g: 0.11, b: 0.12)
    /// El canal vacío del arco: tiene que verse dónde termina lo lleno.
    static let track = RGB(r: 0.30, g: 0.30, b: 0.32)
    static let label = RGB(r: 0.95, g: 0.95, b: 0.97)
    /// Lo que no tiene dato: gris, pero legible.
    static let dim = RGB(r: 0.62, g: 0.62, b: 0.65)

    // ── severidad ────────────────────────────────────────────────────────
    /// Cada anillo avisa por sí solo: la gota ya no se tiñe entera, que con cuatro anillos
    /// no se sabía cuál era el que estaba bajo.
    enum Severity: CaseIterable {
        case calm, low, warning, critical

        /// Recibe lo que QUEDA, no lo consumido.
        static func remaining(_ percent: Int) -> Severity {
            switch percent {
            case ...10: .critical
            case ...20: .warning
            case ...35: .low
            default: .calm
            }
        }

        var ink: RGB {
            switch self {
            case .calm: label
            case .low: RGB(r: 1, g: 0.84, b: 0.04)
            case .warning: RGB(r: 1, g: 0.62, b: 0.04)
            case .critical: RGB(r: 1, g: 0.27, b: 0.23)
            }
        }
    }

    // ── métricas que no son cuota ────────────────────────────────────────
    static let memoryInk = RGB(r: 0.75, g: 0.55, b: 1)
    static let batteryInk = RGB(r: 0.19, g: 0.82, b: 0.35)

    static func memory(_ fraction: Double) -> RGB { fraction > 0.85 ? Severity.warning.ink : memoryInk }
    static func battery(_ battery: Battery) -> RGB {
        if battery.isCharging || battery.isPlugged { return batteryInk }
        switch battery.percent {
        case ...10: return Severity.critical.ink
        case ...20: return Severity.warning.ink
        default: return batteryInk
        }
    }

    static func selfCheck() -> Bool {
        guard Severity.remaining(100) == .calm, Severity.remaining(36) == .calm,
              Severity.remaining(35) == .low, Severity.remaining(21) == .low,
              Severity.remaining(20) == .warning, Severity.remaining(11) == .warning,
              Severity.remaining(10) == .critical, Severity.remaining(0) == .critical else { return false }

        // C1: 50% en 5 h y 50% en la semana → "50", arco a la mitad, 2 de 4 puntos.
        let half = PebbleGauge.quota(agent: .claude, fiveHourLeft: 50, weeklyLeft: 50)
        guard half.value == 50, half.fraction == 0.5, half.dots == 2, half.ink == Severity.calm.ink else { return false }
        // Los puntos redondean hacia arriba: cualquier resto se ve.
        let dots = [0: 0, 1: 1, 25: 1, 26: 2, 51: 3, 100: 4]
        for (left, lit) in dots {
            guard PebbleGauge.quota(agent: .claude, fiveHourLeft: 90, weeklyLeft: left).dots == lit else { return false }
        }
        // C2: el anillo toma el color de su propia severidad.
        guard PebbleGauge.quota(agent: .codex, fiveHourLeft: 16, weeklyLeft: nil).ink == Severity.warning.ink,
              PebbleGauge.quota(agent: .codex, fiveHourLeft: 16, weeklyLeft: nil).dots == nil else { return false }
        // C3: sin cuota no se inventa un número.
        let none = PebbleGauge.quota(agent: .agy, fiveHourLeft: nil, weeklyLeft: nil)
        guard none.value == nil, none.fraction == 0, none.dots == nil, none.text == "—", none.ink == dim else { return false }
        // La RAM muestra lo usado, en morado, sin puntos.
        let ram = PebbleGauge.memory(used: 0.71)
        guard ram.value == 71, ram.ink == memoryInk, ram.dots == nil else { return false }

        // C5: todo lo que se dibuja sobre la gota oscura se lee.
        let inks = Severity.allCases.map(\.ink) + [memoryInk, batteryInk]
        for ink in inks {
            guard contrast(ink, ground) >= 4.5 else { return false }    // es también el color del número
            guard contrast(track, ink) >= 2 else { return false }       // arco lleno vs. canal vacío
        }
        guard contrast(track, ground) >= 1.4, contrast(label, ground) >= 4.5, contrast(dim, ground) >= 4.5 else { return false }
        return true
    }
}
