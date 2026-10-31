import UIKit

/// Navigation state of the web app, sent by the iOS region in src/renderer/components/TopNav/TopNav.vue
struct ChromeState: Decodable, Equatable {
  struct Profile: Decodable, Equatable {
    let id: String
    let name: String
    let bgColor: String
    let textColor: String
  }

  struct Labels: Decodable, Equatable {
    let subscriptions: String
    let channels: String
    let trending: String
    let popular: String
    let playlists: String
    let history: String
    let settings: String
    let about: String
    let more: String
    let profiles: String
    let manageProfiles: String
    let search: String
    let back: String
  }

  let route: String
  let isPromptOpen: Bool
  let showSearch: Bool
  let searchFiltersChanged: Bool
  let showTrending: Bool
  let showPopular: Bool
  let showPlaylists: Bool
  let activeProfileId: String
  let profiles: [Profile]
  let labels: Labels
}

@MainActor
protocol NativeChromeDelegate: AnyObject {
  func chrome(_ chrome: NativeChrome, navigateTo path: String)
  func chromeGoBack(_ chrome: NativeChrome)
  func chrome(_ chrome: NativeChrome, search query: String)
  func chrome(_ chrome: NativeChrome, suggestionsFor query: String) async -> (items: [String], removableCount: Int)?
  func chrome(_ chrome: NativeChrome, removeSearchHistoryEntry query: String)
  func chrome(_ chrome: NativeChrome, setActiveProfile id: String)
  func chromeScrollToTop(_ chrome: NativeChrome)
  func chromeShowSearchFilters(_ chrome: NativeChrome)
  /// The Downloads tab is a native screen, see DownloadsViewController.swift
  func chrome(_ chrome: NativeChrome, showDownloads: Bool)
}

/// The Liquid Glass controls that replace FreeTube's top and side navigation:
/// a floating tab bar with a search button at the bottom (which turns into a search field with suggestions),
/// and a back button and a profile/more menu at the top. The web content scrolls underneath them.
final class NativeChrome: UIView {
  weak var delegate: NativeChromeDelegate?

  static let barHeight: CGFloat = 62
  static let topButtonSize: CGFloat = 44
  static let topRowInset: CGFloat = 4
  static let sideMargin: CGFloat = 16

  /// The space covered by the controls, used for the --ios-inset-top and --ios-inset-bottom CSS variables
  var contentInsets: (top: CGFloat, bottom: CGFloat) {
    (safeAreaInsets.top + NativeChrome.topRowInset + NativeChrome.topButtonSize,
     safeAreaInsets.bottom + NativeChrome.barHeight + 8)
  }

  var canGoBack = false {
    didSet { updateBackButton(animated: true) }
  }

  private(set) var state: ChromeState?

  // MARK: Views

  private let topEdgeArea = PassthroughView()
  private let bottomEdgeArea = PassthroughView()

  private let backButton = UIButton(configuration: .glass())
  private let profileButton = UIButton(configuration: .glass())
  /// Opens the search filters, shown on the search results
  private let filterButton = UIButton(configuration: .glass())
  /// The same inside the search field
  private let searchFieldFilterButton = UIButton(type: .system)

  private let bottomGroup = PassthroughView()
  private let tabBar = UIVisualEffectView(effect: NativeChrome.glass(interactive: true))
  private let tabStack = UIStackView()
  private let selectionIndicator = UIView()
  private var tabButtons: [TabButton] = []
  private var selectedTabId: String?

  private let searchButton = UIButton(configuration: .glass())
  private let searchFieldContainer = UIVisualEffectView(effect: NativeChrome.glass(interactive: true))
  private let searchField = UITextField()

  private let suggestionsPanel = UIVisualEffectView(effect: NativeChrome.glass(interactive: false))
  private let downloadIndicator = DownloadIndicatorView()
  private var isDownloadIndicatorShown = false
  private let suggestionsTable = UITableView(frame: .zero, style: .plain)
  private var suggestionsHeight: NSLayoutConstraint!
  private var suggestions: [String] = []
  private var removableSuggestionCount = 0
  private var suggestionsTask: Task<Void, Never>?

  private var tabBarTrailingToSearch: NSLayoutConstraint!
  private var tabBarTrailingToEdge: NSLayoutConstraint!

  private(set) var isSearching = false
  /// The tap on the keyboard's search key can end up on the search button once the keyboard is gone
  private var searchEndedAt = Date.distantPast
  private var isWebKeyboardVisible = false

  private let selectionFeedback = UISelectionFeedbackGenerator()

  /// The tab bar gets out of the way while scrolling down, like the system tab bar does
  private(set) var isBarMinimized = false
  /// Called when the tab bar is hidden or shown while scrolling, the mini player moves with it
  var onBarMinimizedChange: ((Bool) -> Void)?
  private var lastScrollOffset: CGFloat = 0

  private static func glass(interactive: Bool) -> UIGlassEffect {
    let effect = UIGlassEffect(style: .regular)
    effect.isInteractive = interactive
    return effect
  }

  // MARK: Setup

  init() {
    super.init(frame: .zero)
    setUp()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
    // Only the controls take touches, everything else goes through to the web view
    let view = super.hitTest(point, with: event)
    return view === self || view is PassthroughView ? nil : view
  }

  private let topEdgeInteraction = UIScrollEdgeElementContainerInteraction()
  private let bottomEdgeInteraction = UIScrollEdgeElementContainerInteraction()

