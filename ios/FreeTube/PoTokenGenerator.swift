import UIKit
import WebKit

/// Generates content-bound poTokens with BotGuard, the iOS equivalent of src/main/poTokenGenerator.js.
///
/// BotGuard accesses the global `window` and `document` objects and makes its own requests,
/// so it runs in a separate, hidden web view with a non-persistent data store,
/// which is thrown away after every token, rather than next to the user's data in the app's web view.
@MainActor
final class PoTokenGenerator: NSObject {
  static let shared = PoTokenGenerator()

  /// Requests the BotGuard web view is allowed to make
  private static let allowedHosts: Set<String> = ["www.youtube.com", "www.google.com"]

  /// Routes the fetch requests through the native networking, which also removes the CORS restrictions
  private static let fetchShim = """
  (() => {
    const bridge = window.webkit.messageHandlers.ftFetch
    const toBase64 = (buffer) => {
      let binary = ''
      const bytes = new Uint8Array(buffer)
      for (let i = 0; i < bytes.length; i += 0x8000) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000))
      }
      return btoa(binary)
    }
    window.fetch = async (input, init) => {
      const request = new Request(input, init)
      const headers = {}
      request.headers.forEach((value, name) => { headers[name] = value })
      const body = request.method === 'GET' || request.method === 'HEAD' ? '' : toBase64(await request.arrayBuffer())
      const result = await bridge.postMessage({ url: request.url, method: request.method, headers, body })
      const bytes = Uint8Array.from(atob(result.body), c => c.charCodeAt(0))
      const nullBody = [101, 204, 205, 304].includes(result.status)
      const response = new Response(nullBody ? null : bytes, { status: result.status, headers: result.headers })
      Object.defineProperty(response, 'url', { value: result.url })
      return response
    }
    navigator.sendBeacon = () => false
  })()
  """

  private var queue: Task<Void, Never>?
  private var cachedScript: String?

  /// Requests are processed one after the other, like in the desktop app
  func generate(videoId: String, context: String, initialAttestationData: String, ytConfig: String) async throws -> String {
    let previous = queue
    let task = Task { () throws -> String in
      await previous?.value
      return try await self.internalGenerate(videoId: videoId, context: context, initialAttestationData: initialAttestationData, ytConfig: ytConfig)
    }
    queue = Task { _ = try? await task.value }
    return try await task.value
  }

  private func loadScript() throws -> String {
    if let cachedScript {
      return cachedScript
    }

    guard let url = Bundle.main.url(forResource: "botGuardScript", withExtension: "js") else {
      throw PoTokenError.message("botGuardScript.js is missing from the app bundle")
    }
    let content = try String(contentsOf: url, encoding: .utf8)

    // The script is an ES module with a default export (see _scripts/webpack.botGuardScript.config.js),
    // callAsyncJavaScript runs it as the body of an async function, so call the default export and return its result
    let regex = try NSRegularExpression(pattern: #"export\{(\w+) as default\};"#)
    let range = NSRange(content.startIndex..., in: content)
    guard
      let match = regex.firstMatch(in: content, range: range),
      let fullRange = Range(match.range, in: content),
      let nameRange = Range(match.range(at: 1), in: content)
    else {
      throw PoTokenError.message("Could not find the default export in botGuardScript.js")
    }
    let name = content[nameRange]
    let script = content.replacingCharacters(
      in: fullRange,
      with: ";return await \(name)(videoId, JSON.parse(context), JSON.parse(initialAttestationData), JSON.parse(ytConfig));"
    )
    cachedScript = script
    return script
  }

  private func internalGenerate(videoId: String, context: String, initialAttestationData: String, ytConfig: String) async throws -> String {
    let script = try loadScript()

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .nonPersistent()
    configuration.mediaTypesRequiringUserActionForPlayback = .all
    configuration.userContentController.addScriptMessageHandler(FetchBridge(), contentWorld: .page, name: "ftFetch")
    configuration.userContentController.addUserScript(
      WKUserScript(source: PoTokenGenerator.fetchShim, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    )

    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), configuration: configuration)
    webView.customUserAgent = NetworkProxy.userAgent
    webView.isUserInteractionEnabled = false
    webView.accessibilityElementsHidden = true

    // Web views that aren't in a window get throttled, so put it in the window behind the app's content
    let host = UIApplication.shared.connectedScenes
      .compactMap { ($0 as? UIWindowScene)?.keyWindow }
      .first
    if let host {
      host.insertSubview(webView, at: 0)
    }

    defer {
      webView.stopLoading()
      webView.configuration.userContentController.removeAllScriptMessageHandlers()
      webView.removeFromSuperview()
    }

    let loader = NavigationWaiter()
    webView.navigationDelegate = loader
    webView.loadHTMLString(
      #"<!DOCTYPE html><html lang="en"><head><title></title></head><body></body></html>"#,
      baseURL: URL(string: "https://www.youtube.com/")
    )
    try await loader.wait()

    let result = try await webView.callAsyncJavaScript(
      script,
      arguments: [
        "videoId": videoId,
        "context": context,
        "initialAttestationData": initialAttestationData,
        "ytConfig": ytConfig,
      ],
      in: nil,
      contentWorld: .page
    )

    guard let token = result as? String, !token.isEmpty else {
      throw PoTokenError.message("BotGuard did not return a poToken")
    }
    return token
  }

  enum PoTokenError: LocalizedError {
    case message(String)

    var errorDescription: String? {
      switch self {
      case .message(let message): return message
      }
    }
  }

  /// Waits for the initial page load
  private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
      if let result {
        return try result.get()
      }
      try await withCheckedThrowingContinuation { continuation = $0 }
    }

    private func finish(_ result: Result<Void, Error>) {
      guard self.result == nil else { return }
      self.result = result
      continuation?.resume(with: result)
      continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      finish(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
      finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
      finish(.failure(error))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      // Only the initial page, BotGuard must not navigate anywhere
      decisionHandler(navigationAction.request.url?.absoluteString == "https://www.youtube.com/" || navigationAction.request.url?.scheme == "about" ? .allow : .cancel)
    }
  }

  /// Performs the fetch requests of the BotGuard web view
  private final class FetchBridge: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
      guard
        let body = message.body as? [String: Any],
        let urlString = body["url"] as? String,
        let url = URL(string: urlString),
        url.scheme == "https",
        let host = url.host, PoTokenGenerator.allowedHosts.contains(host)
      else {
        replyHandler(nil, "Request not allowed")
        return
      }

      let method = (body["method"] as? String) ?? "GET"
      let headers = (body["headers"] as? [String: String]) ?? [:]
      let requestBody = (body["body"] as? String).flatMap { Data(base64Encoded: $0) }
      let request = NetworkProxy.prepare(url: url, method: method, headers: headers, body: requestBody)

      Task { @MainActor in
        do {
          let (response, data) = try await NetworkProxy.shared.fetch(request)
          replyHandler([
            "url": response.url?.absoluteString ?? urlString,
            "status": response.statusCode,
            "headers": NetworkProxy.filterResponseHeaders(response),
            "body": data.base64EncodedString(),
          ], nil)
        } catch {
          replyHandler(nil, error.localizedDescription)
        }
      }
    }
  }
}
