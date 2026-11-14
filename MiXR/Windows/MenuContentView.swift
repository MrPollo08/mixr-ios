import UIKit

/// Acción que se dispara al apretar un tile del menú flotante.
enum MenuAction: CaseIterable {
    case pc
    case youtube
    case video
    case photos
    case web
    case control
    case hands
    case occlusion
    case camera
    case recenter
    case clear

    var title: String {
        switch self {
        case .pc: return "PC"
        case .youtube: return "YouTube"
        case .video: return "Videos"
        case .photos: return "Fotos"
        case .web: return "Web"
        case .control: return "Mouse PC"
        case .hands: return "Manos"
        case .occlusion: return "Oclusión"
        case .camera: return "Cámara"
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
        case .camera: return "arrow.triangle.2.circlepath.camera"
        case .recenter: return "scope"
        case .clear: return "trash"
        }
    }

    /// Gradiente del tile, estilo home de Quest.
    var colors: [UIColor] {
        switch self {
        case .pc: return [UIColor(hex: 0x6C5CE7), UIColor(hex: 0x3B2FA8)]
        case .youtube: return [UIColor(hex: 0xFF4D4D), UIColor(hex: 0xB31D1D)]
        case .video: return [UIColor(hex: 0x3A8DFF), UIColor(hex: 0x1153A6)]
        case .photos: return [UIColor(hex: 0xFF5FA2), UIColor(hex: 0xA61F62)]
        case .web: return [UIColor(hex: 0x16C79A), UIColor(hex: 0x0A7A5E)]
        case .control: return [UIColor(hex: 0xF7B731), UIColor(hex: 0xB37A08)]
        case .hands: return [UIColor(hex: 0x2ED573), UIColor(hex: 0x157F41)]
        case .occlusion: return [UIColor(hex: 0x9B5DE5), UIColor(hex: 0x5A2E93)]
        case .camera: return [UIColor(hex: 0x4B6584), UIColor(hex: 0x26313F)]
        case .recenter: return [UIColor(hex: 0x45AAF2), UIColor(hex: 0x14639E)]
        case .clear: return [UIColor(hex: 0xEF5777), UIColor(hex: 0x8E1F37)]
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

/// Tile cuadrado con degradé, ícono y nombre: el bloque del menú.
final class MenuTileView: UIView {

    let action: MenuAction

    private let gradient = CAGradientLayer()
    private let icon = UIImageView()
    private let label = UILabel()

    init(action: MenuAction) {
        self.action = action
        super.init(frame: .zero)

        layer.cornerRadius = 13
        layer.cornerCurve = .continuous
        layer.masksToBounds = true

        gradient.colors = action.colors.map { $0.cgColor }
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer.insertSublayer(gradient, at: 0)

        icon.image = UIImage(systemName: action.symbol)
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        addSubview(icon)

        label.text = action.title
        label.font = .systemFont(ofSize: 8.5, weight: .semibold)
        label.textColor = UIColor.white.withAlphaComponent(0.95)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.65
        addSubview(label)
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

        let iconSize = min(bounds.width * 0.46, 22)
        icon.frame = CGRect(x: (bounds.width - iconSize) / 2,
                            y: bounds.height * 0.18,
                            width: iconSize, height: iconSize)
        label.frame = CGRect(x: 3,
                             y: icon.frame.maxY + 2,
                             width: max(0, bounds.width - 6),
                             height: max(0, bounds.height - icon.frame.maxY - 5))
    }

    func setHovered(_ hovered: Bool) {
        layer.borderWidth = hovered ? 2.5 : 0
        layer.borderColor = UIColor.white.withAlphaComponent(0.95).cgColor
        transform = hovered ? CGAffineTransform(scaleX: 1.05, y: 1.05) : .identity
    }

    func flash() {
        transform = CGAffineTransform(scaleX: 0.93, y: 0.93)
        UIView.animate(withDuration: 0.18, delay: 0.08, options: [.curveEaseOut]) {
            self.transform = .identity
        }
    }
}

/// Contenido del menú flotante: un panel tipo home de Quest.
///
/// Sidebar con "Aplicaciones / Mundos", título y grilla de tiles de colores.
/// Se aprieta con la pinza (o con el dedo si el tracking falla).
final class MenuContentView: UIView {

    var onAction: ((MenuAction) -> Void)?

    private let sidebar = UIView()
    private let searchPill = UIView()
    private let searchLabel = UILabel()
    private let appsRow = UIView()
    private let appsLabel = UILabel()
    private let worldsRow = UIView()
    private let worldsLabel = UILabel()

    private let titleLabel = UILabel()
    private let countLabel = UILabel()

    private var tiles: [MenuTileView] = []

    private let columns = 4
    private let inset: CGFloat = 9
    private let spacing: CGFloat = 7
    private let sidebarWidth: CGFloat = 66
    private let headerHeight: CGFloat = 20

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
        sidebar.backgroundColor = UIColor.white.withAlphaComponent(0.05)
        sidebar.layer.cornerRadius = 12
        sidebar.layer.cornerCurve = .continuous
        addSubview(sidebar)

        searchPill.backgroundColor = UIColor.white.withAlphaComponent(0.09)
        searchPill.layer.cornerRadius = 7
        sidebar.addSubview(searchPill)

        searchLabel.text = "Buscar"
        searchLabel.font = .systemFont(ofSize: 8, weight: .medium)
        searchLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        searchPill.addSubview(searchLabel)

        styleRow(appsRow, selected: true)
        styleRow(worldsRow, selected: false)
        sidebar.addSubview(appsRow)
        sidebar.addSubview(worldsRow)

        appsLabel.text = "▦  Aplicaciones"
        appsLabel.font = .systemFont(ofSize: 8, weight: .semibold)
        appsLabel.textColor = .white
        appsRow.addSubview(appsLabel)

        worldsLabel.text = "◎  Mundos"
        worldsLabel.font = .systemFont(ofSize: 8, weight: .medium)
        worldsLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        worldsRow.addSubview(worldsLabel)

        titleLabel.text = "Aplicaciones"
        titleLabel.font = .systemFont(ofSize: 12, weight: .bold)
        titleLabel.textColor = .white
        addSubview(titleLabel)

        countLabel.text = "\(MenuAction.allCases.count)"
        countLabel.font = .systemFont(ofSize: 8, weight: .bold)
        countLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        countLabel.textAlignment = .center
        countLabel.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        countLabel.layer.cornerRadius = 6
        countLabel.layer.masksToBounds = true
        addSubview(countLabel)

        for action in MenuAction.allCases {
            let tile = MenuTileView(action: action)
            addSubview(tile)
            tiles.append(tile)
        }
    }

    private func styleRow(_ row: UIView, selected: Bool) {
        row.backgroundColor = selected
            ? UIColor.white.withAlphaComponent(0.13)
            : UIColor.clear
        row.layer.cornerRadius = 7
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        sidebar.frame = CGRect(x: inset, y: inset,
                               width: sidebarWidth,
                               height: max(0, bounds.height - inset * 2))

        let pillHeight: CGFloat = 18
        searchPill.frame = CGRect(x: 6, y: 8, width: max(0, sidebarWidth - 12), height: pillHeight)
        searchLabel.frame = CGRect(x: 8, y: 0, width: searchPill.bounds.width - 12, height: pillHeight)

        let rowHeight: CGFloat = 20
        appsRow.frame = CGRect(x: 6, y: searchPill.frame.maxY + 8,
                               width: max(0, sidebarWidth - 12), height: rowHeight)
        appsLabel.frame = CGRect(x: 7, y: 0, width: appsRow.bounds.width - 10, height: rowHeight)

        worldsRow.frame = CGRect(x: 6, y: appsRow.frame.maxY + 4,
                                 width: max(0, sidebarWidth - 12), height: rowHeight)
        worldsLabel.frame = CGRect(x: 7, y: 0, width: worldsRow.bounds.width - 10, height: rowHeight)

        let contentX = sidebar.frame.maxX + spacing + 2
        let contentWidth = bounds.width - contentX - inset

        titleLabel.frame = CGRect(x: contentX, y: inset - 1, width: contentWidth - 30, height: headerHeight)
        countLabel.frame = CGRect(x: bounds.width - inset - 26, y: inset + 2, width: 26, height: 14)

        let rows = max(1, Int(ceil(Double(tiles.count) / Double(columns))))
        let gridY = inset + headerHeight + 3
        let availableWidth = contentWidth
        let availableHeight = bounds.height - gridY - inset
        guard availableWidth > 10, availableHeight > 10 else { return }

        let tileWidth = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        let tileHeight = (availableHeight - spacing * CGFloat(rows - 1)) / CGFloat(rows)

        for (index, tile) in tiles.enumerated() {
            let column = index % columns
            let row = index / columns
            tile.frame = CGRect(x: contentX + CGFloat(column) * (tileWidth + spacing),
                                y: gridY + CGFloat(row) * (tileHeight + spacing),
                                width: tileWidth,
                                height: tileHeight)
        }
    }

    // MARK: - Interacción (mano o dedo)

    /// Resalta el tile que está debajo del dedo.
    func setHover(atLocal point: CGPoint?) {
        for tile in tiles {
            tile.setHovered(point.map { tile.frame.contains($0) } ?? false)
        }
    }

    /// Aprieta el tile que está en ese punto. Devuelve true si consumió el gesto.
    func press(atLocal point: CGPoint) -> Bool {
        guard let tile = tiles.first(where: { $0.frame.contains(point) }) else {
            return false
        }
        tile.flash()
        onAction?(tile.action)
        return true
    }
}