  /// Lets the scroll edge effect of the visible scroll view (the web view or Downloads) show underneath the controls
  func attach(to scrollView: UIScrollView) {
    scrollView.topEdgeEffect.style = .soft
    scrollView.bottomEdgeEffect.style = .soft

    if topEdgeInteraction.view == nil {
      topEdgeInteraction.edge = .top
      topEdgeArea.addInteraction(topEdgeInteraction)
      bottomEdgeInteraction.edge = .bottom
      bottomEdgeArea.addInteraction(bottomEdgeInteraction)
    }
    topEdgeInteraction.scrollView = scrollView
    bottomEdgeInteraction.scrollView = scrollView
  }

  // MARK: Downloads

  static let downloadsTabId = "downloads"
  private(set) var isShowingDownloads = false

  func setShowingDownloads(_ showing: Bool) {
    guard showing != isShowingDownloads else { return }
    isShowingDownloads = showing
    if showing {
      select(tabId: NativeChrome.downloadsTabId, animated: true)
    } else if let state, let tab = tabButtons.first(where: { !$0.path.isEmpty && (state.route == $0.path || state.route.hasPrefix($0.path + "/")) }) {
      select(tabId: tab.id, animated: true)
    } else {
      deselectTabs()
    }
    updateBackButton(animated: true)
    if let state { updateFilterButtons(state: state, animated: true) }
    setBarMinimized(false)
  }

