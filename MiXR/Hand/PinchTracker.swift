import CoreGraphics
import Foundation
import QuartzCore

/// Detecta el **instante exacto** en que la mano pasa de "abierta" a "agarrando", con
/// histéresis y **precisión sub-frame**.
///
/// El problema del "falso retraso" no es el modelo: es *cuándo* se decide. Si la decisión
/// se toma una vez por frame y recién al soltar, el evento siempre llega tarde.
///
/// Acá el cruce del umbral se **interpola linealmente** entre las dos muestras que lo
/// rodean, así se conoce el momento del toque con precisión de milisegundos, aunque la
/// pose venga a 60 Hz (o menos, si Vision pierde un frame).
final class PinchTracker {

    struct Crossing {
        /// Instante interpolado del cruce (no el del frame).
        let time: CFTimeInterval
        /// Punto interpolado donde ocurrió.
        let point: CGPoint
        /// true = empezó el agarre, false = lo soltó.
        let isDown: Bool
        /// Duración del agarre (solo en el cruce de subida).
        let duration: CFTimeInterval
    }

    private struct Sample {
        let value: CGFloat
        let time: CFTimeInterval
        let point: CGPoint
    }

    private var previous: [String: Sample] = [:]
    private var down: [String: Bool] = [:]
    private var downAt: [String: CFTimeInterval] = [:]
    private var downPoint: [String: CGPoint] = [:]

    func reset() {
        previous.removeAll()
        down.removeAll()
        downAt.removeAll()
        downPoint.removeAll()
    }

    func isDown(_ key: String) -> Bool { down[key] ?? false }

    /// Avanza el detector con una muestra nueva. Devuelve el cruce si hubo uno.
    func update(key: String,
                value: CGFloat,
                point: CGPoint,
                time: CFTimeInterval,
                enter: CGFloat,
                exit: CGFloat) -> Crossing? {

        defer { previous[key] = Sample(value: value, time: time, point: point) }

        let holding = down[key] ?? false

        guard let prev = previous[key] else {
            if value >= enter {
                down[key] = true
                downAt[key] = time
                downPoint[key] = point
                return Crossing(time: time, point: point, isDown: true, duration: 0)
            }
            return nil
        }

        let crossed: Bool
        let fraction: CGFloat

        if holding {
            crossed = value <= exit && prev.value > exit
            fraction = crossed ? (prev.value - exit) / max(prev.value - value, 1e-5) : 0
        } else {
            crossed = value >= enter && prev.value < enter
            fraction = crossed ? (enter - prev.value) / max(value - prev.value, 1e-5) : 0
        }

        guard crossed else { return nil }

        let clamped = min(max(fraction, 0), 1)
        let dt = max(time - prev.time, 1e-5)
        let crossTime = prev.time + dt * Double(clamped)
        let crossPoint = CGPoint(x: prev.point.x + (point.x - prev.point.x) * clamped,
                                 y: prev.point.y + (point.y - prev.point.y) * clamped)

        if holding {
            down[key] = false
            let started = downAt[key] ?? crossTime
            downAt[key] = nil
            return Crossing(time: crossTime,
                            point: crossPoint,
                            isDown: false,
                            duration: max(crossTime - started, 0))
        } else {
            down[key] = true
            downAt[key] = crossTime
            downPoint[key] = crossPoint
            return Crossing(time: crossTime, point: crossPoint, isDown: true, duration: 0)
        }
    }
}
