import AVFoundation
import SafariServices
import UIKit
import UniformTypeIdentifiers
import VideoToolbox
import WebKit

/// Hosts the FreeTube web app.
/// The web view fills the whole screen and the native Liquid Glass controls (NativeChrome.swift) float above it,
/// they replace FreeTube's own top and side navigation (hidden by src/renderer/ios.css).
final class WebViewController: UIViewController {
  private var webView: WKWebView!
  private let chrome = NativeChrome()
  private var statusBarStyle: UIStatusBarStyle = .darkContent
  /// The style of the FreeTube theme, for the native screens presented over the web app
  private var themeInterfaceStyle: UIUserInterfaceStyle = .unspecified
  private var pendingDownloadDestinations: [ObjectIdentifier: URL] = [:]
  private var canGoBackObservation: NSKeyValueObservation?
  private var scrollObservation: NSKeyValueObservation?
  private var downloadsScrollObservation: NSKeyValueObservation?
  private let downloads = DownloadsViewController()
  private var lastInsets: (top: CGFloat, bottom: CGFloat)?
  private var miniPlayerBottom: NSLayoutConstraint!

  override var preferredStatusBarStyle: UIStatusBarStyle { statusBarStyle }
  override var prefersStatusBarHidden: Bool { isPlayerFullscreen }
  override var prefersHomeIndicatorAutoHidden: Bool { isPlayerFullscreen }
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    orientationLock ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
  }

  // MARK: Player fullscreen

  private var isPlayerFullscreen = false
  /// The background of the current theme
  private var pageColor: UIColor = .black
  private var orientationLock: UIInterfaceOrientationMask?
  /// The lock is released once the device is held in this orientation
  private var unlockWhenDevice: UIInterfaceOrientationMask?

  func setPlayerFullscreen(_ fullscreen: Bool) {
    guard fullscreen != isPlayerFullscreen else { return }
    isPlayerFullscreen = fullscreen
    // no light flash around the video while rotating
    view.window?.backgroundColor = .black
    if fullscreen {
      view.backgroundColor = .black
      webView.underPageBackgroundColor = .black
    } else {
      view.backgroundColor = pageColor
      webView.underPageBackgroundColor = pageColor
    }
    webView.scrollView.isScrollEnabled = !fullscreen
    chrome.isUserInteractionEnabled = !fullscreen
    UIView.animate(withDuration: 0.25) {
      self.chrome.alpha = fullscreen ? 0 : 1
      self.setNeedsStatusBarAppearanceUpdate()
    }
    setNeedsUpdateOfHomeIndicatorAutoHidden()
  }

  func setOrientation(_ mode: String) {
    switch mode {
    case "landscape": lockOrientation(.landscape, unlockWhen: nil)
    case "portrait": lockOrientation(.portrait, unlockWhen: nil)
    case "landscape-auto": lockOrientation(.landscape, unlockWhen: .landscape)
    case "portrait-auto": lockOrientation(.portrait, unlockWhen: .portrait)
    default: lockOrientation(nil, unlockWhen: nil)
    }
  }

  private func lockOrientation(_ mask: UIInterfaceOrientationMask?, unlockWhen: UIInterfaceOrientationMask?) {
    // already held that way, nothing to keep locked
    if let unlockWhen, deviceOrientationMatches(unlockWhen) {
      orientationLock = nil
      unlockWhenDevice = nil
    } else {
      orientationLock = mask
      unlockWhenDevice = unlockWhen
    }
    setNeedsUpdateOfSupportedInterfaceOrientations()
    if let mask {
      view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
  }

  private func deviceOrientationMatches(_ mask: UIInterfaceOrientationMask) -> Bool {
    switch UIDevice.current.orientation {
    case .portrait: return mask.contains(.portrait)
    case .landscapeLeft, .landscapeRight: return mask.contains(.landscapeLeft)
    default: return false
    }
  }

  @objc private func deviceOrientationDidChange() {
    guard let unlockWhenDevice, deviceOrientationMatches(unlockWhenDevice) else { return }
    self.unlockWhenDevice = nil
    orientationLock = nil
    setNeedsUpdateOfSupportedInterfaceOrientations()
  }

  override func loadView() {
    let root = UIView()
    root.backgroundColor = UIColor(named: "LaunchBackground")
    view = root

    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = .default()
    configuration.allowsInlineMediaPlayback = true
    configuration.allowsPictureInPictureMediaPlayback = true
    configuration.allowsAirPlayForMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []
    configuration.dataDetectorTypes = []
    // On the iPhone the video goes into the native fullscreen player (webkitEnterFullscreen),
    // which has the system playback controls, picture in picture, AirPlay and rotation
    configuration.preferences.isElementFullscreenEnabled = UIDevice.current.userInterfaceIdiom == .pad
    configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
    configuration.preferences.isFraudulentWebsiteWarningEnabled = false

    BackgroundPlayback.configure(configuration.preferences)

    let webRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
    configuration.setURLSchemeHandler(AppSchemeHandler(webRoot: webRoot), forURLScheme: AppSchemeHandler.scheme)

    let contentController = configuration.userContentController
    let hardwareDecode = """
      window.__ftHardwareDecode = Object.freeze({ av1: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)), vp9: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)) });
      window.__ftDownloadCapabilities = Object.freeze({ av1: \(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)), vp9: \(VideoConverter.canTranscodeVP9) });
      """
    contentController.addUserScript(WKUserScript(source: hardwareDecode, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    if let bootstrapUrl = Bundle.main.url(forResource: "Bootstrap", withExtension: "js"),
       let bootstrap = try? String(contentsOf: bootstrapUrl, encoding: .utf8) {
      contentController.addUserScript(WKUserScript(source: bootstrap, injectionTime: .atDocumentStart, forMainFrameOnly: true))
    }
    let bridge = NativeBridge()
    bridge.presenter = self
    contentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "ftIOS")
    contentController.add(WeakMessageHandler(self), name: "ftTheme")
    contentController.add(WeakMessageHandler(self), name: "ftNav")
    contentController.add(WeakMessageHandler(self), name: "ftResumePlayback")

    webView = WKWebView(frame: .zero, configuration: configuration)
    webView.customUserAgent = NetworkProxy.userAgent
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsLinkPreview = false
    webView.allowsBackForwardNavigationGestures = true
    webView.isOpaque = false
    webView.backgroundColor = .clear
    webView.scrollView.backgroundColor = .clear
    webView.scrollView.contentInsetAdjustmentBehavior = .never
    webView.scrollView.keyboardDismissMode = .interactive
    // Pull down at the top: refreshes the feed, or leaves the video (it keeps playing in the mini player)
    let refreshControl = UIRefreshControl()
    refreshControl.addTarget(self, action: #selector(pullToRefresh(_:)), for: .valueChanged)
    webView.scrollView.refreshControl = refreshControl
    #if DEBUG
    webView.isInspectable = true
    #endif

    chrome.delegate = self
    chrome.attach(to: webView.scrollView)
    chrome.onBarMinimizedChange = { [weak self] minimized in
      guard let self else { return }
      self.webView.evaluateJavaScript("window.__ftSetBarMinimized?.(\(minimized))")
      self.updateMiniPlayerPosition(animated: true)
    }
    MediaPlayback.shared.onStart = { [weak self] in
      // only one thing plays at a time
      self?.webView.evaluateJavaScript("window.__ftStopWebMedia?.()")
    }
    DownloadManager.shared.onStateChange = { [weak self] state in
      self?.chrome.showDownload(state)
    }
    DownloadManager.shared.onOpenDownloads = { [weak self] kind in
      self?.downloads.show(kind)
      self?.setShowingDownloads(true)
    }

    addChild(downloads)
    downloads.view.isHidden = true
    for subview in [webView!, downloads.view!, chrome] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(subview)
      NSLayoutConstraint.activate([
        subview.topAnchor.constraint(equalTo: root.topAnchor),
        subview.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        subview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
        subview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      ])
    }

    canGoBackObservation = webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] webView, _ in
      MainActor.assumeIsolated {
        self?.chrome.canGoBack = webView.canGoBack
      }
    }
    scrollObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
      MainActor.assumeIsolated {
        guard self?.chrome.isShowingDownloads == false else { return }
        self?.chrome.scrollViewDidScroll(offset: scrollView.contentOffset.y, userInitiated: scrollView.isTracking || scrollView.isDecelerating)
      }
    }
    let miniPlayer = MediaPlayback.shared.miniPlayer
    miniPlayer.translatesAutoresizingMaskIntoConstraints = false
    root.insertSubview(miniPlayer, belowSubview: chrome)
    miniPlayerBottom = miniPlayer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
    NSLayoutConstraint.activate([
      miniPlayer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: NativeChrome.sideMargin),
      miniPlayer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -NativeChrome.sideMargin),
      miniPlayerBottom,
    ])
    updateMiniPlayerPosition(animated: false)

    downloads.didMove(toParent: self)
    downloadsScrollObservation = downloads.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
      MainActor.assumeIsolated {
        guard self?.chrome.isShowingDownloads == true else { return }
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        self?.chrome.scrollViewDidScroll(offset: offset, userInitiated: scrollView.isTracking || scrollView.isDecelerating)
      }
    }
  }

  /// Shows or hides the native Downloads screen over the web app
  private func setShowingDownloads(_ showing: Bool) {
    guard showing != chrome.isShowingDownloads else { return }
    chrome.setShowingDownloads(showing)
    chrome.attach(to: showing ? downloads.scrollView : webView.scrollView)
    webView.allowsBackForwardNavigationGestures = !showing
    webView.accessibilityElementsHidden = showing

    if showing {
      downloads.view.alpha = 0
      downloads.view.isHidden = false
    }
    UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState]) {
      self.downloads.view.alpha = showing ? 1 : 0
    } completion: { _ in
      if !self.chrome.isShowingDownloads {
        self.downloads.view.isHidden = true
      }
    }
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    UIDevice.current.beginGeneratingDeviceOrientationNotifications()
    NotificationCenter.default.addObserver(self, selector: #selector(deviceOrientationDidChange), name: UIDevice.orientationDidChangeNotification, object: nil)
    // WebKit decides whether media may keep playing at the moment the app goes to the background, see BackgroundPlayback
    let notifications: [(Notification.Name, String)] = [
      (UIApplication.willResignActiveNotification, "willResignActive"),
      (UIApplication.didEnterBackgroundNotification, "didEnterBackground"),
      (UIApplication.didBecomeActiveNotification, "didBecomeActive"),
    ]
    for (name, event) in notifications {
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.webView.evaluateJavaScript("window.__ftAppStateChanged?.('\(event)')")
        }
      }
    }
    webView.load(URLRequest(url: URL(string: "\(AppSchemeHandler.origin)/index.html")!))
  }

  @objc private func pullToRefresh(_ sender: UIRefreshControl) {
    Task { @MainActor in
      let onWatchPage = (try? await webView.evaluateJavaScript("location.hash.startsWith('#/watch/')")) as? Bool ?? false
      if onWatchPage {
        if webView.canGoBack {
          webView.goBack()
        }
      } else {
        _ = try? await webView.evaluateJavaScript("document.querySelector('.floatingRefreshSection .refreshButton:not([disabled])')?.click()")
      }
      try? await Task.sleep(for: .milliseconds(700))
      sender.endRefreshing()
    }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    updateContentInsets()
  }

  /// Tells the page how much space the native controls take up, see src/renderer/ios.css
  private func updateContentInsets(force: Bool = false) {
    let insets = chrome.contentInsets
    if !force, let lastInsets, lastInsets == insets { return }
    lastInsets = insets
    downloads.contentInsets = insets
    updateMiniPlayerPosition(animated: false)
    webView.evaluateJavaScript("window.__ftSetInsets?.(\(insets.top), \(insets.bottom))")
  }

  /// The mini player sits above the tab bar, and goes down with it when it is hidden
  private func updateMiniPlayerPosition(animated: Bool) {
    guard miniPlayerBottom != nil else { return }
    let inset = chrome.isBarMinimized ? view.safeAreaInsets.bottom + 10 : chrome.contentInsets.bottom - 4
    miniPlayerBottom.constant = -inset
    if animated {
      UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.88, initialSpringVelocity: 0.2, options: [.beginFromCurrentState]) {
        self.view.layoutIfNeeded()
      }
    }
  }

  /// Runs one of the functions exposed by the iOS region in src/renderer/components/TopNav/TopNav.vue
  @discardableResult
  private func callApp(_ function: String, _ argument: String) async -> Any? {
    try? await webView.callAsyncJavaScript(
      "return await window.ftIOSApp?.\(function)(argument)",
      arguments: ["argument": argument],
      contentWorld: .page
    )
  }

  override func present(_ viewControllerToPresent: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
    viewControllerToPresent.overrideUserInterfaceStyle = themeInterfaceStyle
    viewControllerToPresent.view.tintColor = chrome.tintColor
    super.present(viewControllerToPresent, animated: flag, completion: completion)
  }

  // MARK: - Theme

  fileprivate func applyThemeColors(_ json: String) {
    guard
      let data = json.data(using: .utf8),
      let colors = try? JSONSerialization.jsonObject(with: data) as? [String: String],
      let page = colors["page"].flatMap(UIColor.init(cssColor:))
    else { return }

    pageColor = page
    if !isPlayerFullscreen {
      view.backgroundColor = page
      // the area the web view shows while it is being resized, e.g. when the screen rotates
      webView.underPageBackgroundColor = page
    }
    downloads.view.backgroundColor = page
    chrome.applyTheme(page: page, accent: colors["accent"].flatMap(UIColor.init(cssColor:)))

    themeInterfaceStyle = page.isLight ? .light : .dark
    downloads.overrideUserInterfaceStyle = themeInterfaceStyle
    // menus and alerts take the appearance of the window
    view.window?.overrideUserInterfaceStyle = colors["followsSystem"] == "true" ? .unspecified : themeInterfaceStyle
    downloads.view.tintColor = chrome.tintColor
    MediaPlayback.shared.miniPlayer.tintColor = chrome.tintColor

    let newStyle: UIStatusBarStyle = page.isLight ? .darkContent : .lightContent
    if newStyle != statusBarStyle {
      statusBarStyle = newStyle
      UIView.animate(withDuration: 0.25) { self.setNeedsStatusBarAppearanceUpdate() }
    }
  }

  // MARK: - Links

  fileprivate func openExternally(_ url: URL) {
    guard let scheme = url.scheme?.lowercased() else { return }
    if scheme == "http" || scheme == "https" {
      let safari = SFSafariViewController(url: url)
      safari.dismissButtonStyle = .close
      present(safari, animated: true)
    } else if ["mailto", "tel", "sms", "itms-apps", "maps"].contains(scheme) {
      UIApplication.shared.open(url)
    }
  }

  // MARK: - Downloads

  fileprivate func export(_ fileUrl: URL) {
    let picker = UIDocumentPickerViewController(forExporting: [fileUrl], asCopy: true)
    present(picker, animated: true)
  }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {
  func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    if navigationAction.shouldPerformDownload {
      decisionHandler(.download, preferences)
      return
    }

    guard let url = navigationAction.request.url, let scheme = url.scheme?.lowercased() else {
      decisionHandler(.cancel, preferences)
      return
    }

    let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true

    if scheme == AppSchemeHandler.scheme {
      decisionHandler(.allow, preferences)
    } else if !isMainFrame && (scheme == "data" || scheme == "about" || scheme == "blob") {
      // the sandboxed iframe for the signature deciphering (sigFrame in src/index.ejs)
      decisionHandler(.allow, preferences)
    } else if scheme == "blob" {
      decisionHandler(.download, preferences)
    } else {
      decisionHandler(.cancel, preferences)
      if navigationAction.navigationType == .linkActivated || isMainFrame {
        openExternally(url)
      }
    }
  }

  func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
  }

  func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
    download.delegate = self
  }

  func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
    download.delegate = self
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    updateContentInsets(force: true)
  }

  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    webView.reload()
  }
}