  private func setUp() {
    for view in [topEdgeArea, bottomEdgeArea, downloadIndicator, suggestionsPanel, bottomGroup, backButton, profileButton, filterButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      addSubview(view)
    }

    setUpTopButtons()
    setUpBottomBar()
    setUpSuggestions()

    let safe = safeAreaLayoutGuide

    let groupLeading = bottomGroup.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: NativeChrome.sideMargin)
    groupLeading.priority = .defaultHigh
    let groupTrailing = bottomGroup.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -NativeChrome.sideMargin)
    groupTrailing.priority = .defaultHigh

    // keyboardLayoutGuide.top is the bottom of the safe area while the keyboard is hidden
    let groupBottom = bottomGroup.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor, constant: -4)

    suggestionsHeight = suggestionsPanel.heightAnchor.constraint(equalToConstant: 0)

    NSLayoutConstraint.activate([
      topEdgeArea.topAnchor.constraint(equalTo: topAnchor),
      topEdgeArea.leadingAnchor.constraint(equalTo: leadingAnchor),
      topEdgeArea.trailingAnchor.constraint(equalTo: trailingAnchor),
      topEdgeArea.bottomAnchor.constraint(equalTo: safe.topAnchor, constant: NativeChrome.topRowInset + NativeChrome.topButtonSize + 6),

      bottomEdgeArea.topAnchor.constraint(equalTo: bottomGroup.topAnchor, constant: -10),
      bottomEdgeArea.leadingAnchor.constraint(equalTo: leadingAnchor),
      bottomEdgeArea.trailingAnchor.constraint(equalTo: trailingAnchor),
      bottomEdgeArea.bottomAnchor.constraint(equalTo: bottomAnchor),

      backButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: NativeChrome.topRowInset),
      backButton.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: NativeChrome.sideMargin),
      backButton.widthAnchor.constraint(equalToConstant: NativeChrome.topButtonSize),
      backButton.heightAnchor.constraint(equalToConstant: NativeChrome.topButtonSize),

      profileButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: NativeChrome.topRowInset),
      profileButton.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -NativeChrome.sideMargin),
      profileButton.widthAnchor.constraint(equalToConstant: NativeChrome.topButtonSize),
      profileButton.heightAnchor.constraint(equalToConstant: NativeChrome.topButtonSize),

      filterButton.topAnchor.constraint(equalTo: safe.topAnchor, constant: NativeChrome.topRowInset),
      filterButton.trailingAnchor.constraint(equalTo: profileButton.leadingAnchor, constant: -10),
      filterButton.widthAnchor.constraint(equalToConstant: NativeChrome.topButtonSize),
      filterButton.heightAnchor.constraint(equalToConstant: NativeChrome.topButtonSize),

      groupLeading,
      groupTrailing,
      bottomGroup.leadingAnchor.constraint(greaterThanOrEqualTo: safe.leadingAnchor, constant: NativeChrome.sideMargin),
      bottomGroup.trailingAnchor.constraint(lessThanOrEqualTo: safe.trailingAnchor, constant: -NativeChrome.sideMargin),
      bottomGroup.centerXAnchor.constraint(equalTo: safe.centerXAnchor),
      bottomGroup.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
      bottomGroup.heightAnchor.constraint(equalToConstant: NativeChrome.barHeight),
      groupBottom,

      suggestionsPanel.leadingAnchor.constraint(equalTo: bottomGroup.leadingAnchor),
      suggestionsPanel.trailingAnchor.constraint(equalTo: bottomGroup.trailingAnchor),
      suggestionsPanel.bottomAnchor.constraint(equalTo: bottomGroup.topAnchor, constant: -10),
      suggestionsPanel.topAnchor.constraint(greaterThanOrEqualTo: safe.topAnchor, constant: NativeChrome.topRowInset + NativeChrome.topButtonSize + 10),
      suggestionsHeight,

      downloadIndicator.leadingAnchor.constraint(equalTo: bottomGroup.leadingAnchor),
      downloadIndicator.trailingAnchor.constraint(equalTo: bottomGroup.trailingAnchor),
      downloadIndicator.bottomAnchor.constraint(equalTo: bottomGroup.topAnchor, constant: -10),
      downloadIndicator.heightAnchor.constraint(greaterThanOrEqualToConstant: 54),
    ])
    downloadIndicator.alpha = 0
    downloadIndicator.isHidden = true
    downloadIndicator.onCancel = { DownloadManager.shared.cancel() }
    downloadIndicator.onDismiss = { DownloadManager.shared.dismiss() }
    suggestionsHeight.priority = .defaultHigh

    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillShow), name: UIResponder.keyboardWillShowNotification, object: nil)
    NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide), name: UIResponder.keyboardWillHideNotification, object: nil)

    registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in
      self.setBarMinimized(self.prefersMinimizedBar)
    }

    isHidden = true
  }

  private func setUpTopButtons() {
    var backConfiguration = UIButton.Configuration.glass()
    backConfiguration.image = UIImage(systemName: "chevron.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
    backConfiguration.cornerStyle = .capsule
    backButton.configuration = backConfiguration
    backButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.delegate?.chromeGoBack(self)
    }, for: .primaryActionTriggered)
    backButton.alpha = 0
    backButton.isHidden = true

    var profileConfiguration = UIButton.Configuration.glass()
    profileConfiguration.cornerStyle = .capsule
    profileConfiguration.contentInsets = .zero
    profileButton.configuration = profileConfiguration
    profileButton.showsMenuAsPrimaryAction = true

    var filterConfiguration = UIButton.Configuration.glass()
    filterConfiguration.cornerStyle = .capsule
    filterButton.configuration = filterConfiguration
    filterButton.accessibilityLabel = "Search Filters"
    filterButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.delegate?.chromeShowSearchFilters(self)
    }, for: .primaryActionTriggered)
    filterButton.alpha = 0
    filterButton.isHidden = true
  }

  private func setUpBottomBar() {
    for view in [tabBar, searchFieldContainer, searchButton] {
      view.translatesAutoresizingMaskIntoConstraints = false
      bottomGroup.addSubview(view)
    }

    tabBar.cornerConfiguration = .capsule()
    tabBar.clipsToBounds = true

    selectionIndicator.isUserInteractionEnabled = false
    selectionIndicator.cornerConfiguration = .capsule()
    selectionIndicator.alpha = 0
    tabBar.contentView.addSubview(selectionIndicator)

    tabStack.axis = .horizontal
    tabStack.distribution = .fillEqually
    tabStack.alignment = .fill
    tabStack.translatesAutoresizingMaskIntoConstraints = false
    tabBar.contentView.addSubview(tabStack)

    var searchConfiguration = UIButton.Configuration.glass()
    searchConfiguration.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
    searchConfiguration.cornerStyle = .capsule
    searchButton.configuration = searchConfiguration
    searchButton.addAction(UIAction { [weak self] _ in self?.toggleSearch() }, for: .primaryActionTriggered)

    searchFieldContainer.cornerConfiguration = .capsule()
    searchFieldContainer.clipsToBounds = true
    searchFieldContainer.alpha = 0
    searchFieldContainer.isHidden = true

    let magnifier = UIImageView(image: UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium)))
    magnifier.tintColor = .secondaryLabel
    magnifier.translatesAutoresizingMaskIntoConstraints = false
    magnifier.setContentHuggingPriority(.required, for: .horizontal)

    searchField.translatesAutoresizingMaskIntoConstraints = false
    searchField.font = .preferredFont(forTextStyle: .body)
    searchField.adjustsFontForContentSizeCategory = true
    searchField.returnKeyType = .search
    searchField.clearButtonMode = .whileEditing
    searchField.autocorrectionType = .no
    searchField.autocapitalizationType = .none
    searchField.smartQuotesType = .no
    searchField.smartDashesType = .no
    searchField.enablesReturnKeyAutomatically = true
    searchField.delegate = self
    // long queries (e.g. pasted URLs) must scroll inside the field instead of widening the bar
    searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    searchField.addAction(UIAction { [weak self] _ in self?.searchTextChanged() }, for: .editingChanged)

    searchFieldContainer.contentView.addSubview(magnifier)
    searchFieldContainer.contentView.addSubview(searchField)

    searchFieldFilterButton.translatesAutoresizingMaskIntoConstraints = false
    searchFieldFilterButton.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.delegate?.chromeShowSearchFilters(self)
    }, for: .primaryActionTriggered)
    searchFieldContainer.contentView.addSubview(searchFieldFilterButton)

    tabBarTrailingToSearch = tabBar.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -10)
    tabBarTrailingToEdge = tabBar.trailingAnchor.constraint(equalTo: bottomGroup.trailingAnchor)

    NSLayoutConstraint.activate([
      tabBar.leadingAnchor.constraint(equalTo: bottomGroup.leadingAnchor),
      tabBar.topAnchor.constraint(equalTo: bottomGroup.topAnchor),
      tabBar.bottomAnchor.constraint(equalTo: bottomGroup.bottomAnchor),
      tabBarTrailingToSearch,

      tabStack.leadingAnchor.constraint(equalTo: tabBar.contentView.leadingAnchor, constant: 4),
      tabStack.trailingAnchor.constraint(equalTo: tabBar.contentView.trailingAnchor, constant: -4),
      tabStack.topAnchor.constraint(equalTo: tabBar.contentView.topAnchor, constant: 4),
      tabStack.bottomAnchor.constraint(equalTo: tabBar.contentView.bottomAnchor, constant: -4),

      searchButton.trailingAnchor.constraint(equalTo: bottomGroup.trailingAnchor),
      searchButton.centerYAnchor.constraint(equalTo: bottomGroup.centerYAnchor),
      searchButton.widthAnchor.constraint(equalToConstant: NativeChrome.barHeight),
      searchButton.heightAnchor.constraint(equalToConstant: NativeChrome.barHeight),

      searchFieldContainer.leadingAnchor.constraint(equalTo: tabBar.leadingAnchor),
      searchFieldContainer.trailingAnchor.constraint(equalTo: tabBar.trailingAnchor),
      searchFieldContainer.topAnchor.constraint(equalTo: tabBar.topAnchor, constant: 5),
      searchFieldContainer.bottomAnchor.constraint(equalTo: tabBar.bottomAnchor, constant: -5),

      magnifier.leadingAnchor.constraint(equalTo: searchFieldContainer.contentView.leadingAnchor, constant: 18),
      magnifier.centerYAnchor.constraint(equalTo: searchFieldContainer.contentView.centerYAnchor),
      searchField.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
      searchField.trailingAnchor.constraint(equalTo: searchFieldFilterButton.leadingAnchor, constant: -4),
      searchFieldFilterButton.trailingAnchor.constraint(equalTo: searchFieldContainer.contentView.trailingAnchor, constant: -6),
      searchFieldFilterButton.centerYAnchor.constraint(equalTo: searchFieldContainer.contentView.centerYAnchor),
      searchFieldFilterButton.widthAnchor.constraint(equalToConstant: 40),
      searchFieldFilterButton.heightAnchor.constraint(equalToConstant: 40),
      searchField.topAnchor.constraint(equalTo: searchFieldContainer.contentView.topAnchor),
      searchField.bottomAnchor.constraint(equalTo: searchFieldContainer.contentView.bottomAnchor),
    ])
  }

  private func setUpSuggestions() {
    suggestionsPanel.cornerConfiguration = .uniformCorners(radius: 28)
    suggestionsPanel.clipsToBounds = true
    suggestionsPanel.alpha = 0
    suggestionsPanel.isHidden = true

    suggestionsTable.translatesAutoresizingMaskIntoConstraints = false
    suggestionsTable.backgroundColor = .clear
    suggestionsTable.separatorStyle = .none
    suggestionsTable.rowHeight = 48
    suggestionsTable.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
    suggestionsTable.keyboardDismissMode = .none
    suggestionsTable.dataSource = self
    suggestionsTable.delegate = self
    suggestionsTable.register(UITableViewCell.self, forCellReuseIdentifier: "suggestion")
    suggestionsPanel.contentView.addSubview(suggestionsTable)

    NSLayoutConstraint.activate([
      suggestionsTable.leadingAnchor.constraint(equalTo: suggestionsPanel.contentView.leadingAnchor),
      suggestionsTable.trailingAnchor.constraint(equalTo: suggestionsPanel.contentView.trailingAnchor),
      suggestionsTable.topAnchor.constraint(equalTo: suggestionsPanel.contentView.topAnchor),
      suggestionsTable.bottomAnchor.constraint(equalTo: suggestionsPanel.contentView.bottomAnchor),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    moveSelectionIndicator(animated: false)
  }

  // MARK: State

  func apply(_ newState: ChromeState) {
    let previous = state
    state = newState

    if isHidden {
      isHidden = false
      alpha = 0
      UIView.animate(withDuration: 0.35) { self.alpha = 1 }
    }

    if previous?.labels != newState.labels || previous?.showTrending != newState.showTrending || previous?.showPlaylists != newState.showPlaylists {
      rebuildTabs()
    }

    if previous?.profiles != newState.profiles || previous?.activeProfileId != newState.activeProfileId
      || previous?.showPopular != newState.showPopular || previous?.labels != newState.labels {
      rebuildProfileMenu()
    }

    // Like the web app's own navigation, the controls can't be used while a dialog is open
    if previous?.isPromptOpen != newState.isPromptOpen {
      if newState.isPromptOpen {
        endSearch()
      }
      isUserInteractionEnabled = !newState.isPromptOpen
      UIView.animate(withDuration: 0.25) {
        self.alpha = newState.isPromptOpen ? 0 : 1
      }
    }

    searchButton.isHidden = !newState.showSearch
    tabBarTrailingToSearch.isActive = newState.showSearch
    tabBarTrailingToEdge.isActive = !newState.showSearch
    searchButton.accessibilityLabel = newState.labels.search
    searchField.attributedPlaceholder = NSAttributedString(string: newState.labels.search, attributes: [.foregroundColor: UIColor.secondaryLabel])
    backButton.accessibilityLabel = newState.labels.back
    updateFilterButtons(state: newState, animated: previous != nil)

    if isShowingDownloads {
      select(tabId: NativeChrome.downloadsTabId, animated: false)
    } else if let tab = tabButtons.first(where: { !$0.path.isEmpty && (newState.route == $0.path || newState.route.hasPrefix($0.path + "/")) }) {
      select(tabId: tab.id, animated: previous != nil)
    } else if NativeChrome.menuPaths.contains(where: { newState.route == $0 || newState.route.hasPrefix($0 + "/") }) {
      deselectTabs()
    }

    updateBackButton(animated: previous != nil)
    if previous?.route != newState.route {
      updateBarMinimized(scrollOffset: lastScrollOffset, delta: 0)
    }
  }

  // MARK: Minimising

  /// On phones in landscape the video player takes up the whole height, so keep the tab bar out of its way
  private var prefersMinimizedBar: Bool {
    traitCollection.verticalSizeClass == .compact && (state?.route.hasPrefix("/watch/") ?? false)
  }

  /// `userInitiated` is false for programmatic scrolling, e.g. when a new page is opened
  func scrollViewDidScroll(offset: CGFloat, userInitiated: Bool) {
    let delta = offset - lastScrollOffset
    lastScrollOffset = offset
    updateBarMinimized(scrollOffset: offset, delta: userInitiated ? delta : 0)
  }

  private func updateBarMinimized(scrollOffset: CGFloat, delta: CGFloat) {
    guard !isSearching else { return }
    if delta < -6 {
      setBarMinimized(false)
    } else if delta > 6 && scrollOffset > 80 {
      setBarMinimized(true)
    } else if scrollOffset <= 10 {
      setBarMinimized(prefersMinimizedBar)
    }
  }

  private func setBarMinimized(_ minimized: Bool) {
    guard minimized != isBarMinimized else { return }
    isBarMinimized = minimized
    onBarMinimizedChange?(minimized)
    let offset = NativeChrome.barHeight + safeAreaInsets.bottom + 24
    UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.bottomGroup.transform = minimized ? CGAffineTransform(translationX: 0, y: offset) : .identity
      // the download progress takes the place of the tab bar
      self.downloadIndicator.transform = minimized ? CGAffineTransform(translationX: 0, y: NativeChrome.barHeight + 10) : .identity
      self.bottomGroup.alpha = minimized || self.isWebKeyboardVisible ? 0 : 1
    }
  }

  private struct TabDefinition {
    let id: String
    let path: String
    let title: String
    let symbol: String
    let selectedSymbol: String
  }

  private func rebuildTabs() {
    guard let state else { return }
    let labels = state.labels

    var definitions = [
      TabDefinition(id: "subscriptions", path: "/subscriptions", title: "Me",
                    symbol: "rectangle.stack.badge.play", selectedSymbol: "rectangle.stack.badge.play.fill"),
    ]
    if state.showTrending {
      definitions.append(TabDefinition(id: "trending", path: "/trending", title: labels.trending, symbol: "flame", selectedSymbol: "flame.fill"))
    }
    if state.showPlaylists {
      definitions.append(TabDefinition(id: "playlists", path: "/userplaylists", title: labels.playlists, symbol: "list.and.film", selectedSymbol: "list.and.film"))
    }
    definitions.append(TabDefinition(id: "history", path: "/history", title: labels.history, symbol: "clock.arrow.circlepath", selectedSymbol: "clock.arrow.circlepath"))
    definitions.append(TabDefinition(id: NativeChrome.downloadsTabId, path: "", title: "Media", symbol: "play.square.stack", selectedSymbol: "play.square.stack.fill"))

    for button in tabButtons {
      button.removeFromSuperview()
    }
    tabButtons = definitions.map { definition in
      let button = TabButton(id: definition.id, path: definition.path, title: definition.title,
                             symbol: definition.symbol, selectedSymbol: definition.selectedSymbol)
      button.addAction(UIAction { [weak self, weak button] _ in
        guard let self, let button else { return }
        self.tabTapped(button)
      }, for: .touchUpInside)
      tabStack.addArrangedSubview(button)
      return button
    }

    if let selectedTabId, tabButtons.contains(where: { $0.id == selectedTabId }) {
      select(tabId: selectedTabId, animated: false)
    } else {
      selectedTabId = nil
      selectionIndicator.alpha = 0
    }
  }

  private func tabTapped(_ button: TabButton) {
    if button.id == NativeChrome.downloadsTabId {
      if isShowingDownloads {
        delegate?.chromeScrollToTop(self)
      } else {
        selectionFeedback.selectionChanged()
        delegate?.chrome(self, showDownloads: true)
      }
      return
    }

    if isShowingDownloads {
      selectionFeedback.selectionChanged()
      delegate?.chrome(self, showDownloads: false)
      if state.map({ $0.route == button.path }) == true {
        return
      }
    } else if selectedTabId == button.id && state.map({ $0.route == button.path }) == true {
      delegate?.chromeScrollToTop(self)
      return
    } else {
      selectionFeedback.selectionChanged()
    }
    select(tabId: button.id, animated: true)
    delegate?.chrome(self, navigateTo: button.path)
  }

  /// Pages opened from the profile menu, which don't belong to any of the tabs
  private static let menuPaths = ["/settings", "/about", "/subscribedchannels", "/popular"]

  private func deselectTabs() {
    selectedTabId = nil
    for button in tabButtons {
      button.isSelected = false
    }
    UIView.animate(withDuration: 0.25) { self.selectionIndicator.alpha = 0 }
  }

  private func select(tabId: String, animated: Bool) {
    selectedTabId = tabId
    for button in tabButtons {
      button.isSelected = button.id == tabId
    }
    moveSelectionIndicator(animated: animated)
  }

  private func moveSelectionIndicator(animated: Bool) {
    guard let button = tabButtons.first(where: { $0.id == selectedTabId }) else { return }
    tabBar.contentView.layoutIfNeeded()
    let frame = button.convert(button.bounds, to: tabBar.contentView)
    if selectionIndicator.alpha == 0 {
      selectionIndicator.frame = frame
    }
    let update = {
      self.selectionIndicator.frame = frame
      self.selectionIndicator.alpha = 1
    }
    if animated {
      UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4, options: [.beginFromCurrentState, .allowUserInteraction], animations: update)
    } else {
      update()
    }
  }

  /// The filled icon shows that filters are applied
  private func updateFilterButtons(state: ChromeState, animated: Bool) {
    let symbol = state.searchFiltersChanged ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
    var configuration = filterButton.configuration ?? .glass()
    configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
    filterButton.configuration = configuration
    searchFieldFilterButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .regular)), for: .normal)
    searchFieldFilterButton.tintColor = state.searchFiltersChanged ? tintColor : .secondaryLabel
    searchFieldFilterButton.accessibilityLabel = "Search Filters"

    let visible = state.route.hasPrefix("/search/") && state.showSearch && !isShowingDownloads
    guard visible == filterButton.isHidden else { return }
    if visible { filterButton.isHidden = false }
    let changes = {
      self.filterButton.alpha = visible ? 1 : 0
      self.filterButton.transform = visible ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
    }
    let completion: (Bool) -> Void = { _ in if !visible { self.filterButton.isHidden = true } }
    if animated {
      UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3, options: [.beginFromCurrentState], animations: changes, completion: completion)
    } else {
      changes()
      completion(true)
    }
  }

  private func updateBackButton(animated: Bool) {
    let isTabRoot = tabButtons.contains { !$0.path.isEmpty && $0.path == state?.route }
    let visible = canGoBack && !isTabRoot && state != nil && !isShowingDownloads
    guard visible == backButton.isHidden else { return }

    if visible {
      backButton.isHidden = false
    }
    let changes = {
      self.backButton.alpha = visible ? 1 : 0
      self.backButton.transform = visible ? .identity : CGAffineTransform(scaleX: 0.6, y: 0.6)
    }
    let completion: (Bool) -> Void = { _ in
      if !visible { self.backButton.isHidden = true }
    }
    if animated {
      UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3, options: [.beginFromCurrentState], animations: changes, completion: completion)
    } else {
      changes()
      completion(true)
    }
  }

  private func rebuildProfileMenu() {
    guard let state else { return }
    let labels = state.labels
    let activeProfile = state.profiles.first { $0.id == state.activeProfileId } ?? state.profiles.first

    if let activeProfile {
      var configuration = profileButton.configuration ?? .glass()
      configuration.image = NativeChrome.profileImage(for: activeProfile, diameter: 32)
      profileButton.configuration = configuration
      profileButton.accessibilityLabel = activeProfile.name
    }

    var sections: [UIMenuElement] = []

    if state.profiles.count > 1 {
      let profileActions = state.profiles.map { profile in
        UIAction(title: profile.name, image: NativeChrome.profileImage(for: profile, diameter: 24),
                 state: profile.id == state.activeProfileId ? .on : .off) { [weak self] _ in
          guard let self else { return }
          self.delegate?.chrome(self, setActiveProfile: profile.id)
        }
      }
      sections.append(UIMenu(title: labels.profiles, options: .displayInline, children: profileActions))
    }

    var pages: [UIMenuElement] = [
      navigationAction(labels.channels, symbol: "person.2", path: "/subscribedchannels"),
    ]
    if state.showPopular {
      pages.append(navigationAction(labels.popular, symbol: "chart.line.uptrend.xyaxis", path: "/popular"))
    }
    sections.append(UIMenu(options: .displayInline, children: pages))

    sections.append(UIMenu(options: .displayInline, children: [
      navigationAction(labels.settings, symbol: "gearshape", path: "/settings"),
      navigationAction(labels.manageProfiles, symbol: "person.crop.circle", path: "/settings/profile"),
      navigationAction(labels.about, symbol: "info.circle", path: "/about"),
    ]))

    profileButton.menu = UIMenu(children: sections)
  }

  private func navigationAction(_ title: String, symbol: String, path: String) -> UIAction {
    UIAction(title: title, image: UIImage(systemName: symbol)) { [weak self] _ in
      guard let self else { return }
      self.delegate?.chrome(self, navigateTo: path)
    }
  }

  private static func profileImage(for profile: ChromeState.Profile, diameter: CGFloat) -> UIImage {
    let background = UIColor(cssColor: profile.bgColor) ?? .systemGray
    let foreground = UIColor(cssColor: profile.textColor) ?? .white
    let size = CGSize(width: diameter, height: diameter)
    let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: diameter * 0.55, weight: .semibold)
    let symbol = UIImage(systemName: "person.fill", withConfiguration: symbolConfiguration)?.withTintColor(foreground, renderingMode: .alwaysOriginal)

    return UIGraphicsImageRenderer(size: size).image { _ in
      background.setFill()
      UIBezierPath(ovalIn: CGRect(origin: .zero, size: size)).fill()
      if let symbol {
        symbol.draw(at: CGPoint(x: (size.width - symbol.size.width) / 2, y: (size.height - symbol.size.height) / 2))
      }
    }.withRenderingMode(.alwaysOriginal)
  }

  // MARK: Downloads

  func showDownload(_ state: DownloadManager.State?) {
    if let state {
      downloadIndicator.update(state)
    }
    let show = state != nil
    guard show != isDownloadIndicatorShown else { return }
    isDownloadIndicatorShown = show

    if show {
      downloadIndicator.isHidden = false
      downloadIndicator.transform = downloadIndicator.transform.translatedBy(x: 0, y: 16)
    }
    UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.3, options: [.beginFromCurrentState, .allowUserInteraction]) {
      self.downloadIndicator.alpha = show && !self.isSearching ? 1 : 0
      self.downloadIndicator.transform = self.isBarMinimized ? CGAffineTransform(translationX: 0, y: NativeChrome.barHeight + 10) : .identity
    } completion: { _ in
      if !self.isDownloadIndicatorShown { self.downloadIndicator.isHidden = true }
    }
  }

  // MARK: Theme

  func applyTheme(page: UIColor, accent: UIColor?) {
    overrideUserInterfaceStyle = page.isLight ? .light : .dark
    tintColor = accent ?? .systemRed
    selectionIndicator.backgroundColor = page.isLight ? UIColor.black.withAlphaComponent(0.07) : UIColor.white.withAlphaComponent(0.12)
    searchField.tintColor = tintColor
  }

  // MARK: Search

  private func toggleSearch() {
    if isSearching {
      endSearch()
    } else {
      beginSearch()
    }
  }

  func beginSearch() {
    guard !isSearching, Date().timeIntervalSince(searchEndedAt) > 0.6 else { return }
    setBarMinimized(false)
    isSearching = true
    selectionFeedback.selectionChanged()

    var configuration = searchButton.configuration
    configuration?.image = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold))
    searchButton.configuration = configuration

    searchFieldContainer.isHidden = false
    searchFieldContainer.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3, options: [.beginFromCurrentState]) {
      self.tabBar.alpha = 0
      self.tabBar.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
      self.downloadIndicator.alpha = 0
      self.searchFieldContainer.alpha = 1
      self.searchFieldContainer.transform = .identity
    }

    searchField.text = ""
    searchField.becomeFirstResponder()
    loadSuggestions(for: "")
  }

  func endSearch() {
    guard isSearching else { return }
    isSearching = false
    searchEndedAt = Date()
    suggestionsTask?.cancel()
    searchField.resignFirstResponder()

    var configuration = searchButton.configuration
    configuration?.image = UIImage(systemName: "magnifyingglass", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
    searchButton.configuration = configuration

    showSuggestions([], removableCount: 0)
    UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0.3, options: [.beginFromCurrentState]) {
      self.tabBar.alpha = 1
      self.tabBar.transform = .identity
      self.downloadIndicator.alpha = self.isDownloadIndicatorShown ? 1 : 0
      self.searchFieldContainer.alpha = 0
      self.searchFieldContainer.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
    } completion: { _ in
      if !self.isSearching { self.searchFieldContainer.isHidden = true }
    }
  }

  private func submitSearch(_ query: String) {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    delegate?.chrome(self, search: trimmed)
    endSearch()
  }

  private func searchTextChanged() {
    loadSuggestions(for: searchField.text ?? "")
  }

  private func loadSuggestions(for query: String) {
    suggestionsTask?.cancel()
    suggestionsTask = Task { [weak self] in
      // debounce typing
      if !query.isEmpty {
        try? await Task.sleep(for: .milliseconds(180))
      }
      guard let self, !Task.isCancelled, self.isSearching else { return }
      guard let result = await self.delegate?.chrome(self, suggestionsFor: query) else { return }
      guard !Task.isCancelled, self.isSearching, (self.searchField.text ?? "") == query else { return }
      self.showSuggestions(result.items, removableCount: result.removableCount)
    }
  }

  private func showSuggestions(_ items: [String], removableCount: Int) {
    suggestions = items
    removableSuggestionCount = removableCount
    suggestionsTable.reloadData()

    let visible = !items.isEmpty && isSearching
    suggestionsHeight.constant = CGFloat(min(items.count, 8)) * suggestionsTable.rowHeight + 12

    if visible && suggestionsPanel.isHidden {
      suggestionsPanel.isHidden = false
      suggestionsPanel.transform = CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.97, y: 0.97)
    }

    UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0.2, options: [.beginFromCurrentState]) {
      self.suggestionsPanel.alpha = visible ? 1 : 0
      self.suggestionsPanel.transform = visible ? .identity : CGAffineTransform(translationX: 0, y: 12).scaledBy(x: 0.97, y: 0.97)
      self.layoutIfNeeded()
    } completion: { _ in
      if self.suggestions.isEmpty || !self.isSearching { self.suggestionsPanel.isHidden = true }
    }
  }

  // MARK: Keyboard

  @objc private func keyboardWillShow(_ notification: Notification) {
    // Get out of the way when typing into the web app, e.g. in the settings
    guard !isSearching, !isWebKeyboardVisible else { return }
    isWebKeyboardVisible = true
    UIView.animate(withDuration: 0.25) {
      self.bottomGroup.alpha = 0
    }
  }

  @objc private func keyboardWillHide(_ notification: Notification) {
    guard isWebKeyboardVisible else { return }
    isWebKeyboardVisible = false
    UIView.animate(withDuration: 0.25) {
      self.bottomGroup.alpha = self.isBarMinimized ? 0 : 1
    }
  }
}

