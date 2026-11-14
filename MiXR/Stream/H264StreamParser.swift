import Foundation

/// Parte el flujo TCP del PC en frames H.264 completos.
///
/// Acepta los dos formatos que existen en la práctica:
///  - **Annex B**: lo que manda `ffmpeg -f h264 tcp://...` (start codes 00 00 01).
///  - **Longitud big-endian de 4 bytes + NAL**: lo que manda el driver
///    de VRViewer/SteamVR (así también sirve el setup que ya tenés).
final class H264StreamParser {

    enum Mode {
        case unknown
        case annexB
        case lengthPrefixed
    }

    /// Un frame listo para el ensamblador (con sus SPS/PPS si hacían falta).
    var onPacket: ((Data) -> Void)?

    private(set) var mode: Mode = .unknown
    private var buffer: [UInt8] = []
    private var pendingUnits: [Data] = []

    private static let startCode = Data([0, 0, 0, 1])
    private static let maxPayload = 8 * 1024 * 1024

    func reset() {
        mode = .unknown
        buffer.removeAll(keepingCapacity: true)
        pendingUnits.removeAll(keepingCapacity: true)
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        buffer.append(contentsOf: data)

        if buffer.count > Self.maxPayload * 4 {
            reset()
            return
        }
        process()
    }

    // MARK: - Detecta el formato y reparte

    private func process() {
        if mode == .unknown {
            guard buffer.count >= 4 else { return }
            if Self.isStartCode(at: 0, in: buffer) {
                mode = .annexB
            } else {
                let length = Self.bigEndianLength(Array(buffer.prefix(4)))
                if length > 0, length <= Self.maxPayload {
                    mode = .lengthPrefixed
                } else if buffer.count >= 8 {
                    // Sin pinta de longitud razonable: probamos Annex B igual.
                    mode = .annexB
                } else {
                    return
                }
            }
        }

        switch mode {
        case .annexB:
            processAnnexB()
        case .lengthPrefixed:
            processLengthPrefixed()
        case .unknown:
            break
        }
    }

    private func processAnnexB() {
        while true {
            guard let start = firstStartCode() else {
                if buffer.count > Self.maxPayload {
                    buffer.removeAll(keepingCapacity: true)
                }
                return
            }
            if start > 0 { buffer.removeFirst(start) }

            let headerLength = Self.isFourByteStartCode(at: 0, in: buffer) ? 4 : 3
            guard let next = nextStartCode(after: headerLength) else {
                // El NAL todavía está llegando.
                return
            }

            let unit = Array(buffer[headerLength..<next])
            buffer.removeFirst(next)
            handle(unit)
        }
    }

    private func processLengthPrefixed() {
        while buffer.count >= 4 {
            let length = Self.bigEndianLength(Array(buffer.prefix(4)))
            guard length > 0, length <= Self.maxPayload else {
                buffer.removeAll(keepingCapacity: true)
                return
            }
            guard buffer.count >= 4 + length else { return }

            let payload = Data(buffer[4..<(4 + length)])
            buffer.removeFirst(4 + length)
            onPacket?(payload)
        }
    }

    /// Agrupa SPS/PPS/SEI con el slice que viene después y emite un frame.
    private func handle(_ unit: [UInt8]) {
        guard let header = unit.first else { return }

        switch header & 0x1F {
        case 7, 8, 6, 9:
            pendingUnits.append(Data(unit))
            if pendingUnits.count > 8 { pendingUnits.removeFirst() }

        case 1, 5:
            var packet = Data()
            for pending in pendingUnits {
                packet.append(Self.startCode)
                packet.append(pending)
            }
            pendingUnits.removeAll(keepingCapacity: true)
            packet.append(Self.startCode)
            packet.append(contentsOf: unit)
            onPacket?(packet)

        default:
            break
        }
    }

    // MARK: - Utilidades de bytes

    private static func isStartCode(at index: Int, in bytes: [UInt8]) -> Bool {
        if index + 2 < bytes.count, bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
            return true
        }
        return isFourByteStartCode(at: index, in: bytes)
    }

    private static func isFourByteStartCode(at index: Int, in bytes: [UInt8]) -> Bool {
        index + 3 < bytes.count
            && bytes[index] == 0 && bytes[index + 1] == 0
            && bytes[index + 2] == 0 && bytes[index + 3] == 1
    }

    private static func bigEndianLength(_ header: [UInt8]) -> Int {
        guard header.count >= 4 else { return 0 }
        return (Int(header[0]) << 24) | (Int(header[1]) << 16)
            | (Int(header[2]) << 8) | Int(header[3])
    }

    /// Índice donde arranca el primer start code (prefiere el de 4 bytes).
    private func firstStartCode() -> Int? {
        var index = 0
        while index + 2 < buffer.count {
            if buffer[index] == 0, buffer[index + 1] == 0 {
                if Self.isFourByteStartCode(at: index, in: buffer) { return index }
                if index > 0, buffer[index + 2] == 1, buffer[index - 1] == 0 { return index - 1 }
                if buffer[index + 2] == 1 { return index }
            }
            index += 1
        }
        return nil
    }

    /// Próximo start code a partir de `offset` (ahí termina el NAL actual).
    private func nextStartCode(after offset: Int) -> Int? {
        var index = offset
        while index + 2 < buffer.count {
            if buffer[index] == 0, buffer[index + 1] == 0 {
                if Self.isFourByteStartCode(at: index, in: buffer) { return index }
                if index > offset, buffer[index + 2] == 1, buffer[index - 1] == 0 { return index - 1 }
                if buffer[index + 2] == 1 { return index }
            }
            index += 1
        }
        return nil
    }
}
