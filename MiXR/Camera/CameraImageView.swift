import CoreImage
import CoreVideo
import Metal
import UIKit

/// Dibuja la imagen de la cámara a pantalla completa (con el recorte "aspect
/// fill" y la orientación correcta).
///
/// Se usa cuando el fondo lo tenemos que pintar nosotros: en el modo gran
/// angular, o cuando le sacamos a ARKit el frame de la ultra gran angular.
final class CameraImageView: UIView {

    private let imageLayer = CALayer()
    private let context: CIContext?
    private let queue = DispatchQueue(label: "mixr.camera-image", qos: .userInitiated)

    private var buffer: CVPixelBuffer?
    private var orientation: UIInterfaceOrientation = .landscapeRight
    private var busy = false

    override init(frame: CGRect) {
        context = MTLCreateSystemDefaultDevice().map {
            CIContext(mtlDevice: $0, options: [.cacheIntermediates: false])
        }
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = false

        imageLayer.contentsGravity = .resize
        imageLayer.magnificationFilter = .linear
        layer.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func update(buffer: CVPixelBuffer, orientation: UIInterfaceOrientation) {
        self.buffer = buffer
        self.orientation = orientation
        schedule()
    }

    private func schedule() {
        guard context != nil, !busy else { return }
        guard bounds.width > 1, bounds.height > 1, let buffer else { return }

        busy = true
        let orientation = self.orientation
        let size = bounds.size

        queue.async { [weak self] in
            guard let self else { return }
            let image = self.render(buffer: buffer, orientation: orientation, size: size)
            DispatchQueue.main.async {
                if let image {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.imageLayer.contents = image
                    CATransaction.commit()
                }
                self.busy = false
            }
        }
    }

    private func render(buffer: CVPixelBuffer,
                        orientation: UIInterfaceOrientation,
                        size: CGSize) -> CGImage? {
        guard let context else { return nil }

        let exif = Int32(ScreenOrientation.visionOrientation(for: orientation).rawValue)
        var source = CIImage(cvPixelBuffer: buffer).oriented(forExifOrientation: exif)
        source = source.transformed(by: CGAffineTransform(translationX: -source.extent.origin.x,
                                                          y: -source.extent.origin.y))

        let imageWidth = source.extent.width
        let imageHeight = source.extent.height
        guard imageWidth > 1, imageHeight > 1 else { return nil }

        let fill = max(size.width / imageWidth, size.height / imageHeight)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
        let dx = (size.width - imageWidth * fill) / 2
        let dy = (size.height - imageHeight * fill) / 2
        let rect = CGRect(origin: .zero, size: size)

        let framed = scaled
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: rect)

        return context.createCGImage(framed, from: rect)
    }
}