// MARK: - UITextFieldDelegate

extension NativeChrome: UITextFieldDelegate {
  func textFieldShouldReturn(_ textField: UITextField) -> Bool {
    submitSearch(textField.text ?? "")
    return false
  }
}

// MARK: - Suggestions table

extension NativeChrome: UITableViewDataSource, UITableViewDelegate {
  func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    suggestions.count
  }

  func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(withIdentifier: "suggestion", for: indexPath)
    var content = cell.defaultContentConfiguration()
    content.text = suggestions[indexPath.row]
    content.textProperties.numberOfLines = 1
    content.image = UIImage(systemName: indexPath.row < removableSuggestionCount ? "clock.arrow.circlepath" : "magnifyingglass")
    content.imageProperties.tintColor = .secondaryLabel
    content.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15, weight: .medium)
    content.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20)
    cell.contentConfiguration = content
    cell.backgroundConfiguration = .clear()

    var selected = UIBackgroundConfiguration.clear()
    selected.backgroundColor = UIColor.label.withAlphaComponent(0.08)
    selected.cornerRadius = 16
    selected.backgroundInsets = NSDirectionalEdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
    cell.configurationUpdateHandler = { cell, state in
      cell.backgroundConfiguration = state.isHighlighted || state.isSelected ? selected : .clear()
    }

    let fill = UIButton(type: .system)
    fill.setImage(UIImage(systemName: "arrow.up.backward", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)), for: .normal)
    fill.tintColor = .tertiaryLabel
    fill.frame = CGRect(x: 0, y: 0, width: 36, height: 36)
    let text = suggestions[indexPath.row]
    fill.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      self.searchField.text = text + " "
      self.searchTextChanged()
    }, for: .primaryActionTriggered)
    cell.accessoryView = fill
    return cell
  }

  func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    submitSearch(suggestions[indexPath.row])
  }

  func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
    guard indexPath.row < removableSuggestionCount else { return nil }
    let entry = suggestions[indexPath.row]
    let delete = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
      guard let self else { return completion(false) }
      self.delegate?.chrome(self, removeSearchHistoryEntry: entry)
      self.suggestions.remove(at: indexPath.row)
      self.removableSuggestionCount -= 1
      tableView.deleteRows(at: [indexPath], with: .automatic)
      self.showSuggestions(self.suggestions, removableCount: self.removableSuggestionCount)
      completion(true)
    }
    delete.image = UIImage(systemName: "trash")
    return UISwipeActionsConfiguration(actions: [delete])
  }
}

