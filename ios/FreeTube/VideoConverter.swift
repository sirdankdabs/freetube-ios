import AVFoundation
import VideoToolbox

/// Turns the separately downloaded video and audio streams into a single MP4 file that Photos accepts.
/// - Remux: H.264 and AV1 (fragmented MP4) are copied as they are, together with the AAC audio.
/// - Transcode: VP9 (WebM) is decoded with VideoToolbox and encoded to HEVC, the audio is copied.
enum VideoConverter {
  struct Input {
    let videoURL: URL
    let audioURL: URL
    let outputURL: URL
    let title: String
    let width: Int
    let height: Int
    let frameRate: Double
    let bitrate: Int
    let durationSeconds: Double
  }

  enum ConversionError: LocalizedError {
    case missingTrack
    case writerFailed(String)
    case decoderUnavailable(OSStatus)
    case cancelled

    var errorDescription: String? {
      switch self {
      case .missingTrack: return "The downloaded files are incomplete."
      case .writerFailed(let reason): return "The video couldn't be saved: \(reason)"
      case .decoderUnavailable(let status): return "This device can't convert this video (\(status)). Choose a lower quality."
      case .cancelled: return "The download was cancelled."
      }
    }
  }

  /// Thread safe cancellation flag, checked between samples
  final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }
  }

  // MARK: - Remux

  static func remux(_ input: Input, cancellation: Cancellation, progress: @escaping @Sendable (Double) -> Void) async throws {
    try FragmentedMP4.resetInitDurations(input.videoURL)
    try FragmentedMP4.resetInitDurations(input.audioURL)

    let videoAsset = AVURLAsset(url: input.videoURL)
    let audioAsset = AVURLAsset(url: input.audioURL)

    guard
      let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
      let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first
    else { throw ConversionError.missingTrack }

    let videoFormat = try await videoTrack.load(.formatDescriptions).first
    let audioFormat = try await audioTrack.load(.formatDescriptions).first
    let transform = try await videoTrack.load(.preferredTransform)

    let writer = try makeWriter(input)

    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
    videoInput.transform = transform
    videoInput.expectsMediaDataInRealTime = false
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
    audioInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)
    writer.add(audioInput)

    let videoReader = try AVAssetReader(asset: videoAsset)
    let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
    videoOutput.alwaysCopiesSampleData = false
    videoReader.add(videoOutput)

    let audioReader = try AVAssetReader(asset: audioAsset)
    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    audioOutput.alwaysCopiesSampleData = false
    audioReader.add(audioOutput)

    guard videoReader.startReading(), audioReader.startReading() else {
      throw ConversionError.writerFailed(videoReader.error?.localizedDescription ?? audioReader.error?.localizedDescription ?? "unreadable")
    }
    guard writer.startWriting() else {
      throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "unknown")
    }
    writer.startSession(atSourceTime: .zero)

    async let videoDone: Void = pump(output: videoOutput, into: videoInput, queue: "video", cancellation: cancellation) { time in
      progress(min(1, time.seconds / max(input.durationSeconds, 1)))
    }
    async let audioDone: Void = pump(output: audioOutput, into: audioInput, queue: "audio", cancellation: cancellation, onSample: nil)
    _ = await (videoDone, audioDone)

    try await finish(writer, cancellation: cancellation, readers: [videoReader, audioReader])
  }

  /// Copies all the samples of the output to the input, as fast as the writer accepts them
  private static func pump(
    output readerOutput: AVAssetReaderOutput,
    into writerInput: AVAssetWriterInput,
    queue name: String,
    cancellation: Cancellation,
    onSample: ((CMTime) -> Void)?
  ) async {
    // only used on `queue`
    nonisolated(unsafe) let input = writerInput
    nonisolated(unsafe) let output = readerOutput
    let queue = DispatchQueue(label: "io.freetubeapp.freetube.convert.\(name)")
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      var finished = false
      input.requestMediaDataWhenReady(on: queue) {
        while input.isReadyForMoreMediaData && !finished {
          if cancellation.isCancelled {
            finished = true
            input.markAsFinished()
            continuation.resume()
            return
          }
          guard let sample = output.copyNextSampleBuffer() else {
            finished = true
            input.markAsFinished()
            continuation.resume()
            return
          }
          onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
          if !input.append(sample) {
            finished = true
            input.markAsFinished()
            continuation.resume()
            return
          }
        }
      }
    }
  }

  // MARK: - Transcode

  static func transcode(_ input: Input, cancellation: Cancellation, progress: @escaping @Sendable (Double) -> Void) async throws {
    let demuxer = try WebMDemuxer(url: input.videoURL)
    let width = demuxer.track.width
    let height = demuxer.track.height

    try FragmentedMP4.resetInitDurations(input.audioURL)
    let audioAsset = AVURLAsset(url: input.audioURL)
    guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first else {
      throw ConversionError.missingTrack
    }
    let audioFormat = try await audioTrack.load(.formatDescriptions).first

    let writer = try makeWriter(input)

    // HEVC is about as efficient as VP9, so keep a similar bitrate, with some headroom for the re-encoding
    let bitrate = max(Int(Double(input.bitrate) * 1.25), 2_000_000)
    let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.hevc,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: bitrate,
        AVVideoExpectedSourceFrameRateKey: input.frameRate,
        AVVideoMaxKeyFrameIntervalDurationKey: 2,
        AVVideoAllowFrameReorderingKey: true,
        AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main_AutoLevel as String,
      ],
    ])
    videoInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)

    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
    audioInput.expectsMediaDataInRealTime = false
    writer.add(videoInput)
    writer.add(audioInput)

    let audioReader = try AVAssetReader(asset: audioAsset)
    let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
    audioOutput.alwaysCopiesSampleData = false
    audioReader.add(audioOutput)

    let decoder = try VP9Decoder(width: width, height: height)

    guard audioReader.startReading() else {
      throw ConversionError.writerFailed(audioReader.error?.localizedDescription ?? "unreadable audio")
    }
    guard writer.startWriting() else {
      throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "unknown")
    }
    writer.startSession(atSourceTime: .zero)

    async let audioDone: Void = pump(output: audioOutput, into: audioInput, queue: "audio", cancellation: cancellation, onSample: nil)

    let videoQueue = DispatchQueue(label: "io.freetubeapp.freetube.convert.vp9", qos: .userInitiated)
    // only used on `videoQueue` until the conversion is done
    nonisolated(unsafe) let encoderInput = videoInput
    nonisolated(unsafe) let encoderAdaptor = adaptor
    nonisolated(unsafe) let videoWriter = writer
    let decodeError: Error? = await withCheckedContinuation { continuation in
      videoQueue.async {
        let firstTime = demuxer.frames.first?.presentationTime ?? .zero
        var lastTime = CMTime.negativeInfinity
        do {
          for (index, frame) in demuxer.frames.enumerated() {
            if cancellation.isCancelled { throw ConversionError.cancelled }

            let time = frame.presentationTime - firstTime
            let data = demuxer.data.subdata(in: frame.range)
            guard let pixelBuffer = try decoder.decode(data, presentationTime: time), time > lastTime else { continue }
            lastTime = time

            while !encoderInput.isReadyForMoreMediaData {
              if cancellation.isCancelled || videoWriter.status == .failed { throw ConversionError.cancelled }
              Thread.sleep(forTimeInterval: 0.005)
            }
            if !encoderAdaptor.append(pixelBuffer, withPresentationTime: time) {
              throw ConversionError.writerFailed(videoWriter.error?.localizedDescription ?? "encoding failed")
            }

            if index % 15 == 0 {
              progress(min(1, time.seconds / max(input.durationSeconds, 1)))
            }
          }
          encoderInput.markAsFinished()
          continuation.resume(returning: nil)
        } catch {
          encoderInput.markAsFinished()
          continuation.resume(returning: error)
        }
      }
    }
    decoder.invalidate()
    _ = await audioDone

    if let decodeError {
      writer.cancelWriting()
      throw cancellation.isCancelled ? ConversionError.cancelled : decodeError
    }
    try await finish(writer, cancellation: cancellation, readers: [audioReader])
  }

  /// Whether this device can convert VP9 downloads, i.e. VideoToolbox has a VP9 decoder
  static let canTranscodeVP9: Bool = {
    // The VP9 decoder is a supplemental decoder that apps have to opt in to
    if #available(iOS 26.2, *) {
      VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)
    }
    guard let decoder = try? VP9Decoder(width: 1920, height: 1080) else { return false }
    decoder.invalidate()
    return true
  }()

  // MARK: - Shared

  private static func makeWriter(_ input: Input) throws -> AVAssetWriter {
    try? FileManager.default.removeItem(at: input.outputURL)
    let writer = try AVAssetWriter(outputURL: input.outputURL, fileType: .mp4)
    writer.shouldOptimizeForNetworkUse = true

    let title = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = input.title as NSString
    title.extendedLanguageTag = "und"
    writer.metadata = [title]
    return writer
  }

  private static func finish(_ writer: AVAssetWriter, cancellation: Cancellation, readers: [AVAssetReader]) async throws {
    if cancellation.isCancelled {
      readers.forEach { $0.cancelReading() }
      writer.cancelWriting()
      throw ConversionError.cancelled
    }
    if let failed = readers.first(where: { $0.status == .failed }) {
      writer.cancelWriting()
      throw ConversionError.writerFailed(failed.error?.localizedDescription ?? "reading failed")
    }
    await writer.finishWriting()
    if writer.status != .completed {
      throw ConversionError.writerFailed(writer.error?.localizedDescription ?? "unknown")
    }
  }
}

