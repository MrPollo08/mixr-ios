import CoreMedia
import Foundation
import Network

/// Servidor TCP que recibe el stream H.264 del PC.
///
/// El iPhone escucha y el PC se conecta (`ffmpeg ... tcp://IP_DEL_IPHONE:47295`),
/// así no hay que configurar nada en el teléfono más que abrir la ventana.
final class StreamServer {

    var onStatus: ((String) -> Void)?
    var onSampleBuffer: ((CMSampleBuffer, CGSize) -> Void)?
    /// IP del PC que se conectó (para mandarle el mouse virtual).
    var onRemoteHost: ((String) -> Void)?

    private let port: UInt16
    private let queue = DispatchQueue(label: "mixr.stream-server")
    private let parser = H264StreamParser()
    private let assembler = H264Assembler()

    private var listener: NWListener?
    private var connection: NWConnection?

    private(set) var remoteHost: String?

    init(port: UInt16) {
        self.port = port
    }

    var isRunning: Bool { listener != nil }

    // MARK: - Ciclo de vida

    func start() {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.onStatus?("Escuchando en el puerto \(self.port)")
                case .failed(let error):
                    self.onStatus?("No se pudo abrir el puerto \(self.port): \(error.localizedDescription)")
                case .cancelled:
                    self.onStatus?("Servidor detenido")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            parser.onPacket = { [weak self] packet in
                self?.decode(packet)
            }

            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStatus?("Puerto \(port) ocupado por otra app")
        }
    }

    func stop() {
        connection?.cancel()
        connection = nil
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.parser.reset()
            self?.assembler.reset()
        }
    }

    deinit {
        connection?.cancel()
        listener?.cancel()
    }

    // MARK: - Conexión

    private func accept(_ connection: NWConnection) {
        self.connection?.cancel()
        self.connection = connection

        parser.reset()
        assembler.reset()

        if case let .hostPort(host, _) = connection.endpoint {
            let text = "\(host)"
            remoteHost = text
            onRemoteHost?(text)
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStatus?("PC conectado ✓")
            case .failed(let error):
                self.onStatus?("Stream: \(error.localizedDescription)")
            case .cancelled:
                self.onStatus?("PC desconectado")
            default:
                break
            }
        }

        connection.start(queue: queue)
        receive(on: connection)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.parser.append(data)
            }
            if let error {
                self.onStatus?("Stream: \(error.localizedDescription)")
                return
            }
            if isComplete {
                self.onStatus?("El PC cerró la conexión")
                return
            }
            self.receive(on: connection)
        }
    }

    // MARK: - Decodificación

    private func decode(_ packet: Data) {
        guard let sample = assembler.sampleBuffer(from: packet) else { return }

        var size = CGSize.zero
        if let format = CMSampleBufferGetFormatDescription(sample) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            if dimensions.width > 0, dimensions.height > 0 {
                size = CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
            }
        }

        onSampleBuffer?(sample, size)
    }
}