// MARK: - Tab button

private final class TabButton: UIControl {
  let id: String
  let path: String
  private let symbol: String
  private let selectedSymbol: String
  private let imageView = UIImageView()
  private let label = UILabel()

  init(id: String, path: String, title: String, symbol: String, selectedSymbol: String) {
    self.id = id
    self.path = path
    self.symbol = symbol
    self.selectedSymbol = selectedSymbol
    super.init(frame: .zero)

    imageView.contentMode = .center
    imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 19, weight: .medium)
    label.text = title
    label.font = .systemFont(ofSize: 10, weight: .semibold)
    label.textAlignment = .center
    label.adjustsFontSizeToFitWidth = true
    label.minimumScaleFactor = 0.62
    label.lineBreakMode = .byTruncatingTail

    let stack = UIStackView(arrangedSubviews: [imageView, label])
    stack.axis = .vertical
    stack.alignment = .center
    stack.spacing = 2
    stack.isUserInteractionEnabled = false
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 2),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -2),
      imageView.heightAnchor.constraint(equalToConstant: 26),
    ])

    isAccessibilityElement = true
    accessibilityLabel = title
    accessibilityTraits = .button
    updateAppearance()
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var isSelected: Bool {
    didSet { updateAppearance() }
  }

  override var isHighlighted: Bool {
    didSet {
      UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
        self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
      }
    }
  }

  override func tintColorDidChange() {
    super.tintColorDidChange()
    updateAppearance()
  }

  private func updateAppearance() {
    imageView.image = UIImage(systemName: isSelected ? selectedSymbol : symbol)
    let color: UIColor = isSelected ? tintColor : .label
    imageView.tintColor = color
    label.textColor = color
    accessibilityTraits = isSelected ? [.button, .selected] : .button
  }
}

