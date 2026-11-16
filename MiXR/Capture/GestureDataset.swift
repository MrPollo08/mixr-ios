import Foundation
import Network
import UIKit
import Vision
import simd

/// Etiquetas de gesto que se van a grabar.
enum GestureLabel: Int, CaseIterable {
    case rest = 0
    case pinch = 1
    case fist = 2
    case point = 3
    case openPalm = 4

    var name: String {
        switch self {
        case .rest: return "reposo"
        case .pinch: return "pinza"
        case .fist: return "puno"
        case .point: return "indice"
        case .openPalm: return "palma"
        }
    }

    var shortName: String {
        switch self {
        case .rest: return "REPOSO"
        case .pinch: return "PINZA"
        case .fist: return "PUNO"
        case .point: return "INDICE"
        case .openPalm: return "PALMA"
        }
    }
}

/// Convierte una mano en un vector de features invariante a rotación, escala y posición.
///
/// - Los 21 puntos se expresan respecto de la **muñeca** y se rotan al eje de la palma.
/// - Se dividen por el largo de la palma, así la distancia al teléfono no cambia el vector.
/// - Se agregan distancias entre yemas y nudillos, que son lo que separa una pinza de un puño.
enum GestureFeatureExtractor {

    /// Orden canónico de las 21 articulaciones.
    static let jointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    /// Pares cuya distancia normalizada se agrega como feature.
    private static let distancePairs: [(VNHumanHandPoseObservation.JointName,
                                       VNHumanHandPoseObservation.JointName)] = [
        (.thumbTip, .indexTip),
        (.indexTip, .indexMCP),
        (.middleTip, .middleMCP),
        (.ringTip, .ringMCP),
        (.littleTip, .littleMCP),
        (.thumbTip, .littleMCP)
    ]

    /// Pares yema→nudillo para medir cuánto se curva cada dedo.
    /// Es lo que separa un puño de una palma abierta cuando los dedos apuntan a la cámara.
    private static let curlPairs: [(VNHumanHandPoseObservation.JointName,
                                    VNHumanHandPoseObservation.JointName)] = [
        (.thumbTip, .thumbCMC),
        (.indexTip, .indexMCP),
        (.middleTip, .middleMCP),
        (.ringTip, .ringMCP),
        (.littleTip, .littleMCP)
    ]

    static let featureCount = jointOrder.count * 2 + curlPairs.count + distancePairs.count

    static func features(for hand: HandPose) -> [Float]? {
        guard let wrist = hand.joints[.wrist],
              let middle = hand.joints[.middleMCP] else { return nil }

        let palm = max(hypot(middle.x - wrist.x, middle.y - wrist.y), 10)
        var dirX = (middle.x - wrist.x) / palm
        var dirY = (middle.y - wrist.y) / palm
        let len = max(hypot(dirX, dirY), 1e-4)
        dirX /= len
        dirY /= len
        let perpX = -dirY
        let perpY = dirX

        var out: [Float] = []
        out.reserveCapacity(featureCount)

        for name in jointOrder {
            guard let p = hand.joints[name] else { return nil }
            let vx = (p.x - wrist.x) / palm
            let vy = (p.y - wrist.y) / palm
            out.append(Float(vx * perpX + vy * perpY))
            out.append(Float(vx * dirX + vy * dirY))
        }

        // Curvatura: distancia de la yema a la muñeca sobre la del nudillo.
        // En este marco la muñeca es (0,0), así que alcanza con el módulo del punto.
        for (tip, mcp) in curlPairs {
            guard let pt = hand.joints[tip], let pm = hand.joints[mcp] else { return nil }
            let tipX = (pt.x - wrist.x) / palm
            let tipY = (pt.y - wrist.y) / palm
            let mcpX = (pm.x - wrist.x) / palm
            let mcpY = (pm.y - wrist.y) / palm
            let tipLen = hypot(tipX, tipY)
            let mcpLen = max(hypot(mcpX, mcpY), 1e-3)
            out.append(Float(tipLen / mcpLen))
        }

        for (a, b) in distancePairs {
            guard let pa = hand.joints[a], let pb = hand.joints[b] else { return nil }
            out.append(Float(hypot(pa.x - pb.x, pa.y - pb.y) / palm))
        }

        return out
    }
}

/// Graba muestras etiquetadas y las acumula en un CSV dentro de Documents.
final class GestureDatasetRecorder {

    private(set) var isRecording = false
    private(set) var label: GestureLabel = .rest
    private(set) var totalRows = 0
    private(set) var sessionRows = 0
    /// Muestras por gesto: sin esto no se sabe si el dataset sirve.
    private(set) var labelCounts: [Int] = Array(repeating: 0, count: GestureLabel.allCases.count)

    private var buffer: [String] = []
    private var lastSampleAt: CFTimeInterval = 0
    /// 30 Hz es suficiente y evita muestras casi idénticas.
    private let sampleInterval: CFTimeInterval = 1.0 / 30.0