/// Fixes for the fragmented MP4 files that SABR produces
enum FragmentedMP4 {
  /// YouTube's initialization segments declare the duration of the whole video in the movie header,
  /// AVFoundation treats that as an empty stretch before the fragments, doubling the duration with black frames at the start.
  /// Setting those durations to zero (which means "defined by the fragments") fixes it.
  static func resetInitDurations(_ url: URL) throws {
    let handle = try FileHandle(forUpdating: url)
    defer { try? handle.close() }

    // the moov box follows the small ftyp box at the start of the file
    var offset: UInt64 = 0
    while true {
      try handle.seek(toOffset: offset)
      guard let header = try handle.read(upToCount: 16), header.count >= 8 else { return }
      var size = UInt64(header.readUInt32(at: 0))
      let type = String(decoding: header[4..<8], as: UTF8.self)
      if size == 1, header.count >= 16 {
        size = header.readUInt64(at: 8)
      }
      guard size >= 8 else { return }

      if type == "moov" {
        guard size < 16 * 1024 * 1024, var moov = try handle.read(upToCount: Int(size) - header.count).map({ header + $0 }) else { return }
        reset(&moov, start: 0, end: moov.count)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: moov)
        return
      }
      if type == "moof" || type == "mdat" {
        return
      }
      offset += size
    }
  }

  private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "edts"]

  private static func reset(_ data: inout Data, start: Int, end: Int) {
    var position = start
    while position + 8 <= end {
      var size = Int(data.readUInt32(at: position))
      var headerLength = 8
      if size == 1, position + 16 <= end {
        size = Int(data.readUInt64(at: position + 8))
        headerLength = 16
      }
      guard size >= headerLength, position + size <= end else { return }
      let type = String(decoding: data[(position + 4)..<(position + 8)], as: UTF8.self)
      let body = position + headerLength
      let version = data[body]

      switch type {
      case "mvhd", "mdhd":
        // version, flags, creation time, modification time, timescale, duration
        data.zero(at: version == 1 ? body + 24 : body + 16, count: version == 1 ? 8 : 4)
      case "tkhd":
        // version, flags, creation time, modification time, track id, reserved, duration
        data.zero(at: version == 1 ? body + 28 : body + 20, count: version == 1 ? 8 : 4)
      case "elst":
        let count = Int(data.readUInt32(at: body + 4))
        var entry = body + 8
        for _ in 0..<count {
          guard entry + (version == 1 ? 20 : 12) <= position + size else { break }
          // only the segment duration, the media time keeps the composition offset
          data.zero(at: entry, count: version == 1 ? 8 : 4)
          entry += version == 1 ? 20 : 12
        }
      default:
        if containers.contains(type) {
          reset(&data, start: body, end: position + size)
        }
      }
      position += size
    }
  }
}

