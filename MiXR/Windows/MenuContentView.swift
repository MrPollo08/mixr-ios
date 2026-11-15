import UIKit

/// Acción que se dispara al elegir un ícono del menú.
enum MenuAction: CaseIterable {
    case pc
    case youtube
    case video
    case photos
    case web
    case control
    case hands
    case occlusion
    case stereo
    case dreamspace
    case recenter
    case clear

    var title: String {
        switch self {
        case .pc: return "PC"
        case .youtube: return "YouTube"
        case .video: return "Videos"
        case .photos: return "Fotos"
        case .web: return "Web"
        case .control: return "Mouse"
        case .hands: return "Manos"
        case .occlusion: return "Oclusión"
        case .stereo: return "VR"
        case .dreamspace: return "Dreamspace"
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
        case .stereo: return "rectangle.split.2x1"
        case .dreamspace: return "water.waves"
        case .recenter: return "scope"
        case .clear: return "trash"
        }
    }

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
        case .stereo: return [UIColor(hex: 0x8E7CFF), UIColor(hex: 0x3D2AA8)]
        case .dreamspace: return [UIColor(hex: 0x2E7DD7), UIColor(hex: 0x11355E)]
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

/// Ícono circular con degradé, como el launcher espacial de Vision Pro.
final class MenuIconView: UIView {

    let action: MenuAction

    private let gradient = CAGradientLayer()
    private let icon = UIImageView()
    private let progressFill = UIView()

    private var progress: CGFloat = 0

    init(action: MenuAction) {
        self.action = action
        super.init(frame: .zero)

        layer.masksToBounds = true
        layer.borderColor = UIColor.white.withAlphaComponent(0.9).cgColor

        gradient.colors = action.colors.map { $0.cgColor }
        gradient.startPoint = CGPoint(x: 0.15, y: 0)
        gradient.endPoint = CGPoint(x: 0.85, y: 1)
        layer.insertSublayer(gradient, at: 0)

        progressFill.backgroundColor = UIColor.white.withAlphaComponent(0.32)
        progressFill.isHidden = true
        addSubview(progressFill)

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
        layer.cornerRadius = min(bounds.width, bounds.height) / 2
        CATransaction.commit()

        let fill = bounds.height * progress
        progressFill.frame = CGRect(x: 0, y: bounds.height - fill,
                                    width: bounds.width, height: fill)

        let iconSize = bounds.width * 0.44
        icon.frame = CGRect(x: (bounds.width - iconSize) / 2,
                            y: (bounds.height - iconSize) / 2,
                            width: iconSize, height: iconSize)
    }

    func setHovered(_ hovered: Bool) {
        layer.borderWidth = hovered ? 3 : 0
        transform = hovered ? CGAffineTransform(scaleX: 1.12, y: 1.12) : .identity
    }

    func setProgress(_ value: CGFloat) {
        let clamped = min(max(value, 0), 1)
        guard abs(clamped - progress) > 0.008 else { return }
        progress = clamped
        progressFill.isHidden = clamped < 0.01
        setNeedsLayout()
    }

    func flash() {
        transform = CGAffineTransform(scaleX: 0.9, y: 0.9)
        UIView.animate(withDuration: 0.18, delay: 0.07, options: [.curveEaseOut]) {
            self.transform = .identity
        }
    }

    func resetProgress() {
        progress = 0
        progressFill.isHidden = true
        setNeedsLayout()
    }
}

/// Menú espacial: grilla de íconos circulares flotando, sin panel.
///
/// Se elige apuntando con el dedo índice (dwell), con pinza o con toque.
final class MenuContentView: UIView, SpatialPressable {

    var onAction: ((MenuAction) -> Void)?

    private var icons: [MenuIconView] = []
    private var labels: [UILabel] = []
    private var cells: [CGRect] = []

    private var focusedIcon: MenuIconView?
    private var firedIcon: MenuIconView?
    private var dwell: CGFloat = 0
    private let dwellTime: CGFloat = 5.0

    private let columns = 4

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        for action in MenuAction.allCases {
            let icon = MenuIconView(action: action)
            addSubview(icon)
            icons.append(icon)

            let label = UILabel()
            label.text = action.title
            label.font = .systemFont(ofSize: 7.5, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.9)
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.6
            label.layer.shadowColor = UIColor.black.cgColor
            label.layer.shadowOpacity = 0.6
            label.layer.shadowRadius = 3
            label.layer.shadowOffset = CGSize(width: 0, height: 1)
            addSubview(label)
            labels.append(label)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let rows = max(1, Int(ceil(Double(icons.count) / Double(columns))))
        let gap: CGFloat = 4
        let cellWidth = (bounds.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let cellHeight = (bounds.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        guard cellWidth > 8, cellHeight > 8 else { return }

        let labelHeight: CGFloat = 10
        let diameter = min(cellWidth, cellHeight - labelHeight - 2)

        cells.removeAll(keepingCapacity: true)

        for (index, icon) in icons.enumerated() {
            let column = index % columns
            let row = index / columns
            let cellX = CGFloat(column) * (cellWidth + gap)
            let cellY = CGFloat(row) * (cellHeight + gap)

            icon.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            icon.center = CGPoint(x: cellX + cellWidth / 2, y: cellY + diameter / 2)
            icon.setNeedsLayout()

            labels[index].frame = CGRect(x: cellX, y: cellY + diameter + 1,
                                         width: cellWidth, height: labelHeight)

            cells.append(CGRect(x: cellX, y: cellY, width: cellWidth, height: cellHeight))
        }
    }

    // MARK: - Elegir con el dedo

    func updatePointer(atLocal point: CGPoint?, dt: CGFloat) {
        guard let point, let icon = icon(at: point) else {
            clearFocus()
            return
        }

        if let fired = firedIcon, fired !== icon {
            fired.resetProgress()
            firedIcon = nil
        }

        if icon !== focusedIcon {
            focusedIcon?.setProgress(0)
            focusedIcon?.setHovered(false)
            focusedIcon = icon
            icon.setHovered(true)
            dwell = 0
        }

        if firedIcon === icon { return }

        dwell = min(1, dwell + dt / max(dwellTime, 0.1))
        icon.setProgress(dwell)

        if dwell >= 1 {
            firedIcon = icon
            icon.flash()
            onAction?(icon.action)
        }
    }

    func press(atLocal point: CGPoint) -> Bool {
        guard let icon = icon(at: point) else { return false }
        icon.flash()
        firedIcon = icon
        onAction?(icon.action)
        return true
    }

    private func clearFocus() {
        focusedIcon?.setProgress(0)
        focusedIcon?.setHovered(false)
        focusedIcon = nil
        dwell = 0
        if firedIcon != nil {
            firedIcon?.resetProgress()
            firedIcon = nil
        }
    }

    private func icon(at point: CGPoint) -> MenuIconView? {
        for (index, cell) in cells.enumerated() where index < icons.count {
            if cell.insetBy(dx: -3, dy: -2).contains(point) { return icons[index] }
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
        if let index = closestIndex, closestDistance <= 26 { return icons[index] }
        return nil
    }
}
