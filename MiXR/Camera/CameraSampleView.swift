import AVFoundation
import CoreMedia
import UIKit

/// Muestra los frames de cámara en pantalla sin pasar por CPU.
///
/// `AVSampleBufferDisplayLayer` acepta el `CVPixelBuffer` de la cámara tal cual
/// y lo compone en la GPU: es lo que hacía falta para no comerse los FPS
/// (dibujar con Core Image y copiar a CPU era carísimo).
final class CameraSampleView: UIView {

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private var format: CMVideoFormatDescription?
    private var formatKey = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false

        displayLayer.videoGravity = .resizeAspectFill
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        applyRotation()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    /// La app es horizontal: el fondo sólo necesita 0° o 180°.
    private func applyRotation() {
        let angle: CGFloat = ScreenOrientation.current == .landscapeLeft ? .pi : 0
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        CATransaction.commit()
    }

    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let key = width &* 100_003 &+ height &+ Int(CVPixelBufferGetPixelFormatType(pixelBuffer))

        if key != formatKey {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &description)
            format = description
            formatKey = description == nil ? 0 : key
        }
        guard let format else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                              imageBuffer: pixelBuffer,
                                                              formatDescription: format,
                                                              sampleTiming: &timing,
                                                              sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0),
                                           to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sample)
    }
}
