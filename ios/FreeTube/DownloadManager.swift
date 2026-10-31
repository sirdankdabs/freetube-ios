import Photos
import UIKit

/// Video and audio downloads: receives the streams from src/renderer/helpers/iosDownload.js (through AppSchemeHandler),
/// turns them into an MP4 (VideoConverter.swift) or M4A file (AudioConverter.swift) and adds it to the app's downloads
/// (DownloadLibrary.swift). Videos are saved to the Photos library too.
@MainActor
final class DownloadManager {
  static let shared = DownloadManager()

  struct Request: Decodable {
    let id: String
    /// "video" or "audio"
    let kind: String
    let videoId: String
    let author: String
    let title: String
    let label: String
    let mode: String
    let videoMimeType: String
    let audioMimeType: String
    let width: Int
    let height: Int
    let fps: Double
    let bitrate: Int
    let durationMs: Double
    let expectedBytes: Double
  }

  enum State: Equatable {
    case downloading(label: String, received: Int64, expected: Int64)
    case converting(label: String, progress: Double, transcoding: Bool)
    case saving(label: String)
    /// `note` explains when a video was only saved to the app
    case saved(label: String, kind: DownloadLibrary.Kind, note: String?)
    case failed(message: String, opensSettings: Bool)
  }

  enum DownloadError: LocalizedError, Equatable {
    case busy
    case notEnoughStorage(needed: Int64)
    case photosAccessDenied

    var errorDescription: String? {
      switch self {
      case .busy:
        return "A download is already in progress."
      case .notEnoughStorage(let needed):
        return "Not enough storage. This download needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free."
      case .photosAccessDenied:
        return "FreeTube can't add videos to Photos. Allow it in Settings."
      }
    }
  }

  /// Mutated on the main actor only, its file handles are only used on `ioQueue`
  private final class Job: @unchecked Sendable {
    let request: Request
    let directory: URL
    let videoURL: URL
    let audioURL: URL
    let videoHandle: FileHandle
    let audioHandle: FileHandle
    let cancellation = VideoConverter.Cancellation()
    var received: Int64 = 0
    var isProcessing = false

    init(request: Request, directory: URL, videoURL: URL, audioURL: URL, videoHandle: FileHandle, audioHandle: FileHandle) {
      self.request = request
      self.directory = directory
      self.videoURL = videoURL
      self.audioURL = audioURL
      self.videoHandle = videoHandle
      self.audioHandle = audioHandle
    }
  }

  /// Called with every state change, nil when there is nothing to show
  var onStateChange: ((State?) -> Void)?

  private(set) var state: State? {
    didSet {
      if state != oldValue { onStateChange?(state) }
    }
  }

  private var job: Job?
  private let ioQueue = DispatchQueue(label: "io.freetubeapp.freetube.downloads", qos: .utility)
  private var dismissWork: DispatchWorkItem?
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

