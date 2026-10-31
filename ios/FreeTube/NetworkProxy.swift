import Foundation

/// Performs the network requests for the web app, the equivalent of the request and response header handling
/// in the Electron main process (src/main/index.js) and the poToken session (src/main/poTokenGenerator.js).
///
/// Requests go through a cookieless, cacheless URLSession, so there are no CORS restrictions
/// and YouTube can't track the user with cookies.
final class NetworkProxy: NSObject, URLSessionDataDelegate {
  static let shared = NetworkProxy()

  /// Desktop Safari, so that YouTube serves the same pages and responses as it does for the desktop app
  static let userAgent: String = {
    let majorVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(majorVersion).0 Safari/605.1.15"
  }()

  /// Header the web app uses to pass cookies, as the Cookie header is forbidden by the fetch spec
  private static let xCookieHeader = "X-Cookie"

  /// The CONSENT and SOCS cookies stop YouTube from redirecting to the cookie consent page in the EU
  private static let consentCookies = "CONSENT=YES+; SOCS=CAI"

  /// Response headers that must not be passed on to the web view
  private static let strippedResponseHeaders: Set<String> = [
    "set-cookie",
    "content-security-policy",
    "content-security-policy-report-only",
    "cross-origin-opener-policy",
    "cross-origin-embedder-policy",
    "cross-origin-resource-policy",
    "report-to",
    "reporting-endpoints",
    "nel",
    "alt-svc",
    "strict-transport-security",
    // URLSession decodes the body, so these would be wrong
    "content-encoding",
    "content-length",
    "transfer-encoding",
  ]

  final class Handlers {
    let onResponse: (HTTPURLResponse) -> Void
    let onData: (Data) -> Void
    let onComplete: (Error?) -> Void

    init(onResponse: @escaping (HTTPURLResponse) -> Void, onData: @escaping (Data) -> Void, onComplete: @escaping (Error?) -> Void) {
      self.onResponse = onResponse
      self.onData = onData
      self.onComplete = onComplete
    }
  }

