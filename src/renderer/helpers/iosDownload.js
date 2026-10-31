// Video downloads in the iOS app (see ios/FreeTube/DownloadManager.swift).
// The media is fetched over SABR with googlevideo's SabrStream, using the same session as the player,
// and streamed to the native app, which combines the video and audio and saves the result to Photos.
import { shallowRef } from 'vue'
import { SabrStream } from 'googlevideo/sabr-stream'
import { buildSabrFormat, EnabledTrackTypes } from 'googlevideo/utils'

/**
 * @typedef {object} IOSDownloadSource
 * @property {string} videoId
 * @property {import('../views/Watch/Watch.js').SabrData} sabrData
 * @property {import('youtubei.js').Misc.Format[]} formats
 */

/** @type {import('vue').ShallowRef<IOSDownloadSource | null>} */
export const iosDownloadSource = shallowRef(null)

/** @param {IOSDownloadSource | null} source */
export function setIOSDownloadSource(source) {
  iosDownloadSource.value = source
}

/** The chunks are sent to the native app in batches of this size */
const BATCH_SIZE = 4 * 1024 * 1024

/** @param {import('youtubei.js').Misc.Format} format */
function getCodec(format) {
  const codecs = format.mime_type.match(/codecs="?([^"]+)"?/)?.[1] ?? ''
  return codecs.split('.')[0]
}

/** @param {import('youtubei.js').Misc.Format} format */
function isHdr(format) {
  const transfer = format.color_info?.transfer_characteristics
  return transfer === 'SMPTEST2084' || transfer === 'ARIB_STD_B67' || /HDR/i.test(format.quality_label ?? '')
}

/**
 * How the native app turns the format into a video for Photos, or null if this device can't
 * - `remux`: the video is already in a codec iOS plays (H.264, or AV1 with hardware decoding), it only gets combined with the audio
 * - `transcode`: VP9 (used by YouTube for 1440p and above) gets converted to HEVC, which needs a VP9 decoder in VideoToolbox
 * @param {import('youtubei.js').Misc.Format} format
 * @returns {'remux' | 'transcode' | null}
 */
function getMode(format) {
  const capabilities = window.__ftDownloadCapabilities ?? { av1: false, vp9: false }
  const codec = getCodec(format)

  if (codec === 'avc1') {
    return 'remux'
  } else if (codec === 'av01') {
    return capabilities.av1 ? 'remux' : null
  } else if (codec === 'vp9' || codec === 'vp09') {
    return capabilities.vp9 && format.mime_type.startsWith('video/webm') ? 'transcode' : null
  }
  return null
}

const MODE_PRIORITY = { remux: 0, transcode: 1 }
const CODEC_PRIORITY = { avc1: 0, av01: 1, vp9: 2, vp09: 2 }
const CODEC_NAMES = { avc1: 'H.264', av01: 'AV1', vp9: 'VP9', vp09: 'VP9', mp4a: 'AAC', opus: 'Opus' }

/**
 * The AAC bitrate an Opus download is encoded to (see ios/FreeTube/AudioConverter.swift),
 * AAC needs about 1.6 times the bitrate of Opus for the same quality
 * @param {number} opusBitrate
 */
function aacBitrateForOpus(opusBitrate) {
  const target = opusBitrate * 1.6
  return [64_000, 96_000, 128_000, 160_000, 192_000, 256_000].find(bitrate => bitrate >= target) ?? 256_000
}

/**
 * All the audio-only formats that can be saved as M4A, the highest quality first
 * (Opus gets converted to AAC, AAC is kept as it is)
 * @param {import('youtubei.js').Misc.Format[]} formats
 */
function buildAudioOptions(formats) {
  const candidates = formats.filter(format => {
    const codec = getCodec(format)
    return format.has_audio && !format.has_video && !format.drm_families && !format.is_drc && !format.is_descriptive &&
      (codec === 'mp4a' || (codec === 'opus' && format.mime_type.startsWith('audio/webm')))
  })

  const languages = new Set(candidates.map(format => format.audio_track?.id ?? ''))

  return candidates
    .sort((a, b) => {
      const defaultA = a.audio_track?.audio_is_default || a.is_original || !a.audio_track ? 1 : 0
      const defaultB = b.audio_track?.audio_is_default || b.is_original || !b.audio_track ? 1 : 0
      return (defaultB - defaultA) || (b.bitrate - a.bitrate)
    })
    .map(format => {
      const codec = getCodec(format)
      const kbps = Math.round((format.average_bitrate ?? format.bitrate) / 1000)
      const durationSeconds = format.approx_duration_ms / 1000
      return {
        format,
        option: {
          id: String(format.itag) + (format.audio_track?.id ? `-${format.audio_track.id}` : ''),
          label: `${kbps} kbps`,
          codec: CODEC_NAMES[codec],
          mode: codec === 'opus' ? 'transcode' : 'remux',
          detail: languages.size > 1 ? (format.audio_track?.display_name ?? format.language ?? null) : null,
          bytes: codec === 'opus'
            ? durationSeconds * aacBitrateForOpus(format.average_bitrate ?? format.bitrate) / 8
            : (format.content_length ?? 0),
          outputBitrate: codec === 'opus' ? aacBitrateForOpus(format.average_bitrate ?? format.bitrate) : 0
        }
      }
    })
}

