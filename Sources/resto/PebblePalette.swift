import SwiftUI

/// La pebble está fijada en apariencia clara, así que sus colores no dependen del tema y se
/// pueden verificar de verdad: `selfCheck` compone cada fondo teñido y mide el contraste de
/// la barra contra él. El piso es 3:1, que es lo que WCAG pide para gráficos no textuales.
enum PebblePalette {
    struct RGB: Equatable {
        let r, g, b: Double
        var color: Color { Color(red: r, green: g, blue: b) }

        /// Luminancia relativa según WCAG 2.1.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        func blended(_ other: RGB, alpha: Double) -> RGB {
            RGB(r: r * (1 - alpha) + other.r * alpha,
                g: g * (1 - alpha) + other.g * alpha,
                b: b * (1 - alpha) + other.b * alpha)
        }
    }

    static func contrast(_ a: RGB, _ b: RGB) -> Double {
        let (hi, lo) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (hi + 0.05) / (lo + 0.05)
    }

    // ── superficie ───────────────────────────────────────────────────────
    /// Blanco roto con un sesgo azul mínimo: un gris puro se ve sin decidir.
    static let ground = RGB(r: 0.937, g: 0.937, b: 0.949)
    /// El canal vacío de la barra. Va sólido y más oscuro que cualquier tinte, para que se
    /// siga viendo dónde termina la barra cuando la píldora se tiñe.
    static let track = RGB(r: 0.66, g: 0.66, b: 0.675)
    static let label = RGB(r: 0.16, g: 0.16, b: 0.20)
    static let tintAlpha = 0.26

    // ── severidad: un solo umbral para la píldora y para la barra ────────
    /// Antes la píldora avisaba a los 50% y la barra a los 25%: se contradecían, y en los
    /// tramos que importan la barra terminaba del mismo color que el fondo.
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

        /// El lavado de la píldora entera. `nil` mientras no hay nada que avisar.
        var tint: RGB? {
            switch self {
            case .calm: nil
            case .low: RGB(r: 1, g: 0.86, b: 0)
            case .warning: RGB(r: 1, g: 0.58, b: 0)
            case .critical: RGB(r: 1, g: 0.23, b: 0.19)
            }
        }

        /// La tinta de la barra: oscura, para leerse sobre el lavado de su propio color.
        var ink: RGB {
            switch self {
            case .calm: RGB(r: 0.11, g: 0.31, b: 0.85)
            case .low: RGB(r: 0.60, g: 0.38, b: 0)
            case .warning: RGB(r: 0.64, g: 0.23, b: 0)
            case .critical: RGB(r: 0.55, g: 0.06, b: 0.08)
            }
        }

        /// El fondo real que le toca a esta barra, ya compuesto.
        var background: RGB { tint.map { ground.blended($0, alpha: tintAlpha) } ?? ground }
    }

    // ── métricas que no son cuota ────────────────────────────────────────
    static let memoryInk = RGB(r: 0.36, g: 0.13, b: 0.71)
    static let batteryInk = RGB(r: 0.08, g: 0.38, b: 0.18)

    static func memory(_ fraction: Double) -> RGB { fraction > 0.85 ? Severity.warning.ink : memoryInk }
    static func battery(_ battery: Battery) -> RGB {
        if battery.isCharging || battery.isPlugged { return batteryInk }
        switch battery.percent {
        case ...10: return Severity.critical.ink
        case ...20: return Severity.warning.ink
        default: return batteryInk
        }
    }

    /// El peor de los alfilerados manda el tinte de la píldora entera.
    static func tint(worstRemaining: Int?) -> RGB? {
        worstRemaining.flatMap { Severity.remaining($0).tint }
    }

    static func selfCheck() -> Bool {
        guard Severity.remaining(100) == .calm, Severity.remaining(36) == .calm,
              Severity.remaining(35) == .low, Severity.remaining(21) == .low,
              Severity.remaining(20) == .warning, Severity.remaining(11) == .warning,
              Severity.remaining(10) == .critical, Severity.remaining(0) == .critical else { return false }
        // Ninguna barra puede perderse en el fondo que ella misma provoca.
        for severity in Severity.allCases {
            let fondo = severity.background
            guard contrast(severity.ink, fondo) >= 3 else { return false }
            // La RAM y la batería conviven con el tinte de las cuotas, no con el suyo.
            guard contrast(memoryInk, fondo) >= 3, contrast(batteryInk, fondo) >= 3 else { return false }
            // El canal vacío tiene que distinguirse del fondo y de la barra llena.
            guard contrast(track, fondo) >= 1.4, contrast(track, severity.ink) >= 2 else { return false }
            guard contrast(label, fondo) >= 4.5 else { return false }   // texto: piso de texto
        }
        return true
    }
}
