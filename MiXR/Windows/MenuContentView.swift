import UIKit

/// Acción que se dispara al elegir un tile del menú flotante.
enum MenuAction: CaseIterable {
    case pc
    case youtube
    case video
    case photos
    case web
    case control
    case hands
    case occlusion
    case pin
    case recenter
    case clear

    var title: String {
        switch self {
        case .pc: return "Pantalla PC"
        case .youtube: return "YouTube"
        case .video: return "Videos"
        case .photos: return "Fotos"
        case .web: return "Navegador"
        case .control: return "Mouse PC"
        case .hands: return "Manos"
        case .occlusion: return "Oclusión"
        case .pin: return "Pegar"
        case .recenter: return "Centrar"
        case .clear: return "Limpiar"
        }
    }

    var symbol: String {
        switch self {
        case .pc: return "display"
        case .youtube: return "play.rectangle.fill"
        case .video: return "film"
        case .photos: return "photo.on.rectangle"
        case .web: return "globe"
        case .control: return "cursorarrow"
        case .hands: return "hand.raised.fill"
        case .occlusion: return "circle.dashed"
        case .pin: return "pin.fill"
        case .recenter: return "scope"
        case .clear: return "trash"
        }
    }

    /// Gradiente del tile, estilo home de Quest.
    var colors: [UIColor] {
        switch self {
        case .pc: return [UIColor(hex: 0x7C6CF0), UIColor(hex: 0x3B2FA8)]
        case .youtube: return [UIColor(hex: 0xFF5A5A), UIColor(hex: 0xC01F1F)]
        case .video: return [UIColor(hex: 0x4A9DFF), UIColor(hex: 0x0F4E9E)]
        case .photos: return [UIColor(hex: 0xFF6FB0), UIColor(hex: 0xA81C60)]
        case .web: return [UIColor(hex: 0x1FD6A6), UIColor(hex: 0x087A5C)]
        case .control: return [UIColor(hex: 0xFFC44D), UIColor(hex: 0xB87B05)]
        case .hands: return [UIColor(hex: 0x35E084), UIColor(hex: 0x118A44)]
        case .occlusion: return [UIColor(hex: 0xA96BF0), UIColor(hex: 0x552A93)]
        case .pin: return [UIColor(hex: 0x2BB3A3), UIColor(hex: 0x0D6B60)]
        case .recenter: return [UIColor(hex: 0x53B8FF), UIColor(hex: 0x0E5E9E)]
        case .clear: return [UIColor(hex: 0xF4617B), UIColor(hex: 0x8E1A2E)]
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

/// Tile con degradé e ícono. El nombre va **debajo**, fuera del tile.
final class MenuTileView: UIView {

    let action: MenuAction

    private let gradient = CAGradientLayer()
    private let progressView = UIView()
    private let icon = UIImageView()

    private var progress: CGFloat = 0

    init(action: MenuAction) {
        self.action = action
        super.init(frame: .zero)

        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        gradient.colors = action.colors.map { $0.cgColor }
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        progressView.backgroundColor = UIColor.white.withAlphaComponent(0.34)
        progressView.isHidden = true
        addSubview(progressView)

        icon.image = UIImage(systemName: action.symbol)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()

        let fill = bounds.height * progress
        progressView.frame = CGRect(x: 0, y: bounds.height - fill,
                                    width: bounds.width, height: fill)

        let iconSize = min(bounds.height * 0.52, bounds.width * 0.42)
        icon.frame = CGRect(x: (bounds.width - iconSize) / 2,
                            y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
    }

    func setHovered(_ hovered: Bool) {
        layer.borderWidth = hovered ? 2.5 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.95).cgColor
        transform = hovered ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
    }

    /// 0…1: cuánto falta para que se abra.
    func setProgress(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - progress) > 0.005 else { return }
        progress = clamped
        progressView.isHidden = clamped < 0.01
        setNeedsLayout()
    }

    func flash() {
        transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        UIView.animate(withDuration: 0.18, delay: 0.08, options: [.curveEaseOut]) {
            self.transform = .identity
        }
    }

    func resetProgress() {
        progress = 0
        progressView.isHidden = true
        setNeedsLayout()
    }
}

/// Menú flotante estilo home de Quest: riel a la izquierda, barra con filtros
/// arriba y grilla de tiles anchos con el nombre debajo.
///
/// **Se elige apuntando con el dedo índice**: el tile se ilumina y una barra lo
/// va llenando; al completarse, se abre. También con pinza o toque (instantáneo).
final class MenuContentView: UIView {

    var onAction: ((MenuAction) -> Void)?

    private let rail = UIView()
    private var railIcons: [UIImageView] = []

    private let titleLabel = UILabel()
    private let chipAll = UILabel()
    private let chipRecent = UILabel()

    private var tiles: [MenuTileView] = []
    private var labels: [UILabel] = []
    private var cells: [CGRect] = []

    private var focusedTile: MenuTileView?
    private var firedTile: MenuTileView?
    private var dwell: CGFloat = 0

    /// Segundos que hay que dejar el dedo sobre un tile para abrirlo.
    private var dwellTime: CGFloat = 0.6

    private let columns = 4
    private let inset: CGFloat = 8
    private let spacing: CGFloat = 5
    private let railWidth: CGFloat = 22
    private let headerHeight: CGFloat = 15
    private let labelHeight: CGFloat = 9

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        build()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    // MARK: - Construcción

    private func build() {
        rail.backgroundColor = UIColor.white.withAlphaComponent(0.045)
        rail.layer.cornerRadius = 9
        rail.layer.cornerCurve = .continuous
        addSubview(rail)

        for symbol in ["magnifyingglass", "square.grid.2x2.fill", "arrow.down.circle", "gearshape"] {
            let imageView = UIImageView(image: UIImage(systemName: symbol))
            imageView.tintColor = UIColor.white.withAlphaComponent(0.55)
            imageView.contentMode = .scaleAspectFit
            rail.addSubview(imageView)
            railIcons.append(imageView)
        }

        titleLabel.text = "Todo"
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        addSubview(titleLabel)

        styleChip(chipAll, text: "Todos (\(MenuAction.allCases.count))", highlighted: true)
        styleChip(chipRecent, text: "Recientes", highlighted: false)
        addSubview(chipAll)
        addSubview(chipRecent)

        for action in MenuAction.allCases {
            let tile = MenuTileView(action: action)
            addSubview(tile)
            tiles.append(tile)

            let label = UILabel()
            label.text = action.title
            label.font = .systemFont(ofSize: 7.5, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.85)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            addSubview(label)
            labels.append(label)
        }
    }

    private func styleChip(_ label: UILabel, text: String, highlighted: Bool) {
        label.text = text
        label.font = .systemFont(ofSize: 7.5, weight: .semibold)
        label.textColor = highlighted ? .black : UIColor.white.withAlphaComponent(0.72)
        label.textAlignment = .center
        label.backgroundColor = highlighted
            ? UIColor.white.withAlphaComponent(0.9)
            : UIColor.white.withAlphaComponent(0.1)
        label.layer.cornerRadius = 5
        label.layer.masksToBounds = true
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        rail.frame = CGRect(x: inset, y: inset,
                            width: railWidth,
                            height: max(0, bounds.height - inset * 2))

        let iconSize: CGFloat = 11
        for (index, imageView) in railIcons.enumerated() {
            imageView.frame = CGRect(x: (railWidth - iconSize) / 2,
                                     y: 10 + CGFloat(index) * 20,
                                     width: iconSize, height: iconSize)
        }

        let contentX = rail.frame.maxX + 6
        let contentWidth = bounds.width - contentX - inset
        guard contentWidth > 20 else { return }

        titleLabel.frame = CGRect(x: contentX, y: inset - 2, width: 60, height: headerHeight)
        chipAll.frame = CGRect(x: bounds.width - inset - 96, y: inset, width: 52, height: 12)
        chipRecent.frame = CGRect(x: bounds.width - inset - 40, y: inset, width: 40, height: 12)

        let rows = max(1, Int(ceil(Double(tiles.count) / Double(columns))))
        let gridY = inset + headerHeight + 2
        let availableHeight = bounds.height - gridY - inset
        guard availableHeight > 20 else { return }

        let tileWidth = (contentWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (availableHeight - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        let tileHeight = max(12, cellHeight - labelHeight - 1)

        cells.removeAll(keepingCapacity: true)

        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = contentX + CGFloat(column) * (tileWidth + spacing)
            let y = gridY + CGFloat(row) * (cellHeight + spacing)

            tile.frame = CGRect(x: x, y: y, width: tileWidth, height: tileHeight)
            labels[index].frame = CGRect(x: x, y: y + tileHeight + 1,
                                         width: tileWidth, height: labelHeight)
            cells.append(CGRect(x: x, y: y, width: tileWidth, height: cellHeight))
        }
    }

    // MARK: - Elegir con el dedo

    /// El dedo índice apunta; si se queda quieto sobre un tile, se abre.
    func updatePointer(atLocal point: CGPoint?, dt: CGFloat) {
        guard let point, let tile = tile(at: point, preferring: focusedTile) else {
            clearFocus()
            return
        }

        if let fired = firedTile, fired !== tile {
            fired.resetProgress()
            firedTile = nil
        }

        if tile !== focusedTile {
            focusedTile?.setProgress(0)
            focusedTile?.setHovered(false)
            focusedTile = tile
            tile.setHovered(true)
            dwell = 0
        }

        // Este ya se abrió: esperamos a que el dedo salga.
        if firedTile === tile { return }

        dwell = min(1, dwell + dt / max(dwellTime, 0.1))
        tile.setProgress(dwell)

        if dwell >= 1 {
            firedTile = tile
            tile.flash()
            onAction?(tile.action)
        }
    }

    /// Aprieta el tile que está en ese punto (pinza o toque). Devuelve true si consumió el gesto.
    func press(atLocal point: CGPoint) -> Bool {
        guard let tile = tile(at: point) else { return false }
        tile.flash()
        firedTile = tile
        onAction?(tile.action)
        return true
    }

    private func clearFocus() {
        focusedTile?.setProgress(0)
        focusedTile?.setHovered(false)
        focusedTile = nil
        dwell = 0
        if firedTile != nil {
            firedTile?.resetProgress()
            firedTile = nil
        }
    }

    /// Tile bajo el dedo, con margen y "imán" al más cercano para que no cueste acertar.
    /// Si ya hay uno enfocado, se mantiene mientras el dedo no salga (sticky).
    private func tile(at point: CGPoint, preferring current: MenuTileView? = nil) -> MenuTileView? {
        if let current,
           let index = tiles.firstIndex(where: { $0 === current }),
           index < cells.count,
           cells[index].insetBy(dx: 3, dy: 2).contains(point) {
            return current
        }

        for (index, cell) in cells.enumerated() where index < tiles.count {
            if cell.insetBy(dx: -4, dy: -3).contains(point) { return tiles[index] }
        }

        var closestIndex: Int?
        var closestDistance = CGFloat.greatestFiniteMagnitude
        for (index, cell) in cells.enumerated() {
            let distance = hypot(cell.midX - point.x, cell.midY - point.y)
            if distance < closestDistance {
                closestDistance = distance
                closestIndex = index
            }
        }
        if let index = closestIndex, closestDistance <= 26 { return tiles[index] }
        return nil
    }
}