/** @param {import('youtubei.js').Misc.Format[]} formats */
function selectAudioFormat(formats) {
  const candidates = formats.filter(format => {
    return format.has_audio && !format.has_video && getCodec(format) === 'mp4a' &&
      !format.is_drc && !format.is_descriptive
  })

  candidates.sort((a, b) => {
    const defaultA = a.audio_track?.audio_is_default || a.is_original ? 1 : 0
    const defaultB = b.audio_track?.audio_is_default || b.is_original ? 1 : 0
    return (defaultB - defaultA) || (b.bitrate - a.bitrate)
  })

  return candidates[0] ?? null
}

/** @param {import('youtubei.js').Misc.Format[]} formats */
function buildQualityOptions(formats) {
  /** @type {Map<string, import('youtubei.js').Misc.Format>} */
  const bestPerQuality = new Map()

  for (const format of formats) {
    if (!format.has_video || format.has_audio || isHdr(format) || format.drm_families) {
      continue
    }
    const mode = getMode(format)
    if (mode === null) {
      continue
    }

    const fps = Math.round(format.fps ?? 30)
    const key = `${format.height}p${fps}`
    const current = bestPerQuality.get(key)

    if (
      !current ||
      MODE_PRIORITY[mode] < MODE_PRIORITY[getMode(current)] ||
      (mode === getMode(current) && CODEC_PRIORITY[getCodec(format)] < CODEC_PRIORITY[getCodec(current)]) ||
      (mode === getMode(current) && getCodec(format) === getCodec(current) && format.bitrate > current.bitrate)
    ) {
      bestPerQuality.set(key, format)
    }
  }

  return [...bestPerQuality.values()]
    .sort((a, b) => (b.height - a.height) || ((b.fps ?? 30) - (a.fps ?? 30)))
}

/** @param {string} message */
function showNativeError(message) {
  window.ftIOS.failDownload('', message)
}

/**
 * Lets the user pick a video or audio quality and downloads it into the app's downloads (and Photos for videos)
 * @param {string} title
 * @param {string} author
 */
