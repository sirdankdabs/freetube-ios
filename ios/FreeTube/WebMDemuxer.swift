import CoreMedia
import Foundation

/// A minimal WebM (Matroska) demuxer for the single track VP9 and Opus streams YouTube serves,
/// as AVFoundation can't read WebM files. It reads the track information and the frames of the first track of the requested type.
struct WebMDemuxer {
  struct Frame {
    let range: Range<Int>
    let presentationTime: CMTime
    let isKeyframe: Bool
  }

  struct Track {
    var number: UInt64 = 0
    var codecId = ""
    var width = 0
    var height = 0
    var sampleRate: Double = 0
    var channels = 0
    var codecPrivate = Data()
  }

  enum TrackType: UInt64 {
    case video = 1
    case audio = 2
  }

  enum DemuxError: LocalizedError {
    case invalidFile
    case noVideoTrack
    case noAudioTrack

    var errorDescription: String? {
      switch self {
      case .invalidFile: return "The downloaded file is damaged."
      case .noVideoTrack: return "The downloaded video file has no video."
      case .noAudioTrack: return "The downloaded audio file has no audio."
      }
    }
  }

  let data: Data
  private(set) var track = Track()
  private(set) var frames: [Frame] = []

  // Element IDs, see https://www.matroska.org/technical/elements.html
  private static let segment: UInt32 = 0x1853_8067
  private static let info: UInt32 = 0x1549_A966
  private static let timestampScale: UInt32 = 0x2AD7B1
  private static let tracks: UInt32 = 0x1654_AE6B
  private static let trackEntry: UInt32 = 0xAE
  private static let trackNumber: UInt32 = 0xD7
  private static let trackType: UInt32 = 0x83
  private static let codecId: UInt32 = 0x86
  private static let video: UInt32 = 0xE0
  private static let pixelWidth: UInt32 = 0xB0
  private static let pixelHeight: UInt32 = 0xBA
  private static let audio: UInt32 = 0xE1
  private static let samplingFrequency: UInt32 = 0xB5
  private static let channels: UInt32 = 0x9F
  private static let codecPrivate: UInt32 = 0x63A2
  private static let cluster: UInt32 = 0x1F43_B675
  private static let clusterTimestamp: UInt32 = 0xE7
  private static let simpleBlock: UInt32 = 0xA3
  private static let blockGroup: UInt32 = 0xA0
  private static let block: UInt32 = 0xA1

  /// Elements that are read by descending into their children
  private static let masterElements: Set<UInt32> = [segment, info, tracks, trackEntry, video, audio, cluster, blockGroup]

  private let trackType: TrackType

  init(url: URL, trackType: TrackType = .video) throws {
    data = try Data(contentsOf: url, options: .alwaysMapped)
    self.trackType = trackType
    try parse()
  }

