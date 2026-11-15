import UIKit

/// Contenido que se puede apretar con el dedo o con la pinza.
protocol SpatialPressable: AnyObject {
    func updatePointer(atLocal point: CGPoint?, dt: CGFloat)
    func press(atLocal point: CGPoint) -> Bool
}

/// Teclado flotante estilo Quest: teclas grandes para escribir con la mano.
///
/// Cada tecla manda el carácter a la PC por UDP (y también sirve con el dedo).
final class KeyboardContentView: UIView, SpatialPressable {

    /// "a", " ", "enter", "back"
    var onKey: ((String) -> Void)?

    private final class Key: UIView {
        let value: String
        private var progress: CGFloat = 0
        private let fill = UIView()

        init(value: String, label: String) {
            self.value = value
            super.init(frame: .zero)

            backgroundColor = UIColor.white.withAlphaComponent(0.12)
            layer.cornerRadius = 7
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
            layer.masksToBounds = true

            fill.backgroundColor = UIColor.white.withAlphaComponent(0.34)
            fill.isHidden = true
            addSubview(fill)

            let text = UILabel()
            text.text = label
            text.font = .systemFont(ofSize: value.count > 1 ? 10 : 15, weight: .medium)
            text.textColor = .white
            text.textAlignment = .center
            text.tag = 99
            addSubview(text)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layoutSubviews() {
            super.layoutSubviews()
            let textHeight: CGFloat = 18
            let textWidth = min(bounds.width - 4, 90)
            textView?.frame = CGRect(x: (bounds.width - textWidth) / 2,
                                     y: (bounds.height - textHeight) / 2,
                                     width: textWidth, height: textHeight)
            let h = bounds.height * progress
            fill.frame = CGRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        }

        private var textView: UILabel? { viewWithTag(99) as? UILabel }

        func setHovered(_ hovered: Bool) {
            layer.borderWidth = hovered ? 2 : 1
            layer.borderColor = hovered
                ? UIColor.white.withAlphaComponent(0.85).cgColor
                : UIColor.white.withAlphaComponent(0.14).cgColor
            backgroundColor = UIColor.white.withAlphaComponent(hovered ? 0.22 : 0.12)
        }

        func setProgress(_ value: CGFloat) {
            let clamped = min(max(value, 0), 1)
            guard abs(clamped - progress) > 0.008 else { return }
            progress = clamped
            fill.isHidden = clamped < 0.01
            setNeedsLayout()
        }

        func flash() {
            backgroundColor = UIColor.white.withAlphaComponent(0.45)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.setHovered(false)
            }
        }

        func resetProgress() {
            progress = 0
            fill.isHidden = true
            setNeedsLayout()
        }
    }

    private let rows: [[(value: String, label: String, units: CGFloat)]] = [
        [("q", "q", 1), ("w", "w", 1), ("e", "e", 1), ("r", "r", 1), ("t", "t", 1),
         ("y", "y", 1), ("u", "u", 1), ("i", "i", 1), ("o", "o", 1), ("p", "p", 1)],
        [("a", "a", 1), ("s", "s", 1), ("d", "d", 1), ("f", "f", 1), ("g", "g", 1),
         ("h", "h", 1), ("j", "j", 1), ("k", "k", 1), ("l", "l", 1), ("ñ", "ñ", 1)],
        [("z", "z", 1), ("x", "x", 1), ("c", "c", 1), ("v", "v", 1), ("b", "b", 1),
         ("n", "n", 1), ("m", "m", 1), (".", ".", 1), ("@", "@", 1), ("-", "-", 1)],
        [("back", "borrar", 3), (" ", "espacio", 4), ("enter", "enter", 2)]
    ]

    private var keys: [Key] = []
    private var cells: [CGRect] = []

    private var focusedKey: Key?
    private var firedKey: Key?
    private var dwell: CGFloat = 0
    private let dwellTime: CGFloat = 0.45

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        for row in rows {
            for item in row {
                let key = Key(value: item.value, label: item.label)
                addSubview(key)
                keys.append(key)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 40, bounds.height > 40 else { return }

        let gap: CGFloat = 3
        let rowCount = rows.count
        let rowHeight = (bounds.height - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)

        cells.removeAll(keepingCapacity: true)
        var index = 0

        for (rowIndex, row) in rows.enumerated() {
            let units = row.reduce(0) { $0 + $1.units }
            let unitWidth = (bounds.width - gap * CGFloat(row.count - 1)) / units
            var x: CGFloat = 0
            let y = CGFloat(rowIndex) * (rowHeight + gap)

            for item in row {
                let width = unitWidth * item.units
                let key = keys[index]
                key.frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                cells.append(CGRect(x: x, y: y, width: width, height: rowHeight))
                x += width + gap
                index += 1
            }
        }
    }

    // MARK: - Mano / dedo

    func updatePointer(atLocal point: CGPoint?, dt: CGFloat) {
        guard let point, let key = key(at: point) else {
            clearFocus()
            return
        }

        if let fired = firedKey, fired !== key {
            fired.resetProgress()
            firedKey = nil
        }

        if key !== focusedKey {
            focusedKey?.setProgress(0)
            focusedKey?.setHovered(false)
            focusedKey = key
            key.setHovered(true)
            dwell = 0
        }

        if firedKey === key { return }

        dwell = min(1, dwell + dt / max(dwellTime, 0.1))
        key.setProgress(dwell)

        if dwell >= 1 {
            firedKey = key
            key.flash()
            onKey?(key.value)
        }
    }

    func press(atLocal point: CGPoint) -> Bool {
        guard let key = key(at: point) else { return false }
        key.flash()
        firedKey = key
        onKey?(key.value)
        return true
    }

    private func clearFocus() {
        focusedKey?.setProgress(0)
        focusedKey?.setHovered(false)
        focusedKey = nil
        dwell = 0
        if firedKey != nil {
            firedKey?.resetProgress()
            firedKey = nil
        }
    }

    private func key(at point: CGPoint) -> Key? {
        for (index, cell) in cells.enumerated() where index < keys.count {
            if cell.insetBy(dx: -2, dy: -2).contains(point) { return keys[index] }
        }
        return nil
    }
}