export async function downloadVideo(title, author) {
  const source = iosDownloadSource.value
  if (!source) {
    return
  }

  const audioFormat = selectAudioFormat(source.formats)
  const videoFormats = audioFormat ? buildQualityOptions(source.formats) : []
  const audioOptions = buildAudioOptions(source.formats)

  if (videoFormats.length === 0 && audioOptions.length === 0) {
    showNativeError('This video can\'t be downloaded.')
    return
  }

  const options = videoFormats.map(format => {
    const codec = getCodec(format)
    const size = (format.content_length ?? 0) + (audioFormat.content_length ?? 0)
    return {
      id: String(format.itag),
      height: format.height,
      width: format.width,
      fps: Math.round(format.fps ?? 30),
      label: format.quality_label ?? `${format.height}p`,
      codec: CODEC_NAMES[codec],
      mode: getMode(format),
      bytes: size
    }
  })

  const choice = await window.ftIOS.chooseDownloadQuality(JSON.stringify({
    title,
    options,
    audioOptions: audioOptions.map(({ option }) => option)
  }))
  if (!choice) {
    return
  }

  const [kind, chosenId] = choice.split(':')
  const isAudio = kind === 'audio'

  /** @type {import('youtubei.js').Misc.Format} */
  let videoFormat
  /** @type {import('youtubei.js').Misc.Format} */
  let chosenAudioFormat
  let option

  if (isAudio) {
    const chosen = audioOptions.find(({ option }) => option.id === chosenId)
    chosenAudioFormat = chosen.format
    option = chosen.option
    // SABR needs a video format even when only the audio is downloaded, it gets discarded
    videoFormat = source.formats
      .filter(format => format.has_video && !format.has_audio)
      .reduce((smallest, format) => (!smallest || format.bitrate < smallest.bitrate ? format : smallest), null)
  } else {
    videoFormat = videoFormats.find(format => String(format.itag) === chosenId)
    chosenAudioFormat = audioFormat
    option = options.find(option => option.id === chosenId)
  }

  const id = crypto.randomUUID()
  const durationMs = isAudio
    ? chosenAudioFormat.approx_duration_ms
    : Math.min(videoFormat.approx_duration_ms, chosenAudioFormat.approx_duration_ms)

  try {
    await window.ftIOS.beginDownload(JSON.stringify({
      id,
      kind: isAudio ? 'audio' : 'video',
      videoId: source.videoId,
      author: author ?? '',
      title,
      label: isAudio
        ? `AAC ${option.mode === 'transcode' ? Math.round(option.outputBitrate / 1000) + ' kbps' : option.label}`
        : option.label,
      mode: option.mode,
      videoMimeType: isAudio ? '' : videoFormat.mime_type,
      audioMimeType: chosenAudioFormat.mime_type,
      width: isAudio ? 0 : videoFormat.width,
      height: isAudio ? 0 : videoFormat.height,
      fps: isAudio ? 0 : (videoFormat.fps ?? 30),
      bitrate: isAudio ? (option.outputBitrate || chosenAudioFormat.bitrate) : videoFormat.bitrate,
      durationMs,
      expectedBytes: isAudio ? (chosenAudioFormat.content_length || option.bytes) : option.bytes
    }))
  } catch (error) {
    // the native app shows the reason, e.g. another download is already running
    console.warn(error)
    return
  }

  const { sabrData } = source

  const sabrStream = new SabrStream({
    fetch: (input, init) => fetch(input, init),
    serverAbrStreamingUrl: sabrData.url,
    videoPlaybackUstreamerConfig: sabrData.ustreamerConfig,
    clientInfo: sabrData.clientInfo,
    poToken: sabrData.poToken,
    durationMs,
    formats: source.formats.map(format => buildSabrFormat(format))
  })

  let sessionError = null
  sabrStream.on('reloadPlayerResponse', () => {
    sessionError = 'YouTube ended the streaming session. Reload the video and try again.'
    sabrStream.abort()
  })

  try {
    const { videoStream, audioStream } = await sabrStream.start({
      videoFormat: buildSabrFormat(videoFormat),
      audioFormat: buildSabrFormat(chosenAudioFormat),
      enabledTrackTypes: isAudio ? EnabledTrackTypes.AUDIO_ONLY : EnabledTrackTypes.VIDEO_AND_AUDIO
    })

    if (isAudio) {
      // nothing is sent on the video stream, but it still has to be read for the stream to finish
      await Promise.all([
        videoStream.pipeTo(new WritableStream()),
        sendStream(id, 'audio', audioStream)
      ])
    } else {
      await Promise.all([
        sendStream(id, 'video', videoStream),
        sendStream(id, 'audio', audioStream)
      ])
    }

    if (sessionError) {
      throw new Error(sessionError)
    }

    await window.ftIOS.finishDownload(id)
  } catch (error) {
    sabrStream.abort()
    if (!(error instanceof DownloadCancelledError)) {
      console.error(error)
      window.ftIOS.failDownload(id, sessionError ?? String(error?.message ?? error))
    }
  }
}

class DownloadCancelledError extends Error {}

/**
 * @param {string} id
 * @param {'video' | 'audio'} track
 * @param {ReadableStream<Uint8Array>} stream
 */
async function sendStream(id, track, stream) {
  const reader = stream.getReader()
  /** @type {Uint8Array[]} */
  let pending = []
  let pendingSize = 0

  const flush = async () => {
    if (pendingSize === 0) {
      return
    }

    const body = new Uint8Array(pendingSize)
    let offset = 0
    for (const chunk of pending) {
      body.set(chunk, offset)
      offset += chunk.byteLength
    }
    pending = []
    pendingSize = 0

    const response = await fetch(`/__download__?id=${encodeURIComponent(id)}&track=${track}`, {
      method: 'POST',
      body: body.buffer
    })

    if (response.status === 410) {
      throw new DownloadCancelledError()
    } else if (!response.ok) {
      throw new Error(`Saving the download failed (${response.status})`)
    }
  }

  try {
    while (true) {
      const { done, value } = await reader.read()
      if (done) {
        break
      }
      pending.push(value)
      pendingSize += value.byteLength

      if (pendingSize >= BATCH_SIZE) {
        await flush()
      }
    }
    await flush()
  } finally {
    reader.releaseLock()
  }
}