  private mutating func parse() throws {
    var position = 0
    var scale: UInt64 = 1_000_000
    var clusterTime: Int64 = 0
    var currentTrack = Track()
    var currentTrackType: UInt64 = 0
    var selectedTrackNumber: UInt64?
    var track = Track()
    var frames: [Frame] = []
    let data = self.data

    try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
      let bytes = buffer.bindMemory(to: UInt8.self)
      let count = bytes.count

      while position < count {
        guard
          case let (id, idLength)? = WebMDemuxer.readElementId(bytes, at: position),
          case let (size, sizeLength)? = WebMDemuxer.readVint(bytes, at: position + idLength)
        else {
          // trailing garbage after the last complete element
          break
        }
        let dataStart = position + idLength + sizeLength
        let dataEnd = size.map { min(dataStart + Int($0), count) } ?? count

        if WebMDemuxer.masterElements.contains(id) {
          if id == WebMDemuxer.trackEntry {
            currentTrack = Track()
            currentTrackType = 0
          } else if id == WebMDemuxer.cluster {
            clusterTime = 0
          }
          position = dataStart

          if id == WebMDemuxer.trackEntry {
            // read the whole track entry now, so that its fields are complete when it ends
            var inner = dataStart
            while inner < dataEnd {
              guard
                case let (childId, childIdLength)? = WebMDemuxer.readElementId(bytes, at: inner),
                case let (childSize, childSizeLength)? = WebMDemuxer.readVint(bytes, at: inner + childIdLength),
                let childLength = childSize
              else { throw DemuxError.invalidFile }
              let childStart = inner + childIdLength + childSizeLength
              let childEnd = min(childStart + Int(childLength), dataEnd)

              switch childId {
              case WebMDemuxer.trackNumber: currentTrack.number = WebMDemuxer.readUInt(bytes, childStart..<childEnd)
              case WebMDemuxer.trackType: currentTrackType = WebMDemuxer.readUInt(bytes, childStart..<childEnd)
              case WebMDemuxer.codecId: currentTrack.codecId = String(decoding: UnsafeRawBufferPointer(rebasing: buffer[childStart..<childEnd]), as: UTF8.self)
              case WebMDemuxer.video, WebMDemuxer.audio:
                inner = childStart
                continue
              case WebMDemuxer.samplingFrequency: currentTrack.sampleRate = WebMDemuxer.readFloat(bytes, childStart..<childEnd)
              case WebMDemuxer.channels: currentTrack.channels = Int(WebMDemuxer.readUInt(bytes, childStart..<childEnd))
              case WebMDemuxer.codecPrivate: currentTrack.codecPrivate = Data(UnsafeRawBufferPointer(rebasing: buffer[childStart..<childEnd]))
              case WebMDemuxer.pixelWidth: currentTrack.width = Int(WebMDemuxer.readUInt(bytes, childStart..<childEnd))
              case WebMDemuxer.pixelHeight: currentTrack.height = Int(WebMDemuxer.readUInt(bytes, childStart..<childEnd))
              default: break
              }
              inner = childEnd
            }

            if currentTrackType == trackType.rawValue && selectedTrackNumber == nil {
              selectedTrackNumber = currentTrack.number
              track = currentTrack
            }
            position = dataEnd
          }
          continue
        }

        switch id {
        case WebMDemuxer.timestampScale:
          scale = WebMDemuxer.readUInt(bytes, dataStart..<dataEnd)
        case WebMDemuxer.clusterTimestamp:
          clusterTime = Int64(WebMDemuxer.readUInt(bytes, dataStart..<dataEnd))
        case WebMDemuxer.simpleBlock, WebMDemuxer.block:
          guard
            case let (blockTrack, trackLength)? = WebMDemuxer.readVint(bytes, at: dataStart),
            dataStart + trackLength + 3 <= dataEnd
          else { throw DemuxError.invalidFile }

          let headerStart = dataStart + trackLength
          let relative = Int16(bitPattern: UInt16(bytes[headerStart]) << 8 | UInt16(bytes[headerStart + 1]))
          let flags = bytes[headerStart + 2]
          let frameStart = headerStart + 3

          if blockTrack == selectedTrackNumber, flags & 0x06 == 0, frameStart < dataEnd {
            let timestamp = (clusterTime + Int64(relative)) * Int64(scale)
            frames.append(Frame(
              range: frameStart..<dataEnd,
              presentationTime: CMTime(value: timestamp, timescale: 1_000_000_000),
              // SimpleBlocks flag keyframes, Blocks without references are keyframes too
              isKeyframe: id == WebMDemuxer.block || flags & 0x80 != 0
            ))
          }
        default:
          break
        }

        position = dataEnd
      }
    }

    switch trackType {
    case .video:
      guard selectedTrackNumber != nil, track.width > 0, track.height > 0, !frames.isEmpty else {
        throw DemuxError.noVideoTrack
      }
    case .audio:
      guard selectedTrackNumber != nil, track.channels > 0, !frames.isEmpty else {
        throw DemuxError.noAudioTrack
      }
    }
    // blocks can arrive slightly out of order across fragments
    frames.sort { $0.presentationTime < $1.presentationTime }
    self.track = track
    self.frames = frames
  }

  private static func readElementId(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> (UInt32, Int)? {
    guard position < bytes.count else { return nil }
    let first = bytes[position]
    let length = first.leadingZeroBitCount + 1
    guard length <= 4, position + length <= bytes.count else { return nil }
    var value = UInt32(first)
    for index in 1..<length {
      value = value << 8 | UInt32(bytes[position + index])
    }
    return (value, length)
  }

  /// Returns nil as the value for unknown sizes
  private static func readVint(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> (UInt64?, Int)? {
    guard position < bytes.count else { return nil }
    let first = bytes[position]
    let length = first.leadingZeroBitCount + 1
    guard length <= 8, position + length <= bytes.count else { return nil }
    var value = UInt64(first) & ((1 << (8 - length)) - 1)
    var allOnes = value == (1 << (8 - length)) - 1
    for index in 1..<length {
      let byte = bytes[position + index]
      allOnes = allOnes && byte == 0xFF
      value = value << 8 | UInt64(byte)
    }
    return (allOnes ? nil : value, length)
  }

  private static func readFloat(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> Double {
    let bits = readUInt(bytes, range)
    return range.count == 4 ? Double(Float(bitPattern: UInt32(bits))) : Double(bitPattern: bits)
  }

  private static func readUInt(_ bytes: UnsafeBufferPointer<UInt8>, _ range: Range<Int>) -> UInt64 {
    var value: UInt64 = 0
    for index in range.prefix(8) {
      value = value << 8 | UInt64(bytes[index])
    }
    return value
  }
}
