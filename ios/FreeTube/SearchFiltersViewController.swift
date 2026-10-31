import UIKit

/// The search filters (type, duration, upload date and sort order) as an inset grouped list.
/// The options and their rules come from the iOS region in src/renderer/components/TopNav/TopNav.vue.
final class SearchFiltersViewController: UITableViewController, UIAdaptivePresentationControllerDelegate {
  struct Section: Decodable {
    struct Option: Decodable {
      let value: String
      let label: String
      let disabled: Bool
    }

    let key: String
    let title: String
    let selected: String
    let options: [Option]
  }

  private var sections: [Section]
  /// Changes one filter, returns all the filters after the change
  private let onChange: (_ key: String, _ value: String) async -> [Section]?
  private let onDone: () -> Void

  init(sections: [Section], onChange: @escaping (String, String) async -> [Section]?, onDone: @escaping () -> Void) {
    self.sections = sections
    self.onChange = onChange
    self.onDone = onDone
    super.init(style: .insetGrouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    title = "Search Filters"
    navigationItem.largeTitleDisplayMode = .never
    navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
      self?.dismiss(animated: true)
    })
    navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Reset", primaryAction: UIAction { [weak self] _ in
      self?.reset()
    })
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "option")
    updateResetButton()
  }

  private var finished = false

  /// The filters are applied once, however the sheet is closed (Done or swiping it down)
  private func finish() {
    guard !finished else { return }
    finished = true
    onDone()
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    navigationController?.presentationController?.delegate = self
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    if isBeingDismissed || navigationController?.isBeingDismissed == true {
      finish()
    }
  }

  func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
    finish()
  }

  private static let defaults = ["type": "all", "duration": "", "time": "", "prioritize": "relevance"]

  private func updateResetButton() {
    navigationItem.leftBarButtonItem?.isEnabled = sections.contains { SearchFiltersViewController.defaults[$0.key] != $0.selected }
  }

  private func reset() {
    Task { @MainActor in
      for (key, value) in SearchFiltersViewController.defaults {
        if let updated = await onChange(key, value) {
          sections = updated
        }
      }
      tableView.reloadData()
      updateResetButton()
    }
  }

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].options.count
  }

  override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
    sections[section].title
  }

  override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
    let section = sections[indexPath.section]
    let option = section.options[indexPath.row]
    let cell = tableView.dequeueReusableCell(withIdentifier: "option", for: indexPath)

    var content = cell.defaultContentConfiguration()
    content.text = option.label
    content.textProperties.color = option.disabled ? .tertiaryLabel : .label
    cell.contentConfiguration = content
    cell.accessoryType = option.value == section.selected && !option.disabled ? .checkmark : .none
    cell.selectionStyle = option.disabled ? .none : .default
    cell.accessibilityTraits = option.value == section.selected ? [.button, .selected] : .button
    return cell
  }

  override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
    sections[indexPath.section].options[indexPath.row].disabled ? nil : indexPath
  }

  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let section = sections[indexPath.section]
    let option = section.options[indexPath.row]
    guard option.value != section.selected else { return }
    UISelectionFeedbackGenerator().selectionChanged()

    Task { @MainActor in
      guard let updated = await onChange(section.key, option.value) else { return }
      sections = updated
      tableView.reloadSections(IndexSet(integersIn: 0..<sections.count), with: .none)
      updateResetButton()
    }
  }
}