// MARK: - WKDownloadDelegate

extension WebViewController: WKDownloadDelegate {
  func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
    // The web app percent-encodes the file name of the download links (see writeFileWithPicker in src/renderer/helpers/utils.js)
    var filename = suggestedFilename.removingPercentEncoding ?? suggestedFilename
    filename = filename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    if filename.isEmpty {
      filename = "download"
    }

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let destination = directory.appendingPathComponent(filename)
    pendingDownloadDestinations[ObjectIdentifier(download)] = destination
    completionHandler(destination)
  }

  func downloadDidFinish(_ download: WKDownload) {
    guard let destination = pendingDownloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
    export(destination)
  }

  func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
    pendingDownloadDestinations.removeValue(forKey: ObjectIdentifier(download))
  }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {
  func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
    // window.open, used for external links (openExternalLink in src/renderer/helpers/utils.js)
    if let url = navigationAction.request.url {
      if url.scheme == AppSchemeHandler.scheme {
        webView.load(URLRequest(url: url))
      } else {
        openExternally(url)
      }
    }
    return nil
  }

  func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
    present(alert, animated: true)
  }

  func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
    present(alert, animated: true)
  }

  func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
    let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
    alert.addTextField { $0.text = defaultText }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(alert.textFields?.first?.text) })
    present(alert, animated: true)
  }

  func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
    decisionHandler(.deny)
  }
}

