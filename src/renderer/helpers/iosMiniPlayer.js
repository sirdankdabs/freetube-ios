import { reactive, shallowRef } from 'vue'

// The iOS app keeps a video playing in a mini player when leaving the watch page, like YouTube's app.
// The player itself (see detachToMini in ft-shaka-video-player.js) is moved to the mini player,
// so the playback isn't interrupted.

export const iosMiniPlayerState = reactive({
  active: false,
  videoId: '',
  title: '',
  channelName: '',
  thumbnail: '',
  playing: false,
  progress: 0
})

/** @type {import('vue').ShallowRef<HTMLElement | null>} */
export const iosMiniPlayerHost = shallowRef(null)

/**
 * @type {{
 *   container: HTMLElement,
 *   video: HTMLVideoElement,
 *   destroy: () => Promise<void>,
 *   removeListeners: () => void
 * } | null}
 */
let current = null

/**
 * @param {{ container: HTMLElement, video: HTMLVideoElement, destroy: () => Promise<void> }} handle
 * @param {{ videoId: string, title: string, channelName: string, thumbnail: string }} info
 */
export function startIOSMiniPlayer(handle, info) {
  const host = iosMiniPlayerHost.value

  if (!host) {
    handle.destroy()
    return
  }

  // there is only ever one video playing
  stopIOSMiniPlayer()

  const { video, container } = handle
  const wasPlaying = !video.paused

  const updatePlaying = () => { iosMiniPlayerState.playing = !video.paused }
  const updateProgress = () => {
    iosMiniPlayerState.progress = video.duration > 0 && isFinite(video.duration) ? Math.min(1, video.currentTime / video.duration) : 0
  }

  video.addEventListener('play', updatePlaying)
  video.addEventListener('pause', updatePlaying)
  video.addEventListener('timeupdate', updateProgress)
  video.addEventListener('ended', stopIOSMiniPlayer)

  current = {
    ...handle,
    removeListeners() {
      video.removeEventListener('play', updatePlaying)
      video.removeEventListener('pause', updatePlaying)
      video.removeEventListener('timeupdate', updateProgress)
      video.removeEventListener('ended', stopIOSMiniPlayer)
    }
  }

  container.classList.remove('fullWindow')
  container.classList.add('iosMiniVideo')
  host.appendChild(container)

  Object.assign(iosMiniPlayerState, info, { active: true, playing: wasPlaying })
  updateProgress()

  // moving the video element can interrupt it
  if (wasPlaying && video.paused) {
    video.play().catch(() => {})
  }
}

export function toggleIOSMiniPlayer() {
  const video = current?.video

  if (!video) {
    return
  }

  if (video.paused) {
    video.play().catch(() => {})
  } else {
    video.pause()
  }
}

/** @returns {number} the playback position in seconds */
export function getIOSMiniPlayerTime() {
  return current?.video.currentTime ?? 0
}

export async function stopIOSMiniPlayer() {
  const player = current

  if (!player) {
    return
  }

  current = null
  iosMiniPlayerState.active = false
  iosMiniPlayerState.playing = false
  iosMiniPlayerState.progress = 0

  player.removeListeners()
  player.video.pause()

  try {
    await player.destroy()
  } catch (error) {
    console.error(error)
  }

  player.container.remove()
}

// Called by the native app when the downloads start playing in the native player
if (process.env.IS_IOS) {
  Object.defineProperty(window, '__ftStopWebMedia', {
    value: () => {
      stopIOSMiniPlayer()
      document.querySelectorAll('video').forEach(video => video.pause())
    }
  })
}
