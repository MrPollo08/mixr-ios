import CoreGraphics
import Foundation
import QuartzCore
import simd

/// Implementación matemática exacta del filtro adaptativo **One-Euro (1€)**
/// (Casiez, Roussel, Vogel — CHI 2012) para señales 1D, 2D, 3D (`simd_float3`)
/// y rotaciones (`simd_quatf`).
///
/// - A baja velocidad: `cutoff ≈ minCutoff` → filtra fuerte el jitter de Vision/LiDAR.
/// - A alta velocidad: `cutoff = minCutoff + beta * |dx/dt|` → elimina la latencia.
struct OneEuroFilter1D {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float

    private var xPrev: Float?
    private var dxPrev: Float = 0
    private var tPrev: CFTimeInterval?

    init(minCutoff: Float = 1.2, beta: Float = 0.04, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func reset() {
        xPrev = nil
        dxPrev = 0
        tPrev = nil
    }

    mutating func filter(_ x: Float, timestamp: CFTimeInterval = CACurrentMediaTime()) -> Float {
        guard x.isFinite else { return xPrev ?? 0 }
        guard let prevX = xPrev, let prevT = tPrev else {
            xPrev = x
            dxPrev = 0
            tPrev = timestamp
            return x
        }

        let rawDt = Float(timestamp - prevT)
        let dt = (rawDt > 0.0005 && rawDt < 0.5) ? rawDt : (1.0 / 60.0)
        tPrev = timestamp

        let dx = (x - prevX) / dt
        let aD = Self.smoothingFactor(dt: dt, cutoff: dCutoff)
        let edx = aD * dx + (1.0 - aD) * dxPrev
        dxPrev = edx

        let cutoff = minCutoff + beta * abs(edx)
        let aX = Self.smoothingFactor(dt: dt, cutoff: cutoff)
        let filtered = aX * x + (1.0 - aX) * prevX
        xPrev = filtered
        return filtered
    }

    static func smoothingFactor(dt: Float, cutoff: Float) -> Float {
        let r = 2.0 * Float.pi * max(cutoff, 0.001) * max(dt, 0.0001)
        return r / (r + 1.0)
    }
}

/// Filtro One-Euro acoplado en 2D (`CGPoint`): usa la magnitud escalar de la
/// velocidad 2D para que X e Y compartan la misma frecuencia de corte y no se
/// deformen las trayectorias diagonales.
struct OneEuroFilter2D {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float

    private var pPrev: SIMD2<Float>?
    private var vPrev: SIMD2<Float> = .zero
    private var tPrev: CFTimeInterval?

    init(minCutoff: Float = 1.35, beta: Float = 0.018, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func reset() {
        pPrev = nil
        vPrev = .zero
        tPrev = nil
    }

    mutating func filter(_ point: CGPoint, timestamp: CFTimeInterval = CACurrentMediaTime()) -> CGPoint {
        let p = SIMD2<Float>(Float(point.x), Float(point.y))
        guard p.x.isFinite, p.y.isFinite else {
            if let prev = pPrev { return CGPoint(x: CGFloat(prev.x), y: CGFloat(prev.y)) }
            return .zero
        }
        guard let prevP = pPrev, let prevT = tPrev else {
            pPrev = p
            vPrev = .zero
            tPrev = timestamp
            return point
        }

        let rawDt = Float(timestamp - prevT)
        let dt = (rawDt > 0.0005 && rawDt < 0.5) ? rawDt : (1.0 / 60.0)
        tPrev = timestamp

        let v = (p - prevP) / dt
        let aD = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: dCutoff)
        let ev = vPrev + (v - vPrev) * aD
        vPrev = ev

        let speed = simd_length(ev)
        let cutoff = minCutoff + beta * speed
        let aX = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: cutoff)
        let filtered = prevP + (p - prevP) * aX
        pPrev = filtered
        return CGPoint(x: CGFloat(filtered.x), y: CGFloat(filtered.y))
    }
}

/// Filtro One-Euro 3D (`simd_float3`) diseñado para articular las 21 coordenadas
/// de Vision + LiDAR en espacio métrico (metros).
///
/// Separa la frecuencia de corte transversal (XY) de la longitudinal (Z LiDAR)
/// para absorber el ruido del sensor ToF sin introducir lag al acercar/alejar la mano.
struct OneEuroFilter3D {
    var minCutoffXY: Float
    var betaXY: Float
    var minCutoffZ: Float
    var betaZ: Float
    var dCutoff: Float

