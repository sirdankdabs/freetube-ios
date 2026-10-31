import UIKit

// MARK: - Quality picker

/// The options built by downloadVideo in src/renderer/helpers/iosDownload.js
struct DownloadQualityOptions: Decodable {
  struct Option: Decodable {
    let id: String
    let height: Int?
    let width: Int?
    let fps: Int?
    let label: String
    let codec: String
    let mode: String
    let bytes: Double
    /// for audio, e.g. the language of a dubbed track
    let detail: String?
  }

  let title: String
  let options: [Option]
  let audioOptions: [Option]
}

/// A sheet listing the available video and audio qualities, the highest first.
/// Returns "video:<id>" or "audio:<id>".
final class DownloadQualityViewController: UITableViewController {
  private let qualities: DownloadQualityOptions
  private var completion: ((String?) -> Void)?
  private let kindControl = UISegmentedControl(items: ["Video", "Audio"])

  private var isAudio: Bool { kindControl.selectedSegmentIndex == 1 }
  private var visibleOptions: [DownloadQualityOptions.Option] { isAudio ? qualities.audioOptions : qualities.options }

  init(qualities: DownloadQualityOptions, completion: @escaping (String?) -> Void) {
    self.qualities = qualities
    self.completion = completion
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Download"
    navigationItem.largeTitleDisplayMode = .never

    kindControl.selectedSegmentIndex = qualities.options.isEmpty && !qualities.audioOptions.isEmpty ? 1 : 0
    kindControl.setEnabled(!qualities.options.isEmpty, forSegmentAt: 0)
    kindControl.setEnabled(!qualities.audioOptions.isEmpty, forSegmentAt: 1)
    kindControl.addAction(UIAction { [weak self] _ in
      UISelectionFeedbackGenerator().selectionChanged()
      self?.tableView.reloadSections(IndexSet(integer: 0), with: .fade)
    }, for: .valueChanged)
    navigationItem.titleView = kindControl
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
      self?.finish(with: nil)
    })
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "quality")
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 60
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    // dismissed by swiping down
    finish(with: nil)
  }

  private func finish(with id: String?) {
    guard let completion else { return }
    self.completion = nil
    completion(id)
    if presentingViewController != nil && !isBeingDismissed {
      dismiss(animated: true)
    }
  }

  override func numberOfSections(in tableView: UITableView) -> Int { 1 }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    visibleOptions.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    qualities.title
  }

  override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
    if isAudio {
      var footer = "The audio is saved as an M4A file in Media, where you can play it or share it with other apps."
      if qualities.audioOptions.contains(where: { $0.mode == "transcode" }) {
        footer += " Opus audio is converted to AAC on your device."
      }
      return footer
    }
    var footer = "The video is saved to Media and to your Photos library."
    if qualities.options.contains(where: { $0.mode == "transcode" }) {
      footer += " Qualities marked HEVC are converted on your device after downloading, which takes a while for long videos."
    }
    return footer
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let option = visibleOptions[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "quality", for: indexPath)

    var content = UIListContentConfiguration.subtitleCell()
    content.text = option.label
    content.textProperties.font = .preferredFont(forTextStyle: .headline)

    var details = [option.mode == "transcode" ? "\(option.codec) → \(isAudio ? "AAC" : "HEVC")" : option.codec]
    if let detail = option.detail {
      details.insert(detail, at: 0)
    }
    if option.bytes > 0 {
      details.append("≈ " + ByteCountFormatter.string(fromByteCount: Int64(option.bytes), countStyle: .file))
    }
    content.secondaryText = details.joined(separator: " · ")
    content.secondaryTextProperties.color = .secondaryLabel
    content.image = UIImage(systemName: isAudio ? "waveform.circle" : "arrow.down.circle")
    content.imageProperties.tintColor = view.tintColor
    cell.contentConfiguration = content

    if let badge = isAudio ? (indexPath.row == 0 ? "Best" : nil) : DownloadQualityViewController.badge(for: option) {
      let label = PaddedLabel()
      label.text = badge
      label.font = .systemFont(ofSize: 12, weight: .bold)
      label.textColor = .secondaryLabel
      label.layer.borderColor = UIColor.tertiaryLabel.cgColor
      label.layer.borderWidth = 1
      label.layer.cornerRadius = 5
      label.sizeToFit()
      cell.accessoryView = label
    } else {
      cell.accessoryView = nil
    }
    cell.accessibilityLabel = [option.label, content.secondaryText].compactMap { $0 }.joined(separator: ", ")
    return cell
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    UISelectionFeedbackGenerator().selectionChanged()
    finish(with: "\(isAudio ? "audio" : "video"):\(visibleOptions[indexPath.row].id)")
  }

  private static func badge(for option: DownloadQualityOptions.Option) -> String? {
    // use the shorter side, so that vertical videos get the same labels
    guard let height = option.height else { return nil }
    let size = min(height, option.width ?? height)
    switch size {
    case 4320...: return "8K"
    case 2160...: return "4K"
    case 1440...: return "QHD"
    case 1080...: return "Full HD"
    case 720...: return "HD"
    default: return nil
    }
  }

  private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

    override func drawText(in rect: CGRect) {
      super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
      let size = super.intrinsicContentSize
      return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
      intrinsicContentSize
    }
  }
}