// MARK: - Script message handlers

extension WebViewController: WKScriptMessageHandler {
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    guard let json = message.body as? String else { return }
    switch message.name {
    case "ftResumePlayback":
      BackgroundPlayback.resume(webView)
    case "ftTheme":
      applyThemeColors(json)
    case "ftNav":
      if let data = json.data(using: .utf8), let state = try? JSONDecoder().decode(ChromeState.self, from: data) {
        chrome.apply(state)
      }
    default:
      break
    }
  }
}

/// Avoids the retain cycle between the user content controller and the view controller
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
  weak var target: WKScriptMessageHandler?

  init(_ target: WKScriptMessageHandler) {
    self.target = target
  }

  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    target?.userContentController(userContentController, didReceive: message)
  }
}

/// Handles the calls to `window.ftIOS` (see Bootstrap.js)
private final class NativeBridge: NSObject, WKScriptMessageHandlerWithReply {
  weak var presenter: UIViewController?
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
    guard
      message.frameInfo.isMainFrame,
      message.frameInfo.securityOrigin.protocol == AppSchemeHandler.scheme,
      let body = message.body as? [String: Any],
      let action = body["action"] as? String
    else {
      replyHandler(nil, "Invalid message")
      return
    }

    switch action {
    case "generatePoToken":
      guard let args = body["args"] as? [String], args.count == 4 else {
        replyHandler(nil, "Invalid arguments")
        return
      }
      Task { @MainActor in
        do {
          let token = try await PoTokenGenerator.shared.generate(videoId: args[0], context: args[1], initialAttestationData: args[2], ytConfig: args[3])
          replyHandler(token, nil)
        } catch {
          replyHandler(nil, error.localizedDescription)
        }
      }
    case "chooseDownloadQuality":
      guard
        let json = (body["args"] as? [String])?.first,
        let qualities = try? JSONDecoder().decode(DownloadQualityOptions.self, from: Data(json.utf8)),
        let presenter
      else {
        replyHandler(nil, "Invalid arguments")
        return
      }
      let picker = DownloadQualityViewController(qualities: qualities) { id in
        replyHandler(id, nil)
      }
      let navigation = UINavigationController(rootViewController: picker)
      if let sheet = navigation.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      }
      presenter.present(navigation, animated: true)
    case "beginDownload":
      guard
        let json = (body["args"] as? [String])?.first,
        let request = try? JSONDecoder().decode(DownloadManager.Request.self, from: Data(json.utf8))
      else {
        replyHandler(nil, "Invalid arguments")
        return
      }
      do {
        try DownloadManager.shared.begin(request)
        replyHandler(true, nil)
      } catch {
        replyHandler(nil, error.localizedDescription)
      }
    case "finishDownload":
      guard let id = (body["args"] as? [String])?.first else {
        replyHandler(nil, "Invalid arguments")
        return
      }
      DownloadManager.shared.finish(id: id)
      replyHandler(true, nil)
    case "setPlayerFullscreen":
      (presenter as? WebViewController)?.setPlayerFullscreen((body["args"] as? [String])?.first == "true")
      replyHandler(true, nil)
    case "webMediaPlaying":
      MediaPlayback.shared.stop()
      replyHandler(true, nil)
    case "setOrientation":
      (presenter as? WebViewController)?.setOrientation((body["args"] as? [String])?.first ?? "auto")
      replyHandler(true, nil)
    case "failDownload":
      guard let args = body["args"] as? [String], args.count == 2 else {
        replyHandler(nil, "Invalid arguments")
        return
      }
      DownloadManager.shared.fail(id: args[0], message: args[1])
      replyHandler(true, nil)
    default:
      replyHandler(nil, "Unknown action \(action)")
    }
  }
}

