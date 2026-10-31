import AVKit
import UIKit

/// Plays the downloaded videos and audio. When the player is closed the playback goes on
/// in a mini player above the tab bar (tap it to open the player again), like YouTube's app.
@MainActor
final class MediaPlayback: NSObject {
  static let shared = MediaPlayback()

  let miniPlayer = MiniMediaPlayerView()
  /// Called when something starts playing, the web app's own video is paused
  var onStart: (() -> Void)?

  private(set) var item: DownloadLibrary.Item?
  private var player: AVPlayer?
  private var controller: MediaPlayerViewController?
  private var endObserver: NSObjectProtocol?

  override private init() {
    super.init()
    miniPlayer.onExpand = { [weak self] in self?.expand() }
    miniPlayer.onClose = { [weak self] in self?.stop() }
  }

  /// Opens the player, with the playback of the item starting if it isn't the one already playing
  func present(_ item: DownloadLibrary.Item, controller: MediaPlayerViewController, player: AVPlayer, from presenter: UIViewController) {
    stop()

    self.item = item
    self.player = player
    self.controller = controller
    controller.onDismiss = { [weak self] wasPlaying in
      self?.playerWasDismissed(wasPlaying: wasPlaying)
    }
    endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.stop() }
    }

    onStart?()
    presenter.present(controller, animated: true) {
      player.play()
    }
  }

  /// The mini player was tapped
  private func expand() {
    guard let controller, let presenter = miniPlayer.window?.rootViewController else { return }
    var top = presenter
    while let presented = top.presentedViewController { top = presented }
    miniPlayer.setVisible(false, animated: true)
    top.present(controller, animated: true)
  }

  private func playerWasDismissed(wasPlaying: Bool) {
    guard let player, let item else { return }
    // closing the player must not stop the playback, the system's player can pause it a moment after it's gone
    if wasPlaying {
      player.play()
      Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(400))
        if let self, self.player === player, player.timeControlStatus == .paused {
          player.play()
        }
      }
    }

    var thumbnail: UIImage?
    if let url = DownloadLibrary.shared.thumbnailURL(for: item) {
      thumbnail = UIImage(contentsOfFile: url.path)
    }
    miniPlayer.configure(
      title: item.title,
      subtitle: item.author,
      thumbnail: thumbnail,
      player: player,
      showsVideo: item.kind == .video
    )
    miniPlayer.setVisible(true, animated: true)
  }

  /// Stops the playback and closes the mini player
  func stop() {
    if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    endObserver = nil

    miniPlayer.setVisible(false, animated: true)
    miniPlayer.configure(title: "", subtitle: "", thumbnail: nil, player: nil, showsVideo: false)

    player?.pause()
    player?.replaceCurrentItem(with: nil)
    controller?.onDismiss = nil
    if controller?.presentingViewController != nil {
      controller?.dismiss(animated: true)
    }
    controller?.player = nil
    controller = nil
    player = nil
    item = nil
  }
}

/// The system's player, which tells when it is closed
final class MediaPlayerViewController: AVPlayerViewController {
  var onDismiss: ((_ wasPlaying: Bool) -> Void)?
  private var wasPlaying = true
  private var isPlaying = true
  private var wasPlayingBeforeChange = true
  private var lastChange = Date.distantPast
  private var statusObservation: NSKeyValueObservation?

  override var player: AVPlayer? {
    didSet {
      statusObservation = player?.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
        MainActor.assumeIsolated {
          guard let self, !self.isBeingDismissed else { return }
          self.wasPlayingBeforeChange = self.isPlaying
          self.isPlaying = player.timeControlStatus != .paused
          self.lastChange = Date()
        }
      }
    }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    guard isBeingDismissed else { return }
    // closing the player pauses the video, which isn't the user pausing it
    let pausedByClosing = !isPlaying && Date().timeIntervalSince(lastChange) < 1.5
    wasPlaying = pausedByClosing ? wasPlayingBeforeChange : isPlaying
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed {
      onDismiss?(wasPlaying)
    }
  }
}

/// A Liquid Glass bar with the video (or the artwork), its title and the play/pause and close buttons
final class MiniMediaPlayerView: UIView {
  var onExpand: (() -> Void)?
  var onClose: (() -> Void)?

  static let height: CGFloat = 60

  private let glass = UIVisualEffectView()
  private let videoView = PlayerLayerView()
  private let artworkView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let playButton = UIButton(type: .system)
  private let closeButton = UIButton(type: .system)
  private let progressView = UIView()
  private var progressWidth: NSLayoutConstraint?

  private weak var player: AVPlayer?
  private var timeObserver: Any?
  private var statusObservation: NSKeyValueObservation?
  private var isShown = false

  override init(frame: CGRect) {
    super.init(frame: frame)
    setUp()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setUp() {
    alpha = 0
    isHidden = true

    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = true
    glass.effect = effect
    glass.cornerConfiguration = .capsule()
    glass.translatesAutoresizingMaskIntoConstraints = false
    addSubview(glass)

    let content = glass.contentView

    let thumbnail = UIView()
    thumbnail.layer.cornerRadius = 14
    thumbnail.layer.cornerCurve = .continuous
    thumbnail.clipsToBounds = true
    thumbnail.backgroundColor = .black
    thumbnail.translatesAutoresizingMaskIntoConstraints = false
    for subview in [artworkView, videoView] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      thumbnail.addSubview(subview)
      NSLayoutConstraint.activate([
        subview.topAnchor.constraint(equalTo: thumbnail.topAnchor),
        subview.bottomAnchor.constraint(equalTo: thumbnail.bottomAnchor),
        subview.leadingAnchor.constraint(equalTo: thumbnail.leadingAnchor),
        subview.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor),
      ])
    }
    artworkView.contentMode = .scaleAspectFill
    artworkView.clipsToBounds = true

    titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
    titleLabel.textColor = .label
    subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
    subtitleLabel.textColor = .secondaryLabel
    let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    labels.axis = .vertical
    labels.spacing = 1
    labels.translatesAutoresizingMaskIntoConstraints = false
    labels.isUserInteractionEnabled = false

    func configure(_ button: UIButton, symbol: String, label: String, action: @escaping () -> Void) {
      var configuration = UIButton.Configuration.plain()
      configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
      configuration.baseForegroundColor = .label
      button.configuration = configuration
      button.accessibilityLabel = label
      button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
      button.translatesAutoresizingMaskIntoConstraints = false
    }
    configure(playButton, symbol: "pause.fill", label: "Pause") { [weak self] in self?.togglePlayback() }
    configure(closeButton, symbol: "xmark", label: "Close") { [weak self] in self?.onClose?() }

    let expandButton = UIButton(type: .custom)
    expandButton.translatesAutoresizingMaskIntoConstraints = false
    expandButton.accessibilityLabel = "Open player"
    expandButton.addAction(UIAction { [weak self] _ in self?.onExpand?() }, for: .primaryActionTriggered)

    progressView.backgroundColor = tintColor
    progressView.layer.cornerRadius = 1
    progressView.translatesAutoresizingMaskIntoConstraints = false

    for subview in [expandButton, thumbnail, labels, playButton, closeButton, progressView] {
      content.addSubview(subview)
    }

    NSLayoutConstraint.activate([
      glass.topAnchor.constraint(equalTo: topAnchor),
      glass.bottomAnchor.constraint(equalTo: bottomAnchor),
      glass.leadingAnchor.constraint(equalTo: leadingAnchor),
      glass.trailingAnchor.constraint(equalTo: trailingAnchor),
      heightAnchor.constraint(equalToConstant: MiniMediaPlayerView.height),

      expandButton.topAnchor.constraint(equalTo: content.topAnchor),
      expandButton.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      expandButton.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      expandButton.trailingAnchor.constraint(equalTo: content.trailingAnchor),

      thumbnail.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
      thumbnail.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      thumbnail.heightAnchor.constraint(equalToConstant: 44),
      thumbnail.widthAnchor.constraint(equalToConstant: 78),

      labels.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 10),
      labels.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      labels.trailingAnchor.constraint(equalTo: playButton.leadingAnchor, constant: -4),

      playButton.widthAnchor.constraint(equalToConstant: 40),
      playButton.heightAnchor.constraint(equalToConstant: 40),
      playButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      playButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor),

      closeButton.widthAnchor.constraint(equalToConstant: 40),
      closeButton.heightAnchor.constraint(equalToConstant: 40),
      closeButton.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),

      progressView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      progressView.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -2),
      progressView.heightAnchor.constraint(equalToConstant: 2),
    ])
    progressWidth = progressView.widthAnchor.constraint(equalToConstant: 0)
    progressWidth?.isActive = true
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    progressView.backgroundColor = tintColor
  }

  func configure(title: String, subtitle: String, thumbnail: UIImage?, player: AVPlayer?, showsVideo: Bool) {
    if let timeObserver, let old = self.player {
      old.removeTimeObserver(timeObserver)
    }
    timeObserver = nil
    statusObservation = nil
    videoView.playerLayer.player = nil

    titleLabel.text = title
    subtitleLabel.text = subtitle
    artworkView.image = thumbnail
    self.player = player
    progressWidth?.constant = 0

    guard let player else { return }
    videoView.isHidden = !showsVideo
    if showsVideo { videoView.playerLayer.player = player }

    statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
      MainActor.assumeIsolated { self?.updatePlayButton(player.timeControlStatus != .paused) }
    }
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
      MainActor.assumeIsolated { self?.updateProgress(time) }
    }
  }

  private func updatePlayButton(_ playing: Bool) {
    var configuration = playButton.configuration
    configuration?.image = UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
    playButton.configuration = configuration
    playButton.accessibilityLabel = playing ? "Pause" : "Play"
  }

  private func updateProgress(_ time: CMTime) {
    guard
      let duration = player?.currentItem?.duration.seconds, duration.isFinite, duration > 0,
      glass.bounds.width > 48
    else { return }
    let fraction = min(1, max(0, time.seconds / duration))
    progressWidth?.constant = (glass.bounds.width - 48) * fraction
  }

  private func togglePlayback() {
    guard let player else { return }
    if player.timeControlStatus == .paused {
      player.play()
    } else {
      player.pause()
    }
  }

  func setVisible(_ visible: Bool, animated: Bool) {
    guard visible != isShown else { return }
    isShown = visible
    if visible { isHidden = false }

    let changes = {
      self.alpha = visible ? 1 : 0
      self.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 16)
    }
    if animated {
      UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction], animations: changes) { _ in
        if !self.isShown { self.isHidden = true }
      }
    } else {
      changes()
      isHidden = !visible
    }
  }
}

private final class PlayerLayerView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer } // swiftlint:disable:this force_cast

  override init(frame: CGRect) {
    super.init(frame: frame)
    playerLayer.videoGravity = .resizeAspectFill
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}