// MARK: - Progress indicator

/// A glass capsule above the tab bar that shows the progress of the current download
final class DownloadIndicatorView: UIVisualEffectView {
  var onCancel: (() -> Void)?
  var onDismiss: (() -> Void)?

  private let ring = CAShapeLayer()
  private let track = CAShapeLayer()
  private let ringView = UIView()
  private let iconView = UIImageView()
  private let titleLabel = UILabel()
  private let subtitleLabel = UILabel()
  private let actionButton = UIButton(type: .system)
  private var state: DownloadManager.State?

  init() {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = true
    super.init(effect: effect)
    cornerConfiguration = .capsule()
    clipsToBounds = true

    ringView.translatesAutoresizingMaskIntoConstraints = false
    for layer in [track, ring] {
      layer.fillColor = UIColor.clear.cgColor
      layer.lineWidth = 3
      layer.lineCap = .round
      ringView.layer.addSublayer(layer)
    }
    track.strokeColor = UIColor.label.withAlphaComponent(0.12).cgColor
    ring.strokeEnd = 0

    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.contentMode = .center
    iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 13, weight: .bold)
    ringView.addSubview(iconView)

    titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
    titleLabel.adjustsFontForContentSizeCategory = true
    titleLabel.lineBreakMode = .byTruncatingTail
    subtitleLabel.font = .systemFont(ofSize: 12, weight: .regular)
    subtitleLabel.textColor = .secondaryLabel
    subtitleLabel.numberOfLines = 2
    subtitleLabel.lineBreakMode = .byTruncatingTail

    let labels = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
    labels.axis = .vertical
    labels.spacing = 1

