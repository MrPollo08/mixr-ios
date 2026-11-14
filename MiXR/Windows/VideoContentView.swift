import AVFoundation
import UIKit

/// Reproduce un video (HLS/MP4 remoto o un archivo de la galería).
final class VideoContentView: UIView, URLLoadable {

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    private var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    private let player = AVPlayer()
    private let hint = UILabel()

    init(url: URL?) {
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        playerLayer.videoGravity = .resizeAspect
        playerLayer.player = player
        player.actionAtItemEnd = .none

        hint.text = "tocá para pausar"
        hint.font = .systemFont(ofSize: 10, weight: .medium)
        hint.textColor = UIColor.white.withAlphaComponent(0.5)
        hint.textAlignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePlayback))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        NotificationCenter.default.addObserver(self,
                                               selector: #selector(loop),
                                               name: .AVPlayerItemDidPlayToEndTime,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(resumeIfNeeded),
                                               name: UIApplication.didBecomeActiveNotification,
                                               object: nil)

        if let url { setURL(url) }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func setURL(_ url: URL) {
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
    }

    @objc private func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    @objc private func loop() {
        player.seek(to: .zero)
        player.play()
    }

    @objc private func resumeIfNeeded() {
        if player.currentItem != nil { player.play() }
    }
}
