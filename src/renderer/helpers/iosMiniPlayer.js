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
  handoff: false,
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
  video.addEventListener('ended', updatePlaying)

  current = {
    ...handle,
    removeListeners() {
      video.removeEventListener('play', updatePlaying)
      video.removeEventListener('pause', updatePlaying)
      video.removeEventListener('timeupdate', updateProgress)
      video.removeEventListener('ended', updatePlaying)
    }
  }

  container.classList.remove('fullWindow')
  container.classList.add('iosMiniVideo')

  // moving the video element with appendChild pauses it, so resume it in the same tick (before it is rendered as paused)
  const resumeOnPause = () => { video.play().catch(() => {}) }
  if (wasPlaying) {
    video.addEventListener('pause', resumeOnPause)
  }

  // moveBefore moves the element without resetting its state (the playback keeps going)
  let moved = false
  if (typeof host.moveBefore === 'function' && container.isConnected) {
    try {
      host.moveBefore(container, null)
      moved = true
    } catch {}
  }
  if (!moved) {
    host.appendChild(container)
  }

  Object.assign(iosMiniPlayerState, info, { active: true, playing: wasPlaying })
  updateProgress()

  if (wasPlaying && video.paused) {
    video.play().catch(() => {})
  }

  setTimeout(() => video.removeEventListener('pause', resumeOnPause), 1000)
}

/**
 * Called when the mini player is expanded into the watch page: the video keeps playing (hidden) while the watch page
 * loads the same video, and is stopped as soon as the new player starts, so the sound isn't interrupted.
 */
export function handoffIOSMiniPlayer() {
  const video = current?.video

  if (!video) {
    return
  }

  const finish = (event) => {
    const target = event?.target

    if (event && (!(target instanceof HTMLVideoElement) || target === video)) {
      return
    }

    document.removeEventListener('playing', finish, true)
    clearTimeout(timeoutId)

    if (event && target.currentTime < video.currentTime && video.currentTime - target.currentTime < 30) {
      // the sound of the mini player went on while the watch page was loading
      target.currentTime = video.currentTime
    }

    iosMiniPlayerState.handoff = false
    document.body.classList.remove('iosMiniPlayerHandoff')
    stopIOSMiniPlayer()
  }

  const timeoutId = setTimeout(() => finish(null), 15000)

  iosMiniPlayerState.handoff = true
  document.body.classList.add('iosMiniPlayerHandoff')
  document.addEventListener('playing', finish, true)
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
