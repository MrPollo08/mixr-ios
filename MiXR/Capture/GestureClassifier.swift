import Foundation
import simd

/// Clasificador de gestos: inferencia del MLP entrenado (53 → 32 → 5).
///
/// Es una multiplicación de matrices de ~1700 productos: corre en microsegundos y se
/// puede evaluar en cada frame, sin CoreML ni dependencias externas.
///
/// Los pesos vienen en `GestureModel.swift`, generado por `tools/train_gestures.py`.
final class GestureClassifier {

    /// Probabilidades suavizadas con una media corta: un frame malo no cambia el gesto.
    private var history: [[Float]] = []
    private let historyLength = 5

    private(set) var lastProbabilities: [Float] = []
    private(set) var lastGesture: GestureLabel = .rest
    private(set) var lastConfidence: Float = 0

    /// Probabilidad de que la mano esté "agarrando" (pinza o puño).
    var grabProbability: Float {
        guard lastProbabilities.count == GestureModel.classCount else { return 0 }
        return lastProbabilities[GestureLabel.pinch.rawValue]
            + lastProbabilities[GestureLabel.fist.rawValue]
    }

    func reset() {
        history.removeAll()
        lastProbabilities = []
        lastGesture = .rest
        lastConfidence = 0
    }

    /// Evalúa una muestra. Devuelve el gesto con más probabilidad (suavizado).
    @discardableResult
    func classify(features: [Float]) -> GestureLabel {
        guard features.count == GestureModel.featureCount else { return lastGesture }

        let probabilities = forward(features)

        history.append(probabilities)
        if history.count > historyLength { history.removeFirst() }

        var averaged = [Float](repeating: 0, count: GestureModel.classCount)
        for row in history {
            for i in 0..<GestureModel.classCount { averaged[i] += row[i] }
        }
        let count = Float(history.count)
        for i in 0..<GestureModel.classCount { averaged[i] /= count }

        var best = 0
        for i in 1..<GestureModel.classCount where averaged[i] > averaged[best] { best = i }
        let clamped = min(max(best, 0), GestureModel.gestureNames.count - 1)

        lastProbabilities = averaged
        lastGesture = GestureModel.gestureNames[clamped]
        lastConfidence = averaged[best]
        return lastGesture
    }

    // MARK: - Forward pass

    private func forward(_ raw: [Float]) -> [Float] {
        let f = GestureModel.featureCount
        let h = GestureModel.hiddenCount
        let k = GestureModel.classCount

        // Normalización
        var x = [Float](repeating: 0, count: f)
        for i in 0..<f {
            x[i] = (raw[i] - GestureModel.mean[i]) / max(GestureModel.std[i], 1e-6)
        }

        // Capa 1: ReLU
        var hidden = [Float](repeating: 0, count: h)
        for j in 0..<h {
            var sum = GestureModel.b1[j]
            for i in 0..<f {
                sum += x[i] * GestureModel.w1[i * h + j]
            }
            hidden[j] = sum > 0 ? sum : 0
        }

        // Capa 2: softmax
        var logits = [Float](repeating: 0, count: k)
        for c in 0..<k {
            var sum = GestureModel.b2[c]
            for j in 0..<h {
                sum += hidden[j] * GestureModel.w2[j * k + c]
            }
            logits[c] = sum
        }

        var maxLogit = logits[0]
        for c in 1..<k { maxLogit = max(maxLogit, logits[c]) }

        var total: Float = 0
        for c in 0..<k {
            logits[c] = expf(logits[c] - maxLogit)
            total += logits[c]
        }
        let divisor = max(total, 1e-6)
        for c in 0..<k { logits[c] /= divisor }

        return logits
    }
}