// MARK: - NativeChromeDelegate

extension WebViewController: NativeChromeDelegate {
  func chrome(_ chrome: NativeChrome, navigateTo path: String) {
    setShowingDownloads(false)
    Task { await callApp("navigate", path) }
  }

  func chrome(_ chrome: NativeChrome, showDownloads: Bool) {
    setShowingDownloads(showDownloads)
  }

  func chromeGoBack(_ chrome: NativeChrome) {
    Task {
      // On narrow screens the settings sections are opened inside the settings page, close that first
      let closedSettingsSection = try? await webView.evaluateJavaScript("""
        (() => {
          const button = document.querySelector('.returnToMenuMobileButton')
          if (button && button.parentElement.style.display !== 'none') {
            button.click()
            return true
          }
          return false
        })()
      """) as? Bool
      if closedSettingsSection != true {
        webView.goBack()
      }
    }
  }

  func chrome(_ chrome: NativeChrome, search query: String) {
    setShowingDownloads(false)
    Task { await callApp("search", query) }
  }

  func chrome(_ chrome: NativeChrome, suggestionsFor query: String) async -> (items: [String], removableCount: Int)? {
    guard
      let result = await callApp("suggestions", query) as? [String: Any],
      let items = result["items"] as? [String]
    else { return nil }
    return (items, (result["removableCount"] as? Int) ?? 0)
  }

