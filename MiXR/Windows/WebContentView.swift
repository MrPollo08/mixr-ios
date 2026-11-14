import UIKit
import WebKit

/// Página web real dentro de una ventana flotante.
final class WebContentView: UIView, URLLoadable {

    private let webView: WKWebView

    init(url: URL) {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)

        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true

        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = true
        addSubview(webView)

        setURL(url)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) no se usa")
    }

    func setURL(_ url: URL) {
        webView.load(URLRequest(url: url))
    }
}
