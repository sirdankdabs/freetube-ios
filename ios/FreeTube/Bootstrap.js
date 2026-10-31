// Injected at document start into the main frame of the app's web view (see WebViewController.swift).
// Routes all external fetch and XMLHttpRequest requests through the native proxy (AppSchemeHandler.swift),
// which removes the CORS restrictions and sets the headers YouTube expects, the same as the Electron main process does.
// It also exposes the native features the web app uses as `window.ftIOS`.
(() => {
  'use strict'

  const PROXY_PREFIX = `${location.origin}/__proxy__?url=`
  const FINAL_URL_HEADER = 'X-FT-Final-URL'

  /** @param {string} url */
  function toProxyUrl(url) {
    return PROXY_PREFIX + encodeURIComponent(url)
  }

  /**
   * @param {string | URL} input
   * @returns {URL | null} the absolute URL if it is an external one
   */
  function externalUrl(input) {
    try {
      const url = new URL(input, location.href)
      return url.protocol === 'https:' || url.protocol === 'http:' ? url : null
    } catch {
      return null
    }
  }

  // #region fetch

  const nativeFetch = window.fetch
  const urlGetter = Object.getOwnPropertyDescriptor(Response.prototype, 'url').get
  const redirectedGetter = Object.getOwnPropertyDescriptor(Response.prototype, 'redirected').get

  /** @type {WeakMap<Response, string>} */
  const responseUrls = new WeakMap()
  const requestUrlSymbol = Symbol('requestUrl')

  // Make Response.url return the original URL rather than the proxy one, so that the web app sees the same URLs as on desktop
  Object.defineProperty(Response.prototype, 'url', {
    configurable: true,
    enumerable: true,
    get() {
      return responseUrls.get(this) ?? urlGetter.call(this)
    }
  })

  Object.defineProperty(Response.prototype, 'redirected', {
    configurable: true,
    enumerable: true,
    get() {
      const originalUrl = responseUrls.get(this)
      if (originalUrl !== undefined) {
        return this.headers.has(FINAL_URL_HEADER) && this.headers.get(FINAL_URL_HEADER) !== this[requestUrlSymbol]
      }
      return redirectedGetter.call(this)
    }
  })

  const nativeClone = Response.prototype.clone
  Response.prototype.clone = function () {
    const clone = nativeClone.call(this)
    const originalUrl = responseUrls.get(this)
    if (originalUrl !== undefined) {
      responseUrls.set(clone, originalUrl)
      clone[requestUrlSymbol] = this[requestUrlSymbol]
    }
    return clone
  }

  /**
   * @param {RequestInfo | URL} input
   * @param {RequestInit} [init]
   */
  async function proxiedFetch(input, init) {
    const isRequest = input instanceof Request
    const url = externalUrl(isRequest ? input.url : input)

    if (url === null) {
      return nativeFetch.call(window, input, init)
    }

    const method = (init?.method ?? (isRequest ? input.method : 'GET')).toUpperCase()

    const headers = new Headers(isRequest ? input.headers : undefined)
    if (init?.headers) {
      new Headers(init.headers).forEach((value, name) => headers.set(name, value))
    }

    let body = init?.body
    if (body === undefined && isRequest && method !== 'GET' && method !== 'HEAD') {
      body = await input.clone().arrayBuffer()
    }
    if (body instanceof ReadableStream) {
      body = await new Response(body).arrayBuffer()
    }

    const response = await nativeFetch.call(window, toProxyUrl(url.href), {
      method,
      headers,
      body: method === 'GET' || method === 'HEAD' ? undefined : body,
      signal: init?.signal ?? (isRequest ? input.signal : undefined),
      credentials: 'omit',
      cache: 'no-store',
      redirect: 'follow',
    })

    response[requestUrlSymbol] = url.href
    responseUrls.set(response, response.headers.get(FINAL_URL_HEADER) ?? url.href)
    return response
  }

  window.fetch = proxiedFetch

  // #endregion fetch

  // #region XMLHttpRequest

  const nativeOpen = XMLHttpRequest.prototype.open
  XMLHttpRequest.prototype.open = function (method, url, ...rest) {
    const external = externalUrl(url)
    return nativeOpen.call(this, method, external === null ? url : toProxyUrl(external.href), ...rest)
  }

  const responseURLGetter = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseURL').get
  Object.defineProperty(XMLHttpRequest.prototype, 'responseURL', {
    configurable: true,
    enumerable: true,
    get() {
      const value = responseURLGetter.call(this)
      if (value.startsWith(PROXY_PREFIX)) {
        return this.getResponseHeader(FINAL_URL_HEADER) ?? decodeURIComponent(value.substring(PROXY_PREFIX.length))
      }
      return value
    }
  })

  // #endregion XMLHttpRequest

  // The web app never needs these and they would bypass the proxy
  navigator.sendBeacon = () => false

  // #region codecs

  // WebKit can claim support for AV1 and VP9 on devices that can only decode them in software, or not at all
  // (e.g. iPhones without AV1 hardware, or the simulator), so only offer them when there is hardware decoding.
  // The player then falls back to the next codec (VP9, then H.264), which is also much better for the battery.
  const hardwareDecode = window.__ftHardwareDecode ?? { av1: false, vp9: false }

  /** @param {string} type */
  function isCodecAllowed(type) {
    const codecs = type.toLowerCase()
    if (!hardwareDecode.av1 && codecs.includes('av01')) {
      return false
    }
    if (!hardwareDecode.vp9 && (codecs.includes('vp09') || /\bvp9\b/.test(codecs))) {
      return false
    }
    return true
  }

  for (const MediaSourceClass of [window.ManagedMediaSource, window.MediaSource]) {
    if (MediaSourceClass) {
      const nativeIsTypeSupported = MediaSourceClass.isTypeSupported.bind(MediaSourceClass)
      MediaSourceClass.isTypeSupported = (type) => isCodecAllowed(type) && nativeIsTypeSupported(type)
    }
  }

  if (navigator.mediaCapabilities) {
    const nativeDecodingInfo = navigator.mediaCapabilities.decodingInfo.bind(navigator.mediaCapabilities)
    navigator.mediaCapabilities.decodingInfo = (configuration) => {
      const contentType = configuration?.video?.contentType
      if (contentType && !isCodecAllowed(contentType)) {
        return Promise.resolve({ supported: false, smooth: false, powerEfficient: false, configuration })
      }
      return nativeDecodingInfo(configuration)
    }
  }

  // #endregion codecs

  // #region background playback

  // iOS pauses the videos of web views when the app goes to the background or the screen is locked.
  // Playback is resumed straight away (as audio, the app has the audio background mode),
  // unless the user paused it, e.g. with the controls on the lock screen.
  /** @type {HTMLMediaElement | null} */
  let activeMedia = null
  let userPaused = false
  const hiddenAt = 0

  document.addEventListener('play', (event) => {
    if (event.target instanceof HTMLMediaElement) {
      activeMedia = event.target
      userPaused = false
    }
  }, true)

  document.addEventListener('pause', (event) => {
    const media = event.target
    if (!(media instanceof HTMLMediaElement) || media !== activeMedia || media.ended || userPaused) {
      return
    }

    if (document.hidden || performance.now() - hiddenAt < 1500) {
      resume(media, 0)
      return
    }

    // WebKit pauses the media before the page becomes hidden, so wait a moment before deciding that the user paused it
    const pausedAt = performance.now()
    setTimeout(() => {
      if (media !== activeMedia || !media.paused || userPaused) {
        return
      }
      if (document.hidden || hiddenAt >= pausedAt || appInBackground) {
        resume(media, 0)
      } else {
        userPaused = true
      }
    }, 700)
  }, true)

  // Called by the native app (see BackgroundPlayback in WebViewController.swift)
  let appInBackground = false
  Object.defineProperty(window, '__ftAppStateChanged', {
    value: (event) => {
      if (!activeMedia) {
        return
      }
      switch (event) {
        case 'willResignActive':
          enterPictureInPicture(0)
          break
        case 'didEnterBackground':
          appInBackground = true
          if (activeMedia.paused && !userPaused && !activeMedia.ended) {
            resume(activeMedia, 0)
          }
          break
        case 'didBecomeActive':
          appInBackground = false
          break
      }
    }
  })

  /**
   * @param {HTMLMediaElement} media
   * @param {number} attempt
   */
  function resume(media, attempt) {
    setTimeout(() => {
      if (userPaused || media !== activeMedia || media.ended || !media.paused || !media.isConnected) {
        return
      }
      // the native app can resume it even when WebKit doesn't allow the page to (see BackgroundPlayback in WebViewController.swift)
      window.webkit.messageHandlers.ftResumePlayback.postMessage('')
      if (attempt < 3) {
        resume(media, attempt + 1)
      }
    }, attempt === 0 ? 300 : 1000)
  }

  if ('mediaSession' in navigator) {
    const setHandler = (action, handler) => {
      try {
        navigator.mediaSession.setActionHandler(action, handler)
      } catch {}
    }

    setHandler('play', () => {
      userPaused = false
      if (document.hidden) {
        // play() from the page is deferred by WebKit while the app is in the background
        window.webkit.messageHandlers.ftResumePlayback.postMessage('')
      } else {
        activeMedia?.play()
      }
    })
    setHandler('pause', () => {
      userPaused = true
      activeMedia?.pause()
    })
    setHandler('enterpictureinpicture', () => enterPictureInPicture(0))
    setHandler('seekbackward', (details) => {
      if (activeMedia) {
        activeMedia.currentTime = Math.max(0, activeMedia.currentTime - (details.seekOffset ?? 10))
      }
    })
    setHandler('seekforward', (details) => {
      if (activeMedia) {
        activeMedia.currentTime = Math.min(activeMedia.duration || Infinity, activeMedia.currentTime + (details.seekOffset ?? 10))
      }
    })
    setHandler('seekto', (details) => {
      if (activeMedia && typeof details.seekTime === 'number') {
        activeMedia.currentTime = details.seekTime
      }
    })
  }

  // picture in picture when leaving the app while the video plays
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) {
      enterPictureInPicture(0)
    }
  })

  /** @param {number} attempt */
  function enterPictureInPicture(attempt) {
    const playing = [...document.querySelectorAll('video')].filter(video => !video.paused && !video.ended && video.readyState > 1)
    const media = playing.includes(activeMedia) ? activeMedia : playing[0]

    if (!media || media.webkitPresentationMode === 'picture-in-picture') {
      return
    }

    media.disablePictureInPicture = false
    media.removeAttribute('disablepictureinpicture')

    try {
      if (media.webkitSupportsPresentationMode?.('picture-in-picture')) {
        media.webkitSetPresentationMode('picture-in-picture')
      } else {
        media.requestPictureInPicture?.().catch(() => {})
      }
    } catch {}

    // WebKit sometimes ignores the first request while the app is changing state, so insist a few times
    if (attempt < 4) {
      setTimeout(() => enterPictureInPicture(attempt + 1), 150 * (attempt + 1))
    }
  }

  // #endregion background playback

  // #region pull down to leave the watch page

  // Dragging down at the top of the watch page moves the page with the finger, like YouTube's app.
  // Letting go far enough goes back (the video keeps playing in the mini player), otherwise the page springs back.
  const isWatchPage = () => location.hash.startsWith('#/watch/')
  const postRoute = () => window.webkit.messageHandlers.ftRoute.postMessage(isWatchPage() ? 'watch' : 'other')
  window.addEventListener('hashchange', postRoute)
  document.addEventListener('DOMContentLoaded', postRoute)

  let dragStartX = 0
  let dragStartY = 0
  let dragLastY = 0
  let dragLastTime = 0
  let dragVelocity = 0
  let dragArmed = false
  let dragging = false
  let dragDistance = 0

  const blockedSelector = 'input, textarea, .shaka-range-element, .shaka-seek-bar-container, .shaka-overflow-menu, .fullWindow, .iosMiniVideo, .iosMiniPlayer'

  /** @param {EventTarget | null} target */
  function canStartDrag(target) {
    if (!isWatchPage() || window.scrollY > 0 || document.fullscreenElement || !(target instanceof Element)) {
      return false
    }
    if (target.closest(blockedSelector)) {
      return false
    }
    // something inside the page is scrolled
    for (let element = target; element && element !== document.body; element = element.parentElement) {
      if (element.scrollTop > 0) {
        return false
      }
    }
    return true
  }

  const pageElement = () => document.getElementById('app')

  function setDrag(distance, animated) {
    const page = pageElement()
    if (!page) {
      return
    }
    const progress = Math.min(1, distance / 600)
    page.style.transition = animated ? 'transform 0.25s cubic-bezier(0.2, 0.8, 0.2, 1), opacity 0.25s' : 'none'
    page.style.transform = distance > 0 ? `translateY(${distance}px) scale(${1 - progress * 0.06})` : ''
    page.style.transformOrigin = 'center top'
    page.style.borderRadius = distance > 0 ? '24px' : ''
    page.style.opacity = distance > 0 ? String(1 - progress * 0.3) : ''
    page.style.overflow = distance > 0 ? 'hidden' : ''
  }

  document.addEventListener('touchstart', (event) => {
    dragArmed = event.touches.length === 1 && canStartDrag(event.target)
    dragging = false
    dragDistance = 0
    dragVelocity = 0
    if (dragArmed) {
      dragStartX = event.touches[0].clientX
      dragStartY = dragLastY = event.touches[0].clientY
      dragLastTime = performance.now()
    }
  }, { capture: true, passive: true })

  document.addEventListener('touchmove', (event) => {
    if (!dragArmed) {
      return
    }
    const touch = event.touches[0]
    const dy = touch.clientY - dragStartY
    const dx = touch.clientX - dragStartX

    if (!dragging) {
      if (dy < -6 || Math.abs(dx) > 12 && Math.abs(dx) > dy) {
        dragArmed = false
        return
      }
      if (dy > 10 && dy > Math.abs(dx) * 1.5) {
        dragging = true
      } else {
        return
      }
    }

    event.preventDefault()
    const now = performance.now()
    dragVelocity = (touch.clientY - dragLastY) / Math.max(1, now - dragLastTime)
    dragLastY = touch.clientY
    dragLastTime = now
    dragDistance = Math.max(0, dy - 10)
    setDrag(dragDistance, false)
  }, { capture: true, passive: false })

  const endDrag = (cancelled) => {
    if (!dragging) {
      dragArmed = false
      return
    }
    dragArmed = false
    dragging = false

    if (!cancelled && (dragDistance > 140 || dragVelocity > 0.7) && history.length > 1) {
      setDrag(window.innerHeight, true)
      setTimeout(() => {
        history.back()
        setTimeout(() => setDrag(0, false), 150)
      }, 220)
    } else {
      setDrag(0, true)
      setTimeout(() => setDrag(0, false), 300)
    }
  }

  document.addEventListener('touchend', () => endDrag(false), { capture: true, passive: true })
  document.addEventListener('touchcancel', () => endDrag(true), { capture: true, passive: true })

  // #endregion pull down to leave the watch page

  // #region native bridge

  const bridge = window.webkit.messageHandlers.ftIOS

  Object.defineProperty(window, 'ftIOS', {
    configurable: false,
    enumerable: false,
    writable: false,
    value: Object.freeze({
      /**
       * @param {string} videoId
       * @param {string} context JSON
       * @param {string} initialAttestationData JSON
       * @param {string} ytConfig JSON
       * @returns {Promise<string>}
       */
      generatePoToken(videoId, context, initialAttestationData, ytConfig) {
        return bridge.postMessage({
          action: 'generatePoToken',
          args: [videoId, context, initialAttestationData, ytConfig]
        })
      },

      // Video downloads, see src/renderer/helpers/iosDownload.js and DownloadManager.swift

      /**
       * Shows the quality picker
       * @param {string} options JSON
       * @returns {Promise<string | null>} the id of the chosen option
       */
      chooseDownloadQuality(options) {
        return bridge.postMessage({ action: 'chooseDownloadQuality', args: [options] })
      },

      /**
       * @param {string} download JSON
       * @returns {Promise<boolean>} rejects if the download can't be started
       */
      beginDownload(download) {
        return bridge.postMessage({ action: 'beginDownload', args: [download] })
      },

      /** @param {string} id */
      finishDownload(id) {
        return bridge.postMessage({ action: 'finishDownload', args: [id] })
      },

      /**
       * @param {string} id empty to show the message without a download
       * @param {string} message
       */
      failDownload(id, message) {
        return bridge.postMessage({ action: 'failDownload', args: [id, message] })
      },

      // The player's fullscreen, see setUpIOSFullscreen in ft-shaka-video-player.js

      /** @param {boolean} fullscreen hides the app's controls, the status bar and the home indicator */
      setPlayerFullscreen(fullscreen) {
        return bridge.postMessage({ action: 'setPlayerFullscreen', args: [fullscreen ? 'true' : 'false'] })
      },

      /**
       * @param {'landscape' | 'portrait' | 'landscape-auto' | 'portrait-auto' | 'auto'} mode
       * the `-auto` modes unlock the orientation once the device is held that way
       */
      setOrientation(mode) {
        return bridge.postMessage({ action: 'setOrientation', args: [mode] })
      }
    })
  })

  // #endregion native bridge

  // #region native chrome

  // The native Liquid Glass controls replace the top and side navigation (see NativeChrome.swift).
  // They need the navigation state (see the iOS region in src/renderer/components/TopNav/TopNav.vue)
  // and the theme colours, so that they match the selected FreeTube theme.

  // Called by the native app with the space the controls take up, see src/renderer/ios.css
  const insetsStyle = document.createElement('style')
  Object.defineProperty(window, '__ftSetInsets', {
    value: (top, bottom) => {
      insetsStyle.textContent = `html:root { --ios-inset-top: ${top}px; --ios-inset-bottom: ${bottom}px; }`
      if (!insetsStyle.isConnected) {
        (document.head ?? document.documentElement).appendChild(insetsStyle)
      }
    }
  })
  document.addEventListener('DOMContentLoaded', () => document.head.appendChild(insetsStyle))

  // Called by the native app when the tab bar is hidden or shown while scrolling (the mini player moves with it)
  Object.defineProperty(window, '__ftSetBarMinimized', {
    value: (minimized) => {
      document.documentElement.toggleAttribute('data-ios-bar-minimized', minimized)
    }
  })

  // Only one thing plays at a time: the native player of the downloads stops when a video starts here
  document.addEventListener('play', (event) => {
    if (event.target instanceof HTMLVideoElement) {
      bridge.postMessage({ action: 'webMediaPlaying', args: [] })
    }
  }, true)

  window.addEventListener('ft-ios-state', (event) => {
    window.webkit.messageHandlers.ftNav.postMessage(event.detail)
  })

  let lastReported = ''
  let scheduled = false

  function reportColors() {
    scheduled = false

    const rootStyle = getComputedStyle(document.documentElement)
    const page = rootStyle.getPropertyValue('--bg-color').trim() || getComputedStyle(document.body).backgroundColor
    const card = rootStyle.getPropertyValue('--card-bg-color').trim() || page
    const accent = rootStyle.getPropertyValue('--primary-color').trim()
    const text = rootStyle.getPropertyValue('--primary-text-color').trim()

    // Lets src/renderer/ios.css pick the OLED black or the light style for the menus and dialogs
    const [r, g, b] = (getComputedStyle(document.body).backgroundColor.match(/[\d.]+/g) ?? ['255', '255', '255']).map(Number)
    const appearance = (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.6 ? 'light' : 'dark'
    if (document.documentElement.dataset.iosAppearance !== appearance) {
      document.documentElement.dataset.iosAppearance = appearance
    }

    // with the System base theme the native screens follow the system appearance instead of the theme
    const followsSystem = document.body.classList.contains('system')

    const value = JSON.stringify({ page, card, accent, text, followsSystem: String(followsSystem) })
    if (value !== lastReported) {
      lastReported = value
      window.webkit.messageHandlers.ftTheme.postMessage(value)
    }
  }

  function scheduleReport() {
    if (!scheduled) {
      scheduled = true
      requestAnimationFrame(reportColors)
    }
  }

  document.addEventListener('DOMContentLoaded', () => {
    // the theme classes are set on the body and the main color variables on the document element
    const observer = new MutationObserver(scheduleReport)
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ['class', 'style'] })
    // the data-ios-appearance attribute set above isn't observed, so that setting it doesn't trigger another report
    observer.observe(document.body, { attributes: true, attributeFilter: ['class', 'style'] })
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', scheduleReport)
    scheduleReport()
  })

  // #endregion native chrome
})()