    private var pPrev: simd_float3?
    private var vPrev: simd_float3 = .zero
    private var tPrev: CFTimeInterval?

    init(minCutoffXY: Float = 1.45,
         betaXY: Float = 1.85,
         minCutoffZ: Float = 1.10,
         betaZ: Float = 1.35,
         dCutoff: Float = 1.0) {
        self.minCutoffXY = minCutoffXY
        self.betaXY = betaXY
        self.minCutoffZ = minCutoffZ
        self.betaZ = betaZ
        self.dCutoff = dCutoff
    }

    mutating func reset() {
        pPrev = nil
        vPrev = .zero
        tPrev = nil
    }

    mutating func filter(_ point: simd_float3, timestamp: CFTimeInterval = CACurrentMediaTime()) -> simd_float3 {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else {
            return pPrev ?? .zero
        }
        guard let prevP = pPrev, let prevT = tPrev else {
            pPrev = point
            vPrev = .zero
            tPrev = timestamp
            return point
        }

        let rawDt = Float(timestamp - prevT)
        let dt = (rawDt > 0.0005 && rawDt < 0.5) ? rawDt : (1.0 / 60.0)
        tPrev = timestamp

        let v = (point - prevP) / dt
        let aD = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: dCutoff)
        let ev = vPrev + (v - vPrev) * aD
        vPrev = ev

        let speedXY = hypot(ev.x, ev.y)
        let cutoffXY = minCutoffXY + betaXY * speedXY
        let aXY = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: cutoffXY)

        let speedZ = abs(ev.z)
        let cutoffZ = minCutoffZ + betaZ * speedZ
        let aZ = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: cutoffZ)

        let fx = prevP.x + (point.x - prevP.x) * aXY
        let fy = prevP.y + (point.y - prevP.y) * aXY
        let fz = prevP.z + (point.z - prevP.z) * aZ
        let filtered = simd_float3(fx, fy, fz)
        pPrev = filtered
        return filtered
    }
}

/// Filtro One-Euro sobre cuaterniones (`simd_quatf`) usando Slerp y velocidad angular.
struct OneEuroFilterQuat {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float

    private var qPrev: simd_quatf?
    private var omegaPrev: Float = 0
    private var tPrev: CFTimeInterval?

    init(minCutoff: Float = 1.6, beta: Float = 0.35, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func reset() {
        qPrev = nil
        omegaPrev = 0
        tPrev = nil
    }

    mutating func filter(_ qRaw: simd_quatf, timestamp: CFTimeInterval = CACurrentMediaTime()) -> simd_quatf {
        let q = simd_normalize(qRaw)
        guard q.vector.x.isFinite, q.vector.y.isFinite, q.vector.z.isFinite, q.vector.w.isFinite else {
            return qPrev ?? simd_quatf(angle: 0, axis: simd_float3(0, 1, 0))
        }
        guard let prevQ = qPrev, let prevT = tPrev else {
            qPrev = q
            omegaPrev = 0
            tPrev = timestamp
            return q
        }

        let rawDt = Float(timestamp - prevT)
        let dt = (rawDt > 0.0005 && rawDt < 0.5) ? rawDt : (1.0 / 60.0)
        tPrev = timestamp

        // Asegurar el camino corto en S^3.
        let aligned = simd_dot(prevQ.vector, q.vector) < 0 ? simd_quatf(vector: -q.vector) : q
        let dotVal = min(max(abs(simd_dot(prevQ.vector, aligned.vector)), -1.0), 1.0)
        let angle = 2.0 * acos(dotVal)
        let omega = angle / dt

        let aD = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: dCutoff)
        let eOmega = aD * omega + (1.0 - aD) * omegaPrev
        omegaPrev = eOmega

        let cutoff = minCutoff + beta * eOmega
        let alpha = OneEuroFilter1D.smoothingFactor(dt: dt, cutoff: cutoff)
        let filtered = simd_normalize(simd_slerp(prevQ, aligned, alpha))
        qPrev = filtered
        return filtered
    }
}