private extension Data {
  func readUInt32(at offset: Int) -> UInt32 {
    let start = startIndex + offset
    return self[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
  }

  func readUInt64(at offset: Int) -> UInt64 {
    let start = startIndex + offset
    return self[start..<(start + 8)].reduce(0) { $0 << 8 | UInt64($1) }
  }

  mutating func zero(at offset: Int, count: Int) {
    let start = startIndex + offset
    replaceSubrange(start..<(start + count), with: repeatElement(0, count: count))
  }
}

/// Hardware VP9 decoding with VideoToolbox
/// Only used on one queue at a time
private final class VP9Decoder: @unchecked Sendable {
  private var session: VTDecompressionSession?
  private let formatDescription: CMVideoFormatDescription

  init(width: Int, height: Int) throws {
    // VP codec configuration record ("vpcC" box), profile 0, 8 bit, 4:2:0 and BT.709 colours,
    // which is what YouTube's SDR VP9 streams use (HDR formats aren't offered for downloading)
    let level: UInt8 = height >= 2160 ? 51 : height >= 1440 ? 50 : 41
    let vpcC = Data([
      1, 0, 0, 0, // version 1, flags
      0, // profile
      level,
      8 << 4 | 1 << 1, // bit depth, chroma subsampling (4:2:0 colocated), video full range
      1, 1, 1, // colour primaries, transfer characteristics, matrix coefficients: BT.709
      0, 0, // no codec initialization data
    ])

    var description: CMVideoFormatDescription?
    let extensions: [CFString: Any] = [
      kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: ["vpcC": vpcC],
    ]
    var status = CMVideoFormatDescriptionCreate(
      allocator: kCFAllocatorDefault,
      codecType: kCMVideoCodecType_VP9,
      width: Int32(width),
      height: Int32(height),
      extensions: extensions as CFDictionary,
      formatDescriptionOut: &description
    )
    guard status == noErr, let description else { throw VideoConverter.ConversionError.decoderUnavailable(status) }
    formatDescription = description

    let attributes: [CFString: Any] = [
      kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
      kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
    ]
    var session: VTDecompressionSession?
    status = VTDecompressionSessionCreate(
      allocator: kCFAllocatorDefault,
      formatDescription: description,
      decoderSpecification: nil,
      imageBufferAttributes: attributes as CFDictionary,
      outputCallback: nil,
      decompressionSessionOut: &session
    )
    guard status == noErr, let session else { throw VideoConverter.ConversionError.decoderUnavailable(status) }
    self.session = session
  }

