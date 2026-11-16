import AVFoundation
import MediaPlayer
import UIKit

/// Lee los botones de **volumen** del iPhone como entrada, sin UI.
///
/// Sirve para etiquetar y grabar dentro de una caja VR, donde no se puede tocar la
/// pantalla. Se apoya en la `AVAudioSession` y oculta el HUD del sistema con un
/// `MPVolumeView` fuera de pantalla.
final class VolumeButtons: NSObject {

    private let session = AVAudioSession.sharedInstance()
    private var lastVolume: Float = 0
    private var hudSuppressor: MPVolumeView?
    private var onUp: (() -> Void)?
    private var onDown: (() -> Void)?
    private var observing = false

    override init() {
        super.init()
    }

    func start(onUp: @escaping () -> Void, onDown: @escaping () -> Void) {
        self.onUp = onUp
        self.onDown = onDown
        guard !observing else { return }

        do {
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try session.setActive(true, options: [])
        } catch {
            // Sin sesión de audio igual funcionan el mando y los toques.
        }

        lastVolume = session.outputVolume

        // Suprime el HUD de volumen del sistema (queda fuera de pantalla).
        if let window = Self.keyWindow() {
            let view = MPVolumeView(frame: CGRect(x: -2000, y: -2000, width: 1, height: 1))
            view.alpha = 0.01
            window.addSubview(view)
            hudSuppressor = view
        }

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(volumeNotification(_:)),
                                               name: NSNotification.Name("AVSystemController_SystemVolumeDidChangeNotification"),
                                               object: nil)
        session.addObserver(self, forKeyPath: "outputVolume", options: [.new], context: nil)
        observing = true
    }

    func stop() {
        guard observing else { return }
        NotificationCenter.default.removeObserver(self)
        session.removeObserver(self, forKeyPath: "outputVolume")
        hudSuppressor?.removeFromSuperview()
        hudSuppressor = nil
        observing = false
    }

    @objc private func volumeNotification(_ note: Notification) {
        guard let reason = note.userInfo?["AVSystemController_AudioVolumeChangeReasonNotificationParameter"] as? String,
              reason == "ExplicitVolumeChange" else { return }
        handleChange()
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        guard keyPath == "outputVolume" else { return }
        handleChange()
    }

    private func handleChange() {
        let volume = session.outputVolume
        let delta = volume - lastVolume
        guard abs(delta) > 0.001 else { return }
        lastVolume = volume

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if delta > 0 { self.onUp?() } else { self.onDown?() }
        }
    }

    private static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.windows.first
            ?? scenes.first?.windows.first
    }
}