    var fileURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("dataset.csv")
    }

    init() {
        loadExistingCounts()
    }

    func nextLabel() {
        let all = GestureLabel.allCases
        let index = (label.rawValue + 1) % all.count
        label = all[index]
    }

    func setLabel(_ newLabel: GestureLabel) {
        label = newLabel
    }

    func toggleRecording() {
        isRecording ? stop() : start()
    }

    func start() {
        buffer.removeAll(keepingCapacity: true)
        sessionRows = 0
        lastSampleAt = 0
        isRecording = true
    }

    func stop() {
        isRecording = false
        flush()
    }

    func capture(hand: HandPose, now: CFTimeInterval) {
        guard isRecording else { return }
        guard now - lastSampleAt >= sampleInterval else { return }
        guard let features = GestureFeatureExtractor.features(for: hand) else { return }
        lastSampleAt = now

        var line = "\(label.rawValue)"
        for value in features {
            line += "," + String(format: "%.4f", value)
        }
        buffer.append(line)
        sessionRows += 1
        labelCounts[label.rawValue] += 1
    }

    private func flush() {
        guard !buffer.isEmpty, let url = fileURL else { return }

        let header = "label," + (0..<GestureFeatureExtractor.featureCount)
            .map { "f\($0)" }
            .joined(separator: ",")
        let newText = buffer.joined(separator: "\n") + "\n"

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            if let data = newText.data(using: .utf8) { handle.write(data) }
            try? handle.close()
        } else {
            let text = header + "\n" + newText
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }

        totalRows += buffer.count
        buffer.removeAll(keepingCapacity: true)
    }

    private func existingRowCount() -> Int {
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        return max(text.split(separator: "\n").count - 1, 0)
    }

    /// Relee el CSV para reconstruir el total y el desglose por gesto.
    private func loadExistingCounts() {
        labelCounts = Array(repeating: 0, count: GestureLabel.allCases.count)
        totalRows = 0
        guard let url = fileURL,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }

        for (index, line) in text.split(separator: "\n").enumerated() {
            if index == 0 { continue }  // cabecera
            guard let first = line.first, let value = Int(String(first)),
                  value >= 0, value < labelCounts.count else { continue }
            labelCounts[value] += 1
            totalRows += 1
        }
    }

    /// Desglose compacto para el panel.
    var countsText: String {
        var parts: [String] = []
        for label in GestureLabel.allCases {
            parts.append("\(label.shortName.prefix(2))\(labelCounts[label.rawValue])")
        }
        return parts.joined(separator: "  ")
    }

    func clearDataset() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
        totalRows = 0
        sessionRows = 0
        labelCounts = Array(repeating: 0, count: GestureLabel.allCases.count)
        buffer.removeAll()
        isRecording = false
    }

    var statusText: String {
        let rec = isRecording ? "REC \(sessionRows)" : "listo"
        return "CAP \(label.shortName)  \(rec)  total \(totalRows)"
    }
}

/// Servidor HTTP mínimo para bajar el dataset desde el navegador de la PC.
final class DatasetHTTPServer {

    private var listener: NWListener?
    private let port: UInt16 = 47320
    private let recorder: GestureDatasetRecorder
    private(set) var isRunning = false

    init(recorder: GestureDatasetRecorder) {
        self.recorder = recorder
    }

    func start() {
        guard !isRunning, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        do {
            let listener = try NWListener(using: .tcp, on: nwPort)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
            isRunning = true
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }

            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let wantsCSV = request.contains("dataset.csv")

            if wantsCSV, let url = self.recorder.fileURL {
                let body = (try? Data(contentsOf: url)) ?? Data()
                self.send(connection, body: body,
                          contentType: "text/csv; charset=utf-8",
                          extraHeader: "Content-Disposition: attachment; filename=\"dataset.csv\"\r\n")
            } else {
                let ip = LocalIP.wifiAddress() ?? "?"
                let html = """
                <!doctype html><meta charset="utf-8">
                <body style="font-family:-apple-system,sans-serif;background:#111;color:#eee;padding:24px">
                <h2>Dreamspace - dataset de gestos</h2>
                <p>Filas: <b>\(self.recorder.totalRows)</b> &nbsp; Etiqueta actual: <b>\(self.recorder.label.name)</b></p>
                <p><a style="color:#6cf" href="/dataset.csv">Descargar dataset.csv</a></p>
                <p style="color:#888">http://\(ip):\(self.port)/dataset.csv</p>
                </body>
                """
                self.send(connection, body: Data(html.utf8),
                          contentType: "text/html; charset=utf-8",
                          extraHeader: "")
            }
        }
    }

    private func send(_ connection: NWConnection,
                      body: Data,
                      contentType: String,
                      extraHeader: String) {
        var header = "HTTP/1.1 200 OK\r\n"
        header += "Content-Type: \(contentType)\r\n"
        header += "Content-Length: \(body.count)\r\n"
        header += extraHeader
        header += "Access-Control-Allow-Origin: *\r\n"
        header += "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(body)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
