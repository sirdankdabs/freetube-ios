import AVFoundation

/// Turns the downloaded audio streams into M4A (AAC) files, which every app can open.
/// - AAC streams (fragmented MP4) are copied as they are.
/// - Opus streams (WebM), YouTube's best audio quality, are decoded and encoded to AAC at a bitrate that keeps their quality.
/// The title, the artist and the artwork are added, so that the files look right when they are shared.
enum AudioConverter {
  struct Metadata {
    let title: String
    let artist: String
    let artwork: Data?
  }

  static func remux(_ source: URL, to output: URL, metadata: Metadata, cancellation: VideoConverter.Cancellation) async throws {
    try FragmentedMP4.resetInitDurations(source)
    try await export(AVURLAsset(url: source), to: output, metadata: metadata, cancellation: cancellation)
  }

  static func transcodeOpus(_ source: URL, to output: URL, bitrate: Int, metadata: Metadata, cancellation: VideoConverter.Cancellation,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
    let demuxer = try WebMDemuxer(url: source, trackType: .audio)
    let channels = AVAudioChannelCount(max(1, min(demuxer.track.channels, 2)))

    // Opus always decodes at 48 kHz
    var description = AudioStreamBasicDescription(
      mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
      mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: channels, mBitsPerChannel: 0, mReserved: 0
    )
    guard
      let opusFormat = AVAudioFormat(streamDescription: &description),
      let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: channels, interleaved: false),
      let converter = AVAudioConverter(from: opusFormat, to: pcmFormat)
    else {
      throw VideoConverter.ConversionError.writerFailed("Opus audio isn't supported on this device")
    }
    if !demuxer.track.codecPrivate.isEmpty {
      converter.magicCookie = demuxer.track.codecPrivate
    }

    // samples at the start that the encoder added (pre-skip in the OpusHead header)
    var skip = 312
    let head = demuxer.track.codecPrivate
    if head.count >= 12, head.starts(with: Array("OpusHead".utf8)) {
      skip = Int(UInt16(head[head.startIndex + 10]) | UInt16(head[head.startIndex + 11]) << 8)
    }

    let intermediate = output.deletingPathExtension().appendingPathExtension("encoding.m4a")
    try? FileManager.default.removeItem(at: intermediate)
    defer { try? FileManager.default.removeItem(at: intermediate) }

    try await Task.detached(priority: .userInitiated) {
      let file = try AVAudioFile(forWriting: intermediate, settings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: channels,
        AVEncoderBitRateKey: channels == 1 ? min(bitrate, 128_000) : min(max(bitrate, 64_000), 256_000),
        AVEncoderAudioQualityKey: AVAudioQuality.max.rawValue,
      ], commonFormat: .pcmFormatFloat32, interleaved: false)

      let frames = demuxer.frames
      var index = 0
      let batch = 50

      while index < frames.count {
        if cancellation.isCancelled { throw VideoConverter.ConversionError.cancelled }

        let end = min(index + batch, frames.count)
        let packets = frames[index..<end]
        let totalBytes = packets.reduce(0) { $0 + $1.range.count }
        let maxPacketSize = packets.map(\.range.count).max() ?? 0

        let compressed = AVAudioCompressedBuffer(format: opusFormat, packetCapacity: AVAudioPacketCount(packets.count), maximumPacketSize: maxPacketSize)
        var offset = 0
        demuxer.data.withUnsafeBytes { raw in
          for (packetIndex, frame) in packets.enumerated() {
            memcpy(compressed.data + offset, raw.baseAddress! + frame.range.lowerBound, frame.range.count)
            compressed.packetDescriptions![packetIndex] = AudioStreamPacketDescription(
              mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.range.count)
            )
            offset += frame.range.count
          }
        }
        compressed.packetCount = AVAudioPacketCount(packets.count)
        compressed.byteLength = UInt32(totalBytes)

        // a packet is at most 120 ms
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(packets.count * 5760)) else {
          throw VideoConverter.ConversionError.writerFailed("out of memory")
        }
        var provided = false
        var conversionError: NSError?
        let status = converter.convert(to: pcm, error: &conversionError) { _, inputStatus in
          if provided {
            inputStatus.pointee = .noDataNow
            return nil
          }
          provided = true
          inputStatus.pointee = .haveData
          return compressed
        }
        if status == .error {
          throw VideoConverter.ConversionError.writerFailed(conversionError?.localizedDescription ?? "decoding failed")
        }

        if skip > 0 && pcm.frameLength > 0 {
          let skipped = min(skip, Int(pcm.frameLength))
          skip -= skipped
          let remaining = Int(pcm.frameLength) - skipped
          for channel in 0..<Int(channels) {
            let data = pcm.floatChannelData![channel]
            memmove(data, data + skipped, remaining * MemoryLayout<Float>.size)
          }
          pcm.frameLength = AVAudioFrameCount(remaining)
        }
        if pcm.frameLength > 0 {
          try file.write(from: pcm)
        }

        index = end
        progress(Double(index) / Double(frames.count) * 0.95)
      }
    }.value

    try await export(AVURLAsset(url: intermediate), to: output, metadata: metadata, cancellation: cancellation)
    progress(1)
  }

  /// Copies the audio into an M4A file with the metadata
  private static func export(_ asset: AVURLAsset, to output: URL, metadata: Metadata, cancellation: VideoConverter.Cancellation) async throws {
    if cancellation.isCancelled { throw VideoConverter.ConversionError.cancelled }
    guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
      throw VideoConverter.ConversionError.writerFailed("the audio can't be exported")
    }

    var items: [AVMetadataItem] = []
    func add(_ identifier: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol, dataType: String? = nil) {
      let item = AVMutableMetadataItem()
      item.identifier = identifier
      item.value = value
      item.extendedLanguageTag = "und"
      if let dataType {
        item.dataType = dataType
      }
      items.append(item)
    }
    add(.commonIdentifierTitle, metadata.title as NSString)
    add(.commonIdentifierArtist, metadata.artist as NSString)
    add(.iTunesMetadataArtist, metadata.artist as NSString)
    if let artwork = metadata.artwork {
      add(.commonIdentifierArtwork, artwork as NSData, dataType: kCMMetadataBaseDataType_JPEG as String)
    }
    session.metadata = items

    try? FileManager.default.removeItem(at: output)
    try await session.export(to: output, as: .m4a)
  }
}
