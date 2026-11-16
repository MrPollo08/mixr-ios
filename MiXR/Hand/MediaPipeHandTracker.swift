import CoreGraphics
import CoreVideo
import Foundation
import MediaPipeTasksVision
import Vision
import UIKit

/// Mano detectada por MediaPipe, con los 21 puntos en coordenadas **normalizadas**
/// (origen abajo-izquierda, como las usa el resto del pipeline).
struct MediaPipeHand {
    let key: String
    /// 21 puntos en 0…1, origen abajo-izquierda.
    let points: [VNHumanHandPoseObservation.JointName: CGPoint]
    /// > 0 si la palma mira a la cámara (corregido por lateralidad).
    let chiralitySign: Float
}

/// Detector de manos con **MediaPipe HandLandmarker** (LiteRT).
///
/// Es el mismo tipo de modelo que usa la app de referencia: entrenado específicamente
/// en manos, con 21 puntos estables incluso en puño. Corre en la GPU del dispositivo.
final class MediaPipeHandTracker {

    /// Orden canónico de los 21 landmarks de MediaPipe.
    static let jointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    private var landmarker: HandLandmarker?
    private var lastTimestampMs = 0

    var isReady: Bool { landmarker != nil }

    init() {
        guard let path = Bundle.main.path(forResource: "hand_landmarker", ofType: "task") else {
            return
        }

        let options = HandLandmarkerOptions()
        options.baseOptions.modelAssetPath = path
        options.runningMode = .video
        options.numHands = 2
        // Umbrales bajos a propósito: en cuartos oscuros conviene detectar y después
        // filtrar, en vez de perder la mano por confianza.
        options.minHandDetectionConfidence = 0.30
        options.minHandPresenceConfidence = 0.30
        options.minTrackingConfidence = 0.30
        options.baseOptions.delegate = .GPU

        landmarker = try? HandLandmarker(options: options)
    }

    /// Devuelve hasta 2 manos. `nil` significa "no pude correr el modelo" (el llamador
    /// debe caer a Vision); un array vacío significa "corrió bien y no hay manos".
    func detect(pixelBuffer: CVPixelBuffer,
                timestamp: CFTimeInterval,
                orientation: CGImagePropertyOrientation) -> [MediaPipeHand]? {
       guard let landmarker else { return nil }

        var timestampMs = Int(timestamp * 1000)
        if timestampMs <= lastTimestampMs { timestampMs = lastTimestampMs + 1 }
        lastTimestampMs = timestampMs

        let uiOrientation: UIImage.Orientation
        switch orientation {
        case .down: uiOrientation = .down
        case .left: uiOrientation = .left
        case .right: uiOrientation = .right
        default: uiOrientation = .up
        }

        guard let image = try? MPPImage(cvPixelBuffer: pixelBuffer, orientation: uiOrientation) else {
            return nil
        }
        guard let result = try? landmarker.detect(videoFrame: image,
                                                  timestampInMilliseconds: timestampMs) else {
            return nil
        }

        var hands: [MediaPipeHand] = []
        for (index, landmarks) in result.landmarks.enumerated() where index < 2 {
            guard landmarks.count >= 21 else { continue }

            var points: [VNHumanHandPoseObservation.JointName: CGPoint] = [:]
            for (i, name) in Self.jointNames.enumerated() where i < landmarks.count {
                let landmark = landmarks[i]
                // MediaPipe entrega origen arriba-izquierda; el pipeline usa abajo-izquierda.
                let x = CGFloat(landmark.x)
                let y = 1.0 - CGFloat(landmark.y)
                guard x.isFinite, y.isFinite else { continue }
                points[name] = CGPoint(x: x, y: y)
            }
            guard points.count >= 18 else { continue }

            // Lateralidad por geometría: si el pulgar queda a la izquierda del meñique
            // en la imagen, es una mano derecha. Es estable y no depende del modelo.
            var sign: Float = -1
            if let thumb = points[.thumbCMC], let little = points[.littleMCP] {
                sign = thumb.x < little.x ? -1 : 1
            }

            hands.append(MediaPipeHand(key: "MP\(index)", points: points, chiralitySign: sign))
        }

        return hands
    }
}
