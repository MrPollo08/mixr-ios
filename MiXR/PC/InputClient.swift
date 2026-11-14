import Foundation
import Network

/// Manda el mouse virtual al PC por UDP (puerto 47300).
///
/// Protocolo mínimo, 1 datagrama por evento:
///   [0] = tipo (1 mover, 2 botón abajo, 3 botón arriba, 4 scroll)
///   mover: uint16 x, uint16 y (0…65535, little-endian)
///   scroll: int8
final class InputClient {

    enum Tag: UInt8 {
        case move = 1
        case buttonDown = 2
        case buttonUp = 3
        case scroll = 4
    }

    private(set) var isReady = false
    private(set) var host: String?

    private let queue = DispatchQueue(label: "mixr.input")
    private var connection: NWConnection?

    func connect(host: String, port: UInt16 = Config.inputPort) {
        if self.host == host, connection != nil { return }

        connection?.cancel()
        connection = nil
        isReady = false

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isReady = true
            default:
                self?.isReady = false
            }
        }
        connection.start(queue: queue)

        self.connection = connection
        self.host = host
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isReady = false
        host = nil
    }

    // MARK: - Eventos

    func sendMove(x: CGFloat, y: CGFloat) {
        let px = UInt16(min(max(x, 0), 1) * 65535)
        let py = UInt16(min(max(y, 0), 1) * 65535)
        send(Data([Tag.move.rawValue,
                   UInt8(px & 0xFF), UInt8(px >> 8),
                   UInt8(py & 0xFF), UInt8(py >> 8)]))
    }

    func sendButton(down: Bool) {
        send(Data([down ? Tag.buttonDown.rawValue : Tag.buttonUp.rawValue]))
    }

    func sendScroll(_ delta: Int8) {
        send(Data([Tag.scroll.rawValue, UInt8(bitPattern: delta)]))
    }

    private func send(_ data: Data) {
        guard isReady, let connection else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}
