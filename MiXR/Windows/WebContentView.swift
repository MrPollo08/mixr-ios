import UIKit
import WebKit

/// Página web real dentro de una ventana flotante.
///
/// Implementa `ScrollableContent` (gesto de pinza mantenida + movimiento) y
/// `ClickableContent` (Direct Touch con la yema del dedo).
final class WebContentView: UIView, URLLoadable, ScrollableContent, ClickableContent {

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

    @discardableResult
    func scroll(atLocal point: CGPoint, deltaY: CGFloat) -> Bool {
        let scroll = webView.scrollView
        let maxOffset = max(0, scroll.contentSize.height - scroll.bounds.height)
        let target = min(max(scroll.contentOffset.y + deltaY, -scroll.contentInset.top), maxOffset)
        scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: false)
        return true
    }

    @discardableResult
    func click(atLocal point: CGPoint) -> Bool {
        // Simula un toque real en el punto (funciona con enlaces y controles HTML).
        let js = """
        (function() {
          var x = \(Int(point.x)), y = \(Int(point.y));
          var el = document.elementFromPoint(x, y);
          if (!el) return false;
          el.dispatchEvent(new MouseEvent('mousedown', {bubbles:true, clientX:x, clientY:y}));
          el.dispatchEvent(new MouseEvent('mouseup', {bubbles:true, clientX:x, clientY:y}));
          el.dispatchEvent(new MouseEvent('click', {bubbles:true, clientX:x, clientY:y}));
          if (el.focus) el.focus();
          return true;
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
        return true
    }
}