  /// Decodes one frame synchronously, returns nil for frames that aren't shown
  func decode(_ data: Data, presentationTime: CMTime) throws -> CVPixelBuffer? {
    guard let session else { return nil }

    var blockBuffer: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
      allocator: kCFAllocatorDefault,
      memoryBlock: nil,
      blockLength: data.count,
      blockAllocator: kCFAllocatorDefault,
      customBlockSource: nil,
      offsetToData: 0,
      dataLength: data.count,
      flags: kCMBlockBufferAssureMemoryNowFlag,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr, let blockBuffer else { throw VideoConverter.ConversionError.decoderUnavailable(status) }
    data.withUnsafeBytes { raw in
      _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: data.count)
    }

    var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationTime, decodeTimeStamp: .invalid)
    var sampleSize = data.count
    var sampleBuffer: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
      allocator: kCFAllocatorDefault,
      dataBuffer: blockBuffer,
      formatDescription: formatDescription,
      sampleCount: 1,
      sampleTimingEntryCount: 1,
      sampleTimingArray: &timing,
      sampleSizeEntryCount: 1,
      sampleSizeArray: &sampleSize,
      sampleBufferOut: &sampleBuffer
    )
    guard status == noErr, let sampleBuffer else { throw VideoConverter.ConversionError.decoderUnavailable(status) }

    var output: CVPixelBuffer?
    var decodeStatus: OSStatus = noErr
    status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { frameStatus, _, imageBuffer, _, _ in
      decodeStatus = frameStatus
      output = imageBuffer
    }
    VTDecompressionSessionWaitForAsynchronousFrames(session)

    if status != noErr || decodeStatus != noErr {
      throw VideoConverter.ConversionError.decoderUnavailable(status != noErr ? status : decodeStatus)
    }
    return output
  }

  func invalidate() {
    if let session {
      VTDecompressionSessionInvalidate(session)
    }
    session = nil
  }
}
