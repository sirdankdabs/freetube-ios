import Foundation

/// The downloaded videos and audio, kept in Application Support/Downloads with an index of their details
@MainActor
final class DownloadLibrary {
  static let shared = DownloadLibrary()
  static let didChangeNotification = Notification.Name("io.freetubeapp.freetube.DownloadLibraryDidChange")

  enum Kind: String, Codable {
    case video
    case audio
  }

  struct Item: Codable, Identifiable, Hashable {
    let id: String
    let kind: Kind
    let videoId: String
    let title: String
    let author: String
    let quality: String
    let fileName: String
    let thumbnailFileName: String?
    let durationSeconds: Double
    let bytes: Int64
    let date: Date
  }

  private(set) var items: [Item] = []

  let directory: URL = {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    var directory = support.appendingPathComponent("Downloads", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // can be downloaded again, so don't fill up the user's iCloud backup
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? directory.setResourceValues(values)
    return directory
  }()

  private var indexURL: URL { directory.appendingPathComponent("index.json") }

  private init() {
    if let data = try? Data(contentsOf: indexURL),
       let decoded = try? JSONDecoder().decode([Item].self, from: data) {
      // drop the entries whose file is gone
      items = decoded.filter { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.fileName).path) }
    }
  }

  func items(of kind: Kind) -> [Item] {
    items.filter { $0.kind == kind }.sorted { $0.date > $1.date }
  }

  func fileURL(for item: Item) -> URL {
    directory.appendingPathComponent(item.fileName)
  }

  func thumbnailURL(for item: Item) -> URL? {
    item.thumbnailFileName.map { directory.appendingPathComponent($0) }
  }

  /// Moves the file into the library
  @discardableResult
  func add(kind: Kind, videoId: String, title: String, author: String, quality: String, durationSeconds: Double,
           file: URL, thumbnail: URL?) throws -> Item {
    let id = UUID().uuidString
    let fileName = "\(id).\(file.pathExtension)"
    try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent(fileName))

    var thumbnailFileName: String?
    if let thumbnail, (try? FileManager.default.moveItem(at: thumbnail, to: directory.appendingPathComponent("\(id).jpg"))) != nil {
      thumbnailFileName = "\(id).jpg"
    }

    let bytes = (try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(fileName).path)[.size] as? Int64) ?? 0
    let item = Item(id: id, kind: kind, videoId: videoId, title: title, author: author, quality: quality, fileName: fileName,
                    thumbnailFileName: thumbnailFileName, durationSeconds: durationSeconds, bytes: bytes, date: Date())
    items.append(item)
    save()
    return item
  }

  func delete(_ item: Item) {
    try? FileManager.default.removeItem(at: fileURL(for: item))
    if let thumbnail = thumbnailURL(for: item) {
      try? FileManager.default.removeItem(at: thumbnail)
    }
    items.removeAll { $0.id == item.id }
    save()
  }

  private func save() {
    if let data = try? JSONEncoder().encode(items) {
      try? data.write(to: indexURL, options: .atomic)
    }
    NotificationCenter.default.post(name: DownloadLibrary.didChangeNotification, object: self)
  }
}