  func chrome(_ chrome: NativeChrome, removeSearchHistoryEntry query: String) {
    Task { await callApp("removeSearchHistoryEntry", query) }
  }

  func chrome(_ chrome: NativeChrome, setActiveProfile id: String) {
    Task { await callApp("setActiveProfile", id) }
  }

  func chromeShowSearchFilters(_ chrome: NativeChrome) {
    Task { @MainActor [weak self] in
      guard let self else { return }
      guard
        let json = await self.callApp("getSearchFilters", "") as? String,
        let sections = try? JSONDecoder().decode([SearchFiltersViewController.Section].self, from: Data(json.utf8))
      else { return }

      let filters = SearchFiltersViewController(sections: sections, onChange: { [weak self] key, value in
        guard
          let self,
          let change = try? String(data: JSONSerialization.data(withJSONObject: ["key": key, "value": value]), encoding: .utf8),
          let json = await self.callApp("setSearchFilter", change) as? String
        else { return nil }
        return try? JSONDecoder().decode([SearchFiltersViewController.Section].self, from: Data(json.utf8))
      }, onDone: { [weak self] in
        Task { await self?.callApp("applySearchFilters", "") }
      })
      let navigation = UINavigationController(rootViewController: filters)
      if let sheet = navigation.sheetPresentationController {
        sheet.detents = [.medium(), .large()]
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = true
      }
      // the keyboard of the search field would cover the sheet
      self.view.endEditing(true)
      self.present(navigation, animated: true)
    }
  }

