import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the web app from the bundle on `freetube://app/` and proxies external requests made through
/// `freetube://app/__proxy__?url=<encoded url>` (see Bootstrap.js), so that the app has the same origin as its requests.
final class AppSchemeHandler: NSObject, WKURLSchemeHandler {
  static let scheme = "freetube"
  static let host = "app"
  static let origin = "\(scheme)://\(host)"
  static let proxyPath = "/__proxy__"
  /// Chunks of the video downloads, see src/renderer/helpers/iosDownload.js
  static let downloadPath = "/__download__"
  /// The final URL of the proxied request after redirects, used for `Response.url`
  static let finalUrlHeader = "X-FT-Final-URL"

  private let webRoot: URL

  /// Proxied requests that are still running, keyed by the scheme task
  private var activeTasks: [ObjectIdentifier: URLSessionDataTask] = [:]
  /// Download chunks that are being written, a stopped task must not be answered
  private var activeDownloadChunks: Set<ObjectIdentifier> = []

  init(webRoot: URL) {
    self.webRoot = webRoot.standardizedFileURL
  }

  func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
    guard let url = urlSchemeTask.request.url, url.host == AppSchemeHandler.host else {
      fail(urlSchemeTask, URLError(.unsupportedURL))
      return
    }

    if url.path == AppSchemeHandler.proxyPath {
      startProxyRequest(urlSchemeTask, url: url)
    } else if url.path == AppSchemeHandler.downloadPath {
      receiveDownloadChunk(urlSchemeTask, url: url)
    } else {
      serveFile(urlSchemeTask, url: url)
    }
  }

  func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
    let key = ObjectIdentifier(urlSchemeTask)
    activeTasks.removeValue(forKey: key)?.cancel()
    activeDownloadChunks.remove(key)
  }

  // MARK: - Bundled files

  private func serveFile(_ task: WKURLSchemeTask, url: URL) {
    var path = url.path
    if path.isEmpty || path == "/" {
      path = "/index.html"
    }

    let fileUrl = webRoot.appendingPathComponent(String(path.dropFirst())).standardizedFileURL

    guard fileUrl.path.hasPrefix(webRoot.path + "/"), let data = try? Data(contentsOf: fileUrl) else {
      let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/plain"])!
      task.didReceive(response)
      task.didReceive(Data("Not Found".utf8))
      task.didFinish()
      return
    }

    let mimeType = AppSchemeHandler.mimeType(for: fileUrl)
    var headers = [
      "Content-Type": mimeType,
      "Content-Length": String(data.count),
      "Cache-Control": "no-cache",
    ]
    if fileUrl.lastPathComponent == "index.html" {
      // Same restrictions as the desktop app, the only external content are the images and the media
      headers["Content-Security-Policy"] = "object-src 'none'; base-uri 'none'"
    }

    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
    task.didReceive(response)
    task.didReceive(data)
    task.didFinish()
  }

  static func mimeType(for url: URL) -> String {
    switch url.pathExtension.lowercased() {
    case "html": return "text/html; charset=utf-8"
    case "js", "mjs": return "text/javascript; charset=utf-8"
    case "css": return "text/css; charset=utf-8"
    case "json": return "application/json; charset=utf-8"
    case "svg": return "image/svg+xml"
    case "woff2": return "font/woff2"
    case "woff": return "font/woff"
    case "ttf": return "font/ttf"
    default:
      return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
  }

  // MARK: - Proxy

  private func startProxyRequest(_ task: WKURLSchemeTask, url: URL) {
    guard
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let target = components.queryItems?.first(where: { $0.name == "url" })?.value,
      let targetUrl = URL(string: target),
      targetUrl.scheme == "https" || targetUrl.scheme == "http"
    else {
      fail(task, URLError(.badURL))
      return
    }

    let source = task.request
    let method = source.httpMethod ?? "GET"
    let body = source.httpBody ?? source.httpBodyStream.map(AppSchemeHandler.readAll)
    let request = NetworkProxy.prepare(url: targetUrl, method: method, headers: source.allHTTPHeaderFields ?? [:], body: body)

    let key = ObjectIdentifier(task)

    // The scheme task must only be used on the main thread and never after it was stopped,
    // which is the case when it is no longer in `activeTasks`
    let handlers = NetworkProxy.Handlers(
      onResponse: { [weak self] response in
        var headers = NetworkProxy.filterResponseHeaders(response)
        headers[AppSchemeHandler.finalUrlHeader] = response.url?.absoluteString ?? target
        let proxiedResponse = HTTPURLResponse(url: url, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
        DispatchQueue.main.async {
          guard self?.activeTasks[key] != nil else { return }
          task.didReceive(proxiedResponse)
        }
      },
      onData: { [weak self] data in
        DispatchQueue.main.async {
          guard self?.activeTasks[key] != nil else { return }
          task.didReceive(data)
        }
      },
      onComplete: { [weak self] error in
        DispatchQueue.main.async {
          guard let self, self.activeTasks.removeValue(forKey: key) != nil else { return }
          if let error {
            task.didFailWithError(error)
          } else {
            task.didFinish()
          }
        }
      }
    )

    activeTasks[key] = NetworkProxy.shared.start(request, handlers: handlers)
  }

  // MARK: - Downloads

  private func receiveDownloadChunk(_ task: WKURLSchemeTask, url: URL) {
    let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
    guard
      task.request.httpMethod == "POST",
      let id = query.first(where: { $0.name == "id" })?.value,
      let track = query.first(where: { $0.name == "track" })?.value
    else {
      respond(task, url: url, status: 400)
      return
    }

    let body = task.request.httpBody ?? task.request.httpBodyStream.map(AppSchemeHandler.readAll) ?? Data()
    let key = ObjectIdentifier(task)
    activeDownloadChunks.insert(key)

    DownloadManager.shared.receive(id: id, track: track, data: body) { [weak self] accepted in
      guard let self, self.activeDownloadChunks.remove(key) != nil else { return }
      self.respond(task, url: url, status: accepted ? 200 : 410)
    }
  }

  private func respond(_ task: WKURLSchemeTask, url: URL, status: Int) {
    let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "0"])!
    task.didReceive(response)
    task.didFinish()
  }

  private func fail(_ task: WKURLSchemeTask, _ error: Error) {
    task.didFailWithError(error)
  }

  private static func readAll(_ stream: InputStream) -> Data {
    var data = Data()
    stream.open()
    defer { stream.close() }
    let bufferSize = 64 * 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