/// A view that doesn't take touches itself, only its subviews do
final class PassthroughView: UIView {}

// MARK: - Colours

extension UIColor {
  /// Parses the `rgb()`/`rgba()` values returned by getComputedStyle and hex colours
  convenience init?(cssColor: String) {
    let value = cssColor.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

    if value.hasPrefix("#") {
      var hex = String(value.dropFirst())
      if hex.count == 3 {
        hex = hex.map { "\($0)\($0)" }.joined()
      }
      guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
      let hasAlpha = hex.count == 8
      let r = CGFloat((number >> (hasAlpha ? 24 : 16)) & 0xff) / 255
      let g = CGFloat((number >> (hasAlpha ? 16 : 8)) & 0xff) / 255
      let b = CGFloat((number >> (hasAlpha ? 8 : 0)) & 0xff) / 255
      let a = hasAlpha ? CGFloat(number & 0xff) / 255 : 1
      self.init(red: r, green: g, blue: b, alpha: a)
      return
    }

    guard let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") else { return nil }
    let components = value[value.index(after: open)..<close]
      .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
      .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard components.count >= 3 else { return nil }
    let alpha = components.count >= 4 ? components[3] : 1
    guard alpha > 0 else { return nil }
    self.init(red: components[0] / 255, green: components[1] / 255, blue: components[2] / 255, alpha: 1)
  }

  var isLight: Bool {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    getRed(&r, green: &g, blue: &b, alpha: &a)
    return (0.299 * r + 0.587 * g + 0.114 * b) > 0.6
  }
}
