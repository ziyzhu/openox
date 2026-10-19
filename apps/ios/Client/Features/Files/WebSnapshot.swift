import UIKit
import WebKit

final class WebSnapshot: NSObject, WKNavigationDelegate {
    enum Size {
        case viewport(CGSize)
        case svg(width: CGFloat)
    }

    static let maximumSVGBytes = 4 * 1_024 * 1_024
    private static let maximumSVGAspect: CGFloat = 2
    private static let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:\">"
    private static let svgMeasurement = """
    (() => {
        const r = document.querySelector('svg')?.getBoundingClientRect();
        if (!r || r.width <= 0 || r.height <= 0) return [];
        const scale = Math.min(1, window.innerHeight / r.height);
        document.body.style.transformOrigin = '0 0';
        document.body.style.transform = `scale(${scale})`;
        return [r.width * scale, r.height * scale];
    })()
    """

    private let webView: WKWebView
    private let size: Size
    private var continuation: CheckedContinuation<UIImage, any Error>?
    private var timeout: Task<Void, Never>?

    private init(size: Size) {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let frame = switch size {
        case .viewport(let viewport): CGRect(origin: .zero, size: viewport)
        case .svg(let width): CGRect(x: 0, y: 0, width: width, height: width * Self.maximumSVGAspect)
        }
        webView = WKWebView(frame: frame, configuration: configuration)
        self.size = size
        super.init()
        webView.navigationDelegate = self
        webView.isUserInteractionEnabled = false
    }

    static func image(html: String, size: CGSize) async throws -> UIImage {
        try await WebSnapshot(size: .viewport(size)).render(html)
    }

    static func image(svg: Data, width: CGFloat, style: String = "html{background:#fff}") async throws -> UIImage {
        guard svg.count <= maximumSVGBytes else { throw CocoaError(.fileReadTooLarge) }
        let page = "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><style>body{margin:0}svg{display:block;max-width:100%;height:auto}\(style)</style>" + String(decoding: svg, as: UTF8.self)
        return try await WebSnapshot(size: .svg(width: width)).render(page)
    }

    private func render(_ html: String) async throws -> UIImage {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                timeout = Task {
                    do {
                        try await Task.sleep(for: .seconds(5))
                        finish(.failure(URLError(.timedOut)))
                    } catch {}
                }
                webView.loadHTMLString(Self.policy + html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        switch size {
        case .viewport:
            snapshot(rect: webView.bounds, width: webView.bounds.width)
        case .svg(let width):
            webView.evaluateJavaScript(Self.svgMeasurement) { [self] value, error in
                let measured = (value as? [NSNumber])?.map { CGFloat($0.doubleValue) } ?? []
                guard measured.count == 2, measured[0] > 0, measured[1] > 0 else {
                    finish(.failure(error ?? CocoaError(.fileReadCorruptFile)))
                    return
                }
                let rect = CGRect(x: 0, y: 0, width: measured[0], height: measured[1])
                snapshot(rect: rect, width: min(width, width * Self.maximumSVGAspect * rect.width / rect.height))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(CocoaError(.fileReadUnknown))) }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
    }

    private func snapshot(rect: CGRect, width: CGFloat) {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: Double(width))
        webView.takeSnapshot(with: configuration) { [self] image, error in
            if let image { finish(.success(image)) }
            else { finish(.failure(error ?? CocoaError(.fileReadUnknown))) }
        }
    }

    private func finish(_ result: Swift.Result<UIImage, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        webView.stopLoading()
        continuation.resume(with: result)
    }
}
