import AVKit
import UIKit

/// The Downloads tab: the downloaded videos and audio, which play in the native player.
/// Long pressing an item shares it (WhatsApp, Files, AirDrop...), swiping it deletes it.
final class DownloadsViewController: UIViewController {
  private enum Section { case main }

  private let kindControl = UISegmentedControl(items: ["Video", "Audio"])
  private let header = UIStackView()
  private var headerTop: NSLayoutConstraint!
  private var collectionView: UICollectionView!
  private var dataSource: UICollectionViewDiffableDataSource<Section, DownloadLibrary.Item>!
  private let thumbnailCache = NSCache<NSString, UIImage>()

  /// Space taken up by the native controls above and below, see NativeChrome.contentInsets
  var contentInsets: (top: CGFloat, bottom: CGFloat) = (0, 0) {
    didSet { updateInsets() }
  }

  var scrollView: UIScrollView { collectionView }

  private var kind: DownloadLibrary.Kind {
    kindControl.selectedSegmentIndex == 1 ? .audio : .video
  }

  /// "3:33", "1:02:05"
  private static func formatDuration(_ seconds: Double) -> String? {
    guard seconds.isFinite, seconds > 0 else { return nil }
    let total = Int(seconds.rounded())
    let hours = total / 3600, minutes = total / 60 % 60, remainder = total % 60
    return hours > 0
      ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
      : String(format: "%d:%02d", minutes, remainder)
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
    configuration.backgroundColor = .clear
    configuration.showsSeparators = false
    configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
      guard let self, let item = self.dataSource.itemIdentifier(for: indexPath) else { return nil }
      let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, completion in
        self.confirmDelete(item, completion: completion)
      }
      delete.image = UIImage(systemName: "trash")
      return UISwipeActionsConfiguration(actions: [delete])
    }

    let layout = UICollectionViewCompositionalLayout { _, environment in
      let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
      section.interGroupSpacing = 8
      section.contentInsets.top = 4
      return section
    }

    collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
    collectionView.translatesAutoresizingMaskIntoConstraints = false
    collectionView.backgroundColor = .clear
    collectionView.contentInsetAdjustmentBehavior = .never
    collectionView.alwaysBounceVertical = true
    collectionView.delegate = self
    view.addSubview(collectionView)

    let titleLabel = UILabel()
    titleLabel.text = "Media"
    titleLabel.font = .systemFont(ofSize: 34, weight: .bold)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.accessibilityTraits = .header
    header.addArrangedSubview(titleLabel)
    header.addArrangedSubview(kindControl)
    header.axis = .vertical
    header.spacing = 12
    header.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(header)
    headerTop = header.topAnchor.constraint(equalTo: view.topAnchor)
    NSLayoutConstraint.activate([
      headerTop,
      header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
      header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
      kindControl.heightAnchor.constraint(equalToConstant: 36),
      collectionView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
      collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])

    let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, DownloadLibrary.Item> { [weak self] cell, _, item in
      self?.configure(cell, with: item)
    }
    dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
      collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: item)
    }

    kindControl.selectedSegmentIndex = 0
    kindControl.addAction(UIAction { [weak self] _ in
      UISelectionFeedbackGenerator().selectionChanged()
      self?.reload(animated: true)
    }, for: .valueChanged)

    NotificationCenter.default.addObserver(forName: DownloadLibrary.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.reload(animated: true) }
    }

    updateInsets()
    reload(animated: false)
  }

  func show(_ kind: DownloadLibrary.Kind) {
    loadViewIfNeeded()
    kindControl.selectedSegmentIndex = kind == .audio ? 1 : 0
    reload(animated: false)
  }

  private func updateInsets() {
    guard isViewLoaded else { return }
    headerTop.constant = contentInsets.top + 8
    collectionView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: contentInsets.bottom + 12, right: 0)
    collectionView.verticalScrollIndicatorInsets = UIEdgeInsets(top: 0, left: 0, bottom: contentInsets.bottom, right: 0)
  }

  private func reload(animated: Bool) {
    let items = DownloadLibrary.shared.items(of: kind)
    var snapshot = NSDiffableDataSourceSnapshot<Section, DownloadLibrary.Item>()
    snapshot.appendSections([.main])
    snapshot.appendItems(items)
    dataSource.apply(snapshot, animatingDifferences: animated)
    updateEmptyState(isEmpty: items.isEmpty)
  }

  private func updateEmptyState(isEmpty: Bool) {
    guard isEmpty else {
      collectionView.backgroundView = nil
      return
    }
    var empty = UIContentUnavailableConfiguration.empty()
    empty.image = UIImage(systemName: kind == .audio ? "waveform" : "arrow.down.circle")
    empty.text = kind == .audio ? "No Audio" : "No Videos"
    empty.secondaryText = kind == .audio
      ? "Audio you download appears here. Tap the download button of a video and choose Audio."
      : "Videos you download appear here and in your Photos library."
    collectionView.backgroundView = UIContentUnavailableView(configuration: empty)
  }

  // MARK: - Cells

  private func configure(_ cell: UICollectionViewListCell, with item: DownloadLibrary.Item) {
    var content = UIListContentConfiguration.subtitleCell()
    content.text = item.title
    content.textProperties.font = .systemFont(ofSize: 16, weight: .semibold)
    content.textProperties.numberOfLines = 2

    let size = ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file)
    var details = [item.author, item.quality, size].filter { !$0.isEmpty }
    if let duration = DownloadsViewController.formatDuration(item.durationSeconds) {
      details.insert(duration, at: 0)
    }
    content.secondaryText = details.joined(separator: " · ")
    content.secondaryTextProperties.color = .secondaryLabel
    content.secondaryTextProperties.font = .systemFont(ofSize: 13)
    content.secondaryTextProperties.numberOfLines = 2
    content.textToSecondaryTextVerticalPadding = 4

    let imageSize = item.kind == .video ? CGSize(width: 128, height: 72) : CGSize(width: 64, height: 64)
    content.image = thumbnail(for: item) ?? UIImage(systemName: item.kind == .video ? "film" : "music.note")
    content.imageProperties.reservedLayoutSize = imageSize
    content.imageProperties.maximumSize = imageSize
    content.imageProperties.cornerRadius = item.kind == .video ? 10 : 12
    content.imageProperties.tintColor = .secondaryLabel
    content.imageToTextPadding = 14
    content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
    cell.contentConfiguration = content

    // a slightly lighter black than the background with a hairline border on dark themes, like the cards of the web app (src/renderer/ios.css)
    var background = UIBackgroundConfiguration.listCell()
    background.backgroundColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x13 / 255, alpha: 1) : UIColor.label.withAlphaComponent(0.05) }
    background.strokeColor = UIColor { $0.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.09) : .clear }
    background.strokeWidth = 0.5
    background.cornerRadius = 18
    cell.backgroundConfiguration = background

    cell.accessories = [.disclosureIndicator(displayed: .always, options: .init(tintColor: .tertiaryLabel))]
  }

  private func thumbnail(for item: DownloadLibrary.Item) -> UIImage? {
    if let cached = thumbnailCache.object(forKey: item.id as NSString) {
      return cached
    }
    guard let url = DownloadLibrary.shared.thumbnailURL(for: item), let image = UIImage(contentsOfFile: url.path) else {
      return nil
    }

    // crop to the shape of the cell, YouTube's thumbnails are 16:9 with black bars for the smaller sizes
    let target = item.kind == .video ? CGSize(width: 256, height: 144) : CGSize(width: 128, height: 128)
    let scale = max(target.width / image.size.width, target.height / image.size.height)
    let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
    let rendered = UIGraphicsImageRenderer(size: target).image { _ in
      image.draw(in: CGRect(x: (target.width - drawSize.width) / 2, y: (target.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
    }
    thumbnailCache.setObject(rendered, forKey: item.id as NSString)
    return rendered
  }

  // MARK: - Actions

  private func play(_ item: DownloadLibrary.Item) {
    let url = DownloadLibrary.shared.fileURL(for: item)
    let playerItem = AVPlayerItem(url: url)

    // the lock screen and Control Center show the title, the channel and the artwork
    var metadata: [AVMetadataItem] = []
    func add(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) {
      let entry = AVMutableMetadataItem()
      entry.identifier = identifier
      entry.value = value
      entry.extendedLanguageTag = "und"
      metadata.append(entry)
    }
    add(.commonIdentifierTitle, item.title as NSString)
    add(.commonIdentifierArtist, item.author as NSString)
    if let thumbnail = DownloadLibrary.shared.thumbnailURL(for: item), let data = try? Data(contentsOf: thumbnail) {
      add(.commonIdentifierArtwork, data as NSData)
    }
    playerItem.externalMetadata = metadata

    let player = AVPlayer(playerItem: playerItem)
    let controller = MediaPlayerViewController()
    controller.player = player
    controller.allowsPictureInPicturePlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    controller.updatesNowPlayingInfoCenter = true

    if item.kind == .audio, let overlay = controller.contentOverlayView {
      addArtwork(for: item, to: overlay)
    }

    MediaPlayback.shared.present(item, controller: controller, player: player, from: self)
  }

  /// The audio player shows the artwork over a blurred version of it
  private func addArtwork(for item: DownloadLibrary.Item, to overlay: UIView) {
    guard let url = DownloadLibrary.shared.thumbnailURL(for: item), let image = UIImage(contentsOfFile: url.path) else { return }

    let background = UIImageView(image: image)
    background.contentMode = .scaleAspectFill
    background.clipsToBounds = true
    let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterialDark))
    let artwork = UIImageView(image: image)
    artwork.contentMode = .scaleAspectFill
    artwork.clipsToBounds = true
    artwork.layer.cornerRadius = 20
    artwork.layer.cornerCurve = .continuous

    for subview in [background, blur, artwork] {
      subview.translatesAutoresizingMaskIntoConstraints = false
      overlay.addSubview(subview)
    }
    NSLayoutConstraint.activate([
      background.topAnchor.constraint(equalTo: overlay.topAnchor),
      background.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
      background.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
      background.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      blur.topAnchor.constraint(equalTo: overlay.topAnchor),
      blur.bottomAnchor.constraint(equalTo: overlay.bottomAnchor),
      blur.leadingAnchor.constraint(equalTo: overlay.leadingAnchor),
      blur.trailingAnchor.constraint(equalTo: overlay.trailingAnchor),
      artwork.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
      artwork.centerYAnchor.constraint(equalTo: overlay.centerYAnchor, constant: -30),
      artwork.widthAnchor.constraint(equalTo: overlay.widthAnchor, multiplier: 0.72),
      artwork.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
      artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor, multiplier: 9.0 / 16.0),
    ])
  }

  private func share(_ item: DownloadLibrary.Item, from sourceView: UIView?) {
    // share a copy with a readable name, the library uses ids
    let source = DownloadLibrary.shared.fileURL(for: item)
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
    var name = item.title.components(separatedBy: invalid).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    if name.isEmpty { name = item.kind == .audio ? "Audio" : "Video" }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Share", isDirectory: true)
      .appendingPathComponent(item.id, isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let shared = directory.appendingPathComponent(String(name.prefix(120))).appendingPathExtension(source.pathExtension)
    if !FileManager.default.fileExists(atPath: shared.path) {
      // a hard link doesn't take up any more space
      if (try? FileManager.default.linkItem(at: source, to: shared)) == nil {
        try? FileManager.default.copyItem(at: source, to: shared)
      }
    }

    let activity = UIActivityViewController(activityItems: [shared], applicationActivities: nil)
    activity.popoverPresentationController?.sourceView = sourceView ?? view
    activity.completionWithItemsHandler = { _, _, _, _ in
      try? FileManager.default.removeItem(at: directory)
    }
    present(activity, animated: true)
  }

  private func confirmDelete(_ item: DownloadLibrary.Item, completion: ((Bool) -> Void)? = nil) {
    let alert = UIAlertController(
      title: "Delete \(item.kind == .audio ? "Audio" : "Video")?",
      message: item.kind == .video ? "It stays in your Photos library." : nil,
      preferredStyle: .actionSheet
    )
    alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
      DownloadLibrary.shared.delete(item)
      completion?(true)
    })
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completion?(false) })
    alert.popoverPresentationController?.sourceView = view
    alert.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
    present(alert, animated: true)
  }
}

// MARK: - UICollectionViewDelegate

extension DownloadsViewController: UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    collectionView.deselectItem(at: indexPath, animated: true)
    guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
    play(item)
  }

  func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first, let item = dataSource.itemIdentifier(for: indexPath) else { return nil }
    let cell = collectionView.cellForItem(at: indexPath)

    return UIContextMenuConfiguration(identifier: item.id as NSString, previewProvider: nil) { [weak self] _ in
      guard let self else { return nil }
      return UIMenu(children: [
        UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in self.play(item) },
        UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in self.share(item, from: cell) },
        UIMenu(options: .displayInline, children: [
          UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in self.confirmDelete(item) },
        ]),
      ])
    }
  }
}
