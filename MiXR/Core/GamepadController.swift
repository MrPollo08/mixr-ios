import GameController
import UIKit

/// Mando Bluetooth (Xbox, PlayStation, MFi…): joystick para mover el menú.
///
/// - **Stick izquierdo / cruceta**: mueve el menú en el plano de la cámara.
/// - **A**: abre o cierra el menú.
/// - **B / X**: recentra el menú delante tuyo.
///
/// Usa el framework `GameController` de Apple: no hace falta emparejar nada a
/// mano, iOS lo detecta cuando el mando ya está conectado por Bluetooth.
final class GamepadController {

    /// (+1 = derecha, +1 = arriba). Se consulta desde el display link.
    var axes: (x: CGFloat, y: CGFloat) {
        guard let pad = Self.extendedPad() else { return (0, 0) }
        let deadband: CGFloat = 0.16

        var x = CGFloat(pad.leftThumbstick.xAxis.value)
        var y = CGFloat(pad.leftThumbstick.yAxis.value)
        if abs(x) < deadband { x = 0 }
        if abs(y) < deadband { y = 0 }

        if x == 0, y == 0 {
            x = CGFloat(pad.dpad.xAxis.value)
            y = CGFloat(pad.dpad.yAxis.value)
        }
        return (x, y)
    }

    var isConnected: Bool { !GCController.controllers().isEmpty }

    /// Botón A: abre / cierra el menú.
    var onPrimary: (() -> Void)?
    /// Botón B: recentrar.
    var onSecondary: (() -> Void)?
    /// Botón X: alternar autofoco.
    var onTertiary: (() -> Void)?

    init() {
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect,
                                               object: nil, queue: .main) { [weak self] note in
            self?.attach(note.object as? GCController)
        }
        attach(GCController.controllers().first)
        // Busca mandos Bluetooth que estén en modo emparejamiento.
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    private static func extendedPad() -> GCExtendedGamepad? {
        GCController.controllers().compactMap { $0.extendedGamepad }.first
    }

    private func attach(_ controller: GCController?) {
        guard let controller else { return }
        controller.playerIndex = .index1

        let primary: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, pressed in
            if pressed { self?.onPrimary?() }
        }
        let secondary: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, pressed in
            if pressed { self?.onSecondary?() }
        }
        let tertiary: (GCControllerButtonInput, Float, Bool) -> Void = { [weak self] _, _, pressed in
            if pressed { self?.onTertiary?() }
        }

        if let pad = controller.extendedGamepad {
            pad.buttonA.pressedChangedHandler = primary
            pad.buttonB.pressedChangedHandler = secondary
            pad.buttonX.pressedChangedHandler = tertiary
        } else if let pad = controller.gamepad {
            pad.buttonA.pressedChangedHandler = primary
            pad.buttonB.pressedChangedHandler = secondary
            pad.buttonX.pressedChangedHandler = tertiary
        } else if let pad = controller.microGamepad {
            pad.buttonA.pressedChangedHandler = primary
            pad.buttonX.pressedChangedHandler = tertiary
        }
    }
}
