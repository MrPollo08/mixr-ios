import AVFoundation
import CoreMedia
import UIKit

/// Ventana que muestra la pantalla del PC en vivo (H.264 por TCP) y, mientras
/// no llega nada, explica cómo conectar el PC.
final class StreamContentView: UIView {

    /// Se dispara cuando llega el primer frame, con el tamaño real del video.
    var onVideoSize: ((CGSize) -> Void)?
    /// IP del PC que se conectó (sirve para mandarle el mouse virtual).
    var onRemoteHost: ((String) -> Void)?

    private let port: UInt16
    private let server: StreamServer
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let stack = UIStackView()
    private let statusLabel = UILabel()
    private let commandLabel = UILabel()
    private let copyButton = UIButton(type: .system)

    private var hasFirstFrame = false

    /// Un solo servidor por puerto: los demás ojos reciben los mismos frames.
    private static var primaries: [UInt16: StreamContentView] = [:]
    private static var mirrors: [UInt16: NSHashTable<StreamContentView>] = [:]

    init(port: UInt16) {
        self.port = port
        self.server = StreamServer(port: port)
        super.init(frame: .zero)

        backgroundColor = .black
        clipsToBounds = true

        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        layer.addSublayer(displayLayer)

        buildPlaceholder()
        wireServer()
        refreshPlaceholder()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    deinit {
        server.stop()
    }

    // MARK: - Ciclo de vida

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            if Self.primaries[port] === self {
                Self.primaries[port] = nil
                Self.mirrors[port] = nil
            } else {
                Self.mirrors[port]?.remove(self)
            }
            server.stop()
            return
        }

        if let primary = Self.primaries[port], primary !== self {
            // Segundo ojo: no abre otro servidor, se cuelga del primero.
            let table = Self.mirrors[port] ?? NSHashTable<StreamContentView>.weakObjects()
            table.add(self)
            Self.mirrors[port] = table
        } else {
            Self.primaries[port] = self
            server.start()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - Placeholder

    private func buildPlaceholder() {
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        statusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = .white
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0

        commandLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        commandLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        commandLabel.textAlignment = .center
        commandLabel.numberOfLines = 0

        copyButton.setTitle("Copiar comando para el PC", for: .normal)
        copyButton.titleLabel?.font = .systemFont(ofSize: 11, weight: .semibold)
        copyButton.tintColor = .white
        copyButton.addTarget(self, action: #selector(copyCommand), for: .touchUpInside)

        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(commandLabel)
        stack.addArrangedSubview(copyButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
    }

    private func refreshPlaceholder() {
        let ip = LocalIP.wifiAddress() ?? "IP_DEL_IPHONE"
        statusLabel.text = "Esperando al PC…\n\(ip):\(port)"
        commandLabel.text = "En tu PC corré stream-pantalla.bat\no el comando de ffmpeg (botón de abajo)."
    }

    @objc private func copyCommand() {
        let ip = LocalIP.wifiAddress() ?? "IP_DEL_IPHONE"
        UIPasteboard.general.string = StreamCommand.ffmpeg(ip: ip, port: port)
        copyButton.setTitle("¡Copiado! Pegalo en el PC", for: .normal)
    }

    // MARK: - Servidor

    private func wireServer() {
        server.onStatus = { [weak self] text in
            DispatchQueue.main.async {
                guard let self else { return }
                if !self.hasFirstFrame {
                    self.statusLabel.text = text
                }
            }
        }

        server.onRemoteHost = { [weak self] host in
            DispatchQueue.main.async { self?.onRemoteHost?(host) }
        }

        server.onSampleBuffer = { [weak self] sample, size in
            DispatchQueue.main.async { self?.enqueue(sample, videoSize: size) }
        }
    }

    private func enqueue(_ sample: CMSampleBuffer, videoSize: CGSize) {
        if !hasFirstFrame {
            hasFirstFrame = true
            stack.isHidden = true
            if videoSize.width > 0, videoSize.height > 0 {
                onVideoSize?(videoSize)
            }
        }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if displayLayer.isReadyForMoreMediaData {
            displayLayer.enqueue(sample)
        }

        // Reparte el mismo frame al otro ojo (si estamos en modo VR).
        if Self.primaries[port] === self, let table = Self.mirrors[port] {
            for mirror in table.allObjects where mirror !== self {
                mirror.enqueue(sample, videoSize: videoSize)
            }
        }
    }
}