  func chromeScrollToTop(_ chrome: NativeChrome) {
    if chrome.isShowingDownloads {
      let scrollView = downloads.scrollView
      scrollView.setContentOffset(CGPoint(x: 0, y: -scrollView.adjustedContentInset.top), animated: true)
      return
    }
    webView.evaluateJavaScript("window.scrollTo({ top: 0, behavior: 'smooth' })")
  }
}

// MARK: - Background playback

/// Keeps the media playing when the app is in the background or the screen is locked.
/// WebKit pauses the media of web views that aren't visible, these WebKit preferences and methods are private,
/// so they are only used when they exist.
enum BackgroundPlayback {
  static func configure(_ preferences: WKPreferences) {
    setBool(preferences, "_setRequiresPageVisibilityToPlayAudio:", false)
    setBool(preferences, "_setInterruptAudioOnPageVisibilityChangeEnabled:", false)
  }

  /// Called by Bootstrap.js when the media was paused because the app went to the background
  @MainActor
  static func resume(_ webView: WKWebView) {
    let selector = NSSelectorFromString("_playPredominantOrNowPlayingMediaSession:")
    if webView.responds(to: selector) {
      typealias Function = @convention(c) (AnyObject, Selector, @escaping @convention(block) (Bool) -> Void) -> Void
      let function = unsafeBitCast(webView.method(for: selector), to: Function.self)
      function(webView, selector) { _ in }
      return
    }
    let fallback = NSSelectorFromString("_resumeAllMediaPlayback")
    if webView.responds(to: fallback) {
      webView.perform(fallback)
    }
  }

  private static func setBool(_ object: NSObject, _ name: String, _ value: Bool) {
    let selector = NSSelectorFromString(name)
    guard object.responds(to: selector) else { return }
    typealias Function = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(object.method(for: selector), to: Function.self)(object, selector, value)
  }
}