  /// Where the streams are put together, the finished files are moved to the DownloadLibrary
  private static var workDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("Downloads", isDirectory: true)
  }

  /// Opens the downloads, set by WebViewController
  var onOpenDownloads: ((DownloadLibrary.Kind) -> Void)?

  /// Removes the files of downloads that were interrupted when the app was closed
  func removeLeftovers() {
    try? FileManager.default.removeItem(at: DownloadManager.workDirectory)
  }

  // MARK: - Lifecycle

  func begin(_ request: Request) throws {
    guard job == nil else {
      show(.failed(message: DownloadError.busy.localizedDescription, opensSettings: false))
      throw DownloadError.busy
    }

    // The streams, plus the combined file, plus some headroom
    let needed = Int64(request.expectedBytes * 2.2)
    if needed > 0,
       let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
       let available = values.volumeAvailableCapacityForImportantUsage,
       available < needed {
      let error = DownloadError.notEnoughStorage(needed: needed)
      show(.failed(message: error.localizedDescription, opensSettings: false))
      throw error
    }

    let directory = DownloadManager.workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let videoURL = directory.appendingPathComponent(request.videoMimeType.contains("webm") ? "video.webm" : "video.mp4")
    let audioURL = directory.appendingPathComponent(request.audioMimeType.contains("webm") ? "audio.webm" : "audio.m4a")
    FileManager.default.createFile(atPath: videoURL.path, contents: nil)
    FileManager.default.createFile(atPath: audioURL.path, contents: nil)

    job = Job(
      request: request,
      directory: directory,
      videoURL: videoURL,
      audioURL: audioURL,
      videoHandle: try FileHandle(forWritingTo: videoURL),
      audioHandle: try FileHandle(forWritingTo: audioURL)
    )
    UIApplication.shared.isIdleTimerDisabled = true
    show(.downloading(label: request.label, received: 0, expected: Int64(request.expectedBytes)))
  }

  /// Appends a chunk of one of the streams, `completion` gets false if the download was cancelled
  func receive(id: String, track: String, data: Data, completion: @escaping (Bool) -> Void) {
    guard let job, job.request.id == id, !job.cancellation.isCancelled, !job.isProcessing else {
      completion(false)
      return
    }
    let handle = track == "audio" ? job.audioHandle : job.videoHandle

    ioQueue.async {
      do {
        try handle.write(contentsOf: data)
        DispatchQueue.main.async {
          guard self.job === job, !job.cancellation.isCancelled else {
            completion(false)
            return
          }
          job.received += Int64(data.count)
          self.show(.downloading(label: job.request.label, received: job.received, expected: Int64(job.request.expectedBytes)))
          completion(true)
        }
      } catch {
        DispatchQueue.main.async {
          self.fail(id: id, message: "The download couldn't be saved: \(error.localizedDescription)")
          completion(false)
        }
      }
    }
  }

  /// Both streams are complete
  func finish(id: String) {
    guard let job, job.request.id == id, !job.cancellation.isCancelled else { return }
    job.isProcessing = true
    beginBackgroundTask()

    let request = job.request
    let transcoding = request.mode == "transcode"
    show(.converting(label: request.label, progress: 0, transcoding: transcoding))

    Task {
      do {
        await withCheckedContinuation { continuation in
          ioQueue.async {
            try? job.videoHandle.close()
            try? job.audioHandle.close()
            continuation.resume()
          }
        }

        let thumbnail = await downloadThumbnail(videoId: request.videoId, into: job.directory)
        let progress: @Sendable (Double) -> Void = { value in
          DispatchQueue.main.async {
            guard self.job === job, !job.cancellation.isCancelled else { return }
            self.show(.converting(label: request.label, progress: value, transcoding: transcoding))
          }
        }

        if request.kind == "audio" {
          let outputURL = job.directory.appendingPathComponent("audio-output.m4a")
          let metadata = AudioConverter.Metadata(title: request.title, artist: request.author, artwork: thumbnail.flatMap { try? Data(contentsOf: $0) })
          if transcoding {
            try await AudioConverter.transcodeOpus(job.audioURL, to: outputURL, bitrate: request.bitrate, metadata: metadata,
                                                   cancellation: job.cancellation, progress: progress)
          } else {
            try await AudioConverter.remux(job.audioURL, to: outputURL, metadata: metadata, cancellation: job.cancellation)
          }
          try DownloadLibrary.shared.add(kind: .audio, videoId: request.videoId, title: request.title, author: request.author,
                                         quality: request.label, durationSeconds: request.durationMs / 1000,
                                         file: outputURL, thumbnail: thumbnail)
          cleanUp(job)
          show(.saved(label: request.label, kind: .audio, note: nil))
          return
        }

        let outputURL = job.directory.appendingPathComponent(DownloadManager.fileName(for: request.title))
        let input = VideoConverter.Input(
          videoURL: job.videoURL,
          audioURL: job.audioURL,
          outputURL: outputURL,
          title: request.title,
          width: request.width,
          height: request.height,
          frameRate: request.fps,
          bitrate: request.bitrate,
          durationSeconds: request.durationMs / 1000
        )

        if transcoding {
          try await VideoConverter.transcode(input, cancellation: job.cancellation, progress: progress)
        } else {
          try await VideoConverter.remux(input, cancellation: job.cancellation, progress: progress)
        }

        // the streams aren't needed anymore, free the space before the video is copied to Photos
        try? FileManager.default.removeItem(at: job.videoURL)
        try? FileManager.default.removeItem(at: job.audioURL)

        show(.saving(label: request.label))
        let item = try DownloadLibrary.shared.add(kind: .video, videoId: request.videoId, title: request.title, author: request.author,
                                                  quality: request.label, durationSeconds: request.durationMs / 1000,
                                                  file: outputURL, thumbnail: thumbnail)
        var note: String?
        do {
          try await saveToPhotos(DownloadLibrary.shared.fileURL(for: item), title: request.title)
        } catch DownloadError.photosAccessDenied {
          note = "Allow FreeTube to add videos to Photos in Settings to save it there too."
        } catch {
          note = "It couldn't be saved to Photos: \(error.localizedDescription)"
        }

        cleanUp(job)
        show(.saved(label: request.label, kind: .video, note: note))
      } catch {
        let cancelled = job.cancellation.isCancelled
        cleanUp(job)
        if !cancelled {
          let denied = (error as? DownloadError) == .photosAccessDenied
          show(.failed(message: error.localizedDescription, opensSettings: denied))
        }
      }
    }
  }

  /// `id` is empty for errors that happen before a download is started
  func fail(id: String, message: String) {
    if id.isEmpty {
      show(.failed(message: message, opensSettings: false))
      return
    }
    guard let job, job.request.id == id else { return }
    let cancelled = job.cancellation.isCancelled
    job.cancellation.cancel()
    if !job.isProcessing {
      cleanUp(job)
    }
    if !cancelled {
      show(.failed(message: message, opensSettings: false))
    }
  }

  func cancel() {
    guard let job else {
      show(nil)
      return
    }
    job.cancellation.cancel()
    // the web app stops when its next chunk is refused, a running conversion stops by itself
    if !job.isProcessing {
      cleanUp(job)
    }
    show(nil)
  }

  func dismiss() {
    if job == nil {
      show(nil)
    }
  }

  // MARK: - Helpers

  private func cleanUp(_ finishedJob: Job) {
    ioQueue.async {
      try? finishedJob.videoHandle.close()
      try? finishedJob.audioHandle.close()
      try? FileManager.default.removeItem(at: finishedJob.directory)
    }
    if job === finishedJob {
      job = nil
    }
    UIApplication.shared.isIdleTimerDisabled = false
    endBackgroundTask()
  }

  private func show(_ newState: State?) {
    dismissWork?.cancel()
    dismissWork = nil
    state = newState

    let delay: Double
    switch newState {
    case .saved: delay = 6
    case .failed: delay = 8
    default: return
    }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.job == nil else { return }
      self.state = nil
    }
    dismissWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func beginBackgroundTask() {
    guard backgroundTask == .invalid else { return }
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Video download") { [weak self] in
      self?.endBackgroundTask()
    }
  }

  private func endBackgroundTask() {
    guard backgroundTask != .invalid else { return }
    UIApplication.shared.endBackgroundTask(backgroundTask)
    backgroundTask = .invalid
  }

  /// The artwork for the downloads, the best one YouTube has
  private func downloadThumbnail(videoId: String, into directory: URL) async -> URL? {
    for name in ["maxresdefault", "sddefault", "hqdefault"] {
      guard let url = URL(string: "https://i.ytimg.com/vi/\(videoId)/\(name).jpg") else { continue }
      let request = NetworkProxy.prepare(url: url, method: "GET", headers: [:], body: nil)
      if let (response, data) = try? await NetworkProxy.shared.fetch(request), response.statusCode == 200, data.count > 2000 {
        let file = directory.appendingPathComponent("thumbnail.jpg")
        if (try? data.write(to: file)) != nil {
          return file
        }
      }
    }
    return nil
  }

  private static func fileName(for title: String) -> String {
    let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:").union(.newlines).union(.controlCharacters)
    let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
      .trimmingCharacters(in: .whitespaces)
    let name = cleaned.isEmpty ? "Video" : String(cleaned.prefix(120))
    return "\(name).mp4"
  }

  private func saveToPhotos(_ url: URL, title: String) async throws {
    let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard status == .authorized || status == .limited else {
      throw DownloadError.photosAccessDenied
    }
    try await PHPhotoLibrary.shared().performChanges {
      let creation = PHAssetCreationRequest.forAsset()
      let options = PHAssetResourceCreationOptions()
      // the video stays in the app's downloads too
      options.shouldMoveFile = false
      options.originalFilename = url.lastPathComponent
      creation.addResource(with: .video, fileURL: url, options: options)
      creation.creationDate = Date()
    }
  }
}
