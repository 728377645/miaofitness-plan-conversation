import UIKit
import WebKit

final class ViewController: UIViewController {

    private var webView: WKWebView!
    private lazy var server = LocalWebServer(root: Bundle.main.bundleURL)

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        // 与页面 theme-color (#2e7d32) 一致，避免状态栏区域色差
        view.backgroundColor = UIColor(red: 0.18, green: 0.49, blue: 0.20, alpha: 1.0)
        setupWebView()
        loadContent()
    }

    private func setupWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true

        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(self), name: "fitnessSave")
        controller.add(WeakScriptMessageHandler(self), name: "fitnessCopy")
        controller.addUserScript(
            WKUserScript(source: Self.bridgeScript,
                         injectionTime: .atDocumentEnd,
                         forMainFrameOnly: true)
        )
        configuration.userContentController = controller

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.scrollView.bounces = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = false
        self.webView = webView

        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func loadContent() {
        do {
            try server.start()
            if let base = server.baseURL {
                let url = base.appendingPathComponent("index.html")
                let request = URLRequest(url: url,
                                         cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 30)
                webView.load(request)
                return
            }
        } catch {
            NSLog("[FitnessPlan] local server failed: \(error)")
        }
        // 兜底：直接用 file:// 加载（此时 AI 跨域能力可能受限）
        if let file = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
        }
    }

    // MARK: - JS <-> Native 桥接

    /// 补齐 WKWebView 与浏览器行为差异：剪贴板、Blob 导出下载。
    private static let bridgeScript = """
    (function () {
      // 1) navigator.clipboard 在 WKWebView 中常不可用，桥接到 UIPasteboard
      try {
        Object.defineProperty(navigator, 'clipboard', {
          configurable: true,
          value: {
            writeText: function (text) {
              window.webkit.messageHandlers.fitnessCopy.postMessage(String(text));
              return Promise.resolve();
            }
          }
        });
      } catch (e) {}

      // 2) <a download> + Blob 导出在 WKWebView 里不会触发下载，交由原生保存并分享
      try {
        var originalClick = HTMLAnchorElement.prototype.click;
        HTMLAnchorElement.prototype.click = function () {
          if (this.download && String(this.href).indexOf('blob:') === 0) {
            var filename = this.download;
            var href = this.href;
            fetch(href).then(function (r) { return r.blob(); }).then(function (blob) {
              var reader = new FileReader();
              reader.onload = function () {
                var result = String(reader.result);
                window.webkit.messageHandlers.fitnessSave.postMessage({
                  name: filename,
                  mime: blob.type || 'application/octet-stream',
                  base64: result.substring(result.indexOf(',') + 1)
                });
              };
              reader.readAsDataURL(blob);
            }).catch(function () {});
            return;
          }
          return originalClick.apply(this, arguments);
        };
      } catch (e) {}
    })();
    """

    private func saveAndShare(named name: String, data: Data) {
        let directory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = (name as NSString).lastPathComponent
        let url = directory.appendingPathComponent(safeName)
        try? data.write(to: url, options: .atomic)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = self.view
            activity.popoverPresentationController?.sourceRect = CGRect(
                x: self.view.bounds.midX, y: self.view.bounds.midY, width: 0, height: 0
            )
            self.present(activity, animated: true)
        }
    }
}

// MARK: - WKScriptMessageHandler

extension ViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "fitnessCopy":
            if let text = message.body as? String {
                UIPasteboard.general.string = text
            }
        case "fitnessSave":
            guard let body = message.body as? [String: Any],
                  let name = body["name"] as? String,
                  let base64 = body["base64"] as? String,
                  let data = Data(base64Encoded: base64) else { return }
            saveAndShare(named: name, data: data)
        default:
            break
        }
    }
}

/// 避免 WKUserContentController 强引用 ViewController 造成循环引用。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - WKUIDelegate（页面里的 confirm / alert / prompt）

extension ViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "确定", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }
}

// MARK: - WKNavigationDelegate

extension ViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL || url.host == "127.0.0.1" || url.host == "localhost" {
            decisionHandler(.allow)
        } else if navigationAction.navigationType == .linkActivated {
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