    actionButton.translatesAutoresizingMaskIntoConstraints = false
    actionButton.tintColor = .secondaryLabel
    actionButton.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .primaryActionTriggered)

    let row = UIStackView(arrangedSubviews: [ringView, labels, actionButton])
    row.axis = .horizontal
    row.alignment = .center
    row.spacing = 12
    row.translatesAutoresizingMaskIntoConstraints = false
    contentView.addSubview(row)

    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
      row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
      row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
      ringView.widthAnchor.constraint(equalToConstant: 30),
      ringView.heightAnchor.constraint(equalToConstant: 30),
      iconView.centerXAnchor.constraint(equalTo: ringView.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: ringView.centerYAnchor),
      actionButton.widthAnchor.constraint(equalToConstant: 36),
      actionButton.heightAnchor.constraint(equalToConstant: 36),
    ])

    addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
    isAccessibilityElement = false
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    let bounds = ringView.bounds.insetBy(dx: 1.5, dy: 1.5)
    let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2,
                            startAngle: -.pi / 2, endAngle: .pi * 1.5, clockwise: true)
    ring.path = path.cgPath
    track.path = path.cgPath
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    ring.strokeColor = tintColor.cgColor
    if case .saved = state { iconView.tintColor = .systemGreen } else { iconView.tintColor = tintColor }
  }

  func update(_ state: DownloadManager.State) {
    self.state = state
    ring.strokeColor = tintColor.cgColor
    iconView.tintColor = tintColor
    ring.removeAnimation(forKey: "spin")

    let bytes = { (value: Int64) in ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
    var progress: Double?
    var icon = "arrow.down"
    var action: String? = "xmark"

    switch state {
    case let .downloading(label, received, expected):
      titleLabel.text = "Downloading \(label)"
      if expected > 0 {
        let value = min(1, Double(received) / Double(expected))
        progress = value
        subtitleLabel.text = "\(Int(value * 100))% · \(bytes(received)) of \(bytes(expected))"
      } else {
        subtitleLabel.text = bytes(received)
      }
    case let .converting(label, value, transcoding):
      titleLabel.text = transcoding ? "Converting \(label) to HEVC" : "Preparing \(label)"
      subtitleLabel.text = transcoding ? "\(Int(value * 100))% · Keep FreeTube open" : "\(Int(value * 100))%"
      progress = value
      icon = transcoding ? "wand.and.sparkles" : "film"
    case let .saving(label):
      titleLabel.text = "Saving to Photos"
      subtitleLabel.text = label
      progress = 1
      icon = "photo.on.rectangle"
      action = nil
    case let .saved(label, kind, note):
      titleLabel.text = kind == .audio || note != nil ? "Saved to Media" : "Saved to Media and Photos"
      subtitleLabel.text = note ?? "\(label) · Tap to open"
      progress = 1
      icon = "checkmark"
      action = "chevron.right"
      iconView.tintColor = .systemGreen
      ring.strokeColor = UIColor.systemGreen.cgColor
      UINotificationFeedbackGenerator().notificationOccurred(.success)
    case let .failed(message, opensSettings):
      titleLabel.text = "Download failed"
      subtitleLabel.text = opensSettings ? "\(message) Tap to open Settings." : message
      progress = 1
      icon = "exclamationmark"
      iconView.tintColor = .systemRed
      ring.strokeColor = UIColor.systemRed.cgColor
      UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    iconView.image = UIImage(systemName: icon)
    if let progress {
      CATransaction.begin()
      CATransaction.setAnimationDuration(0.25)
      ring.strokeEnd = progress
      CATransaction.commit()
    } else {
      ring.strokeEnd = 0.25
      let spin = CABasicAnimation(keyPath: "transform.rotation")
      spin.fromValue = 0
      spin.toValue = Double.pi * 2
      spin.duration = 1
      spin.repeatCount = .infinity
      ringView.layer.add(spin, forKey: "spin")
    }

    if let action {
      actionButton.isHidden = false
      actionButton.setImage(UIImage(systemName: action, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
      actionButton.accessibilityLabel = action == "xmark" ? "Cancel" : "Open Media"
    } else {
      actionButton.isHidden = true
    }
    accessibilityLabel = [titleLabel.text, subtitleLabel.text].compactMap { $0 }.joined(separator: ", ")
  }

  private func actionTapped() {
    switch state {
    case .downloading, .converting:
      onCancel?()
    case let .saved(_, kind, _):
      openDownloads(kind)
    case .failed:
      onDismiss?()
    default:
      break
    }
  }

  @objc private func tapped() {
    switch state {
    case let .saved(_, kind, _):
      openDownloads(kind)
    case .failed(_, true):
      if let url = URL(string: UIApplication.openSettingsURLString) {
        UIApplication.shared.open(url)
      }
      onDismiss?()
    default:
      break
    }
  }

  private func openDownloads(_ kind: DownloadLibrary.Kind) {
    DownloadManager.shared.onOpenDownloads?(kind)
    onDismiss?()
  }
}