  private let lock = NSLock()
  private var handlers: [Int: Handlers] = [:]
  private let delegateQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "io.freetubeapp.freetube.network"
    queue.maxConcurrentOperationCount = 1
    return queue
  }()

  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 8
    configuration.timeoutIntervalForRequest = 60
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
  }()

  // MARK: - Request preparation

  /// Builds the outgoing request, applying the same header rules as the desktop app
  static func prepare(url: URL, method: String, headers: [String: String], body: Data?) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    if let body, !body.isEmpty, method != "GET", method != "HEAD" {
      request.httpBody = body
    }

    var headers = headers
    var xCookie: String?

    for (name, _) in headers {
      switch name.lowercased() {
      // headers added by WebKit that would reveal the app's internal origin
      case "origin", "referer", "user-agent", "cookie", "host", "content-length", "connection",
        "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest", "sec-fetch-user":
        headers.removeValue(forKey: name)
      case "x-cookie":
        xCookie = headers.removeValue(forKey: name)
      default:
        break
      }
    }

    headers["User-Agent"] = userAgent

    let host = url.host?.lowercased() ?? ""
    let path = url.path
    let urlString = url.absoluteString
    let isYouTube = host == "www.youtube.com" || host == "youtube.com" || host == "m.youtube.com"

    if isYouTube {
      headers["Cookie"] = [consentCookies, xCookie].compactMap { $0 }.joined(separator: "; ")
    }

    if urlString.hasPrefix("https://www.youtube.com/youtubei/") {
      // InnerTube rejects requests if the referer isn't YouTube or empty
      headers["Referer"] = "https://www.youtube.com/"
      headers["Origin"] = "https://www.youtube.com"
      headers["Sec-Fetch-Site"] = "same-origin"
      headers["Sec-Fetch-Mode"] = "same-origin"
      headers["X-Youtube-Bootstrap-Logged-In"] = "false"
    } else if urlString.hasPrefix("https://www.youtube.com/watch") || (host == "www.youtube.com" && (path.isEmpty || path == "/")) {
      headers["Sec-Fetch-Dest"] = "document"
      headers["Sec-Fetch-Mode"] = "navigate"
      headers["Sec-Fetch-Site"] = "none"
      headers["Sec-Fetch-User"] = "?1"
    } else if urlString == "https://www.youtube.com/sw.js_data" || urlString.hasPrefix("https://www.youtube.com/api/timedtext") {
      headers["Referer"] = "https://www.youtube.com/sw.js"
      headers["Sec-Fetch-Site"] = "same-origin"
      headers["Sec-Fetch-Mode"] = "same-origin"
    } else if urlString.hasPrefix("https://www.youtube.com/api/jnn/") {
      headers["Referer"] = "https://www.youtube.com/"
      headers["Origin"] = "https://www.youtube.com"
      headers["Sec-Fetch-Site"] = "same-origin"
      headers["Sec-Fetch-Mode"] = "cors"
    } else if urlString.hasPrefix("https://www.google.com/js/") {
      headers["Sec-Fetch-Dest"] = "script"
      headers["Sec-Fetch-Site"] = "cross-site"
      headers["Accept-Language"] = "*"
    } else if host.hasSuffix(".googleusercontent.com") || host.hasSuffix(".ggpht.com") || host.hasSuffix(".ytimg.com") {
      headers["Referer"] = "https://www.youtube.com/"
      headers["Origin"] = "https://www.youtube.com"
    } else if host.hasSuffix(".googlevideo.com") && path == "/videoplayback" {
      headers["Referer"] = "https://www.youtube.com/"
      headers["Origin"] = "https://www.youtube.com"
      // YouTube doesn't send the Content-Type header for the media requests, so we shouldn't either
      for name in headers.keys where name.lowercased() == "content-type" {
        headers.removeValue(forKey: name)
      }
    }

    request.allHTTPHeaderFields = headers
    return request
  }

  /// Response headers that can be passed on to the web view
  static func filterResponseHeaders(_ response: HTTPURLResponse) -> [String: String] {
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      guard let name = key as? String, let value = value as? String else { continue }
      if !strippedResponseHeaders.contains(name.lowercased()) {
        headers[name] = value
      }
    }
    return headers
  }

  // MARK: - Performing requests

  /// Streams the response through the handlers, which are called on a background queue
  @discardableResult
  func start(_ request: URLRequest, handlers: Handlers) -> URLSessionDataTask {
    let task = session.dataTask(with: request)
    lock.lock()
    self.handlers[task.taskIdentifier] = handlers
    lock.unlock()
    task.resume()
    return task
  }

  /// Fetches the whole response in one go
  func fetch(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        var response: HTTPURLResponse?
        var data = Data()
        let handlers = Handlers(
          onResponse: { response = $0 },
          onData: { data.append($0) },
          onComplete: { error in
            if let error {
              continuation.resume(throwing: error)
            } else if let response {
              continuation.resume(returning: (response, data))
            } else {
              continuation.resume(throwing: URLError(.badServerResponse))
            }
          }
        )
        lock.lock()
        self.handlers[task.taskIdentifier] = handlers
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      task.cancel()
    }
  }

  private func handlers(for task: URLSessionTask) -> Handlers? {
    lock.lock()
    defer { lock.unlock() }
    return handlers[task.taskIdentifier]
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let httpResponse = response as? HTTPURLResponse else {
      completionHandler(.cancel)
      return
    }
    handlers(for: dataTask)?.onResponse(httpResponse)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    handlers(for: dataTask)?.onData(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    let handlers = handlers.removeValue(forKey: task.taskIdentifier)
    lock.unlock()
    handlers?.onComplete(error)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    // Re-apply the header rules for the new destination
    guard let url = request.url, let original = task.originalRequest else {
      completionHandler(request)
      return
    }
    let method = request.httpMethod ?? "GET"
    let headers = original.allHTTPHeaderFields ?? [:]
    let body = method == original.httpMethod ? original.httpBody : nil
    completionHandler(NetworkProxy.prepare(url: url, method: method, headers: headers, body: body))
  }
}
