import shaka from 'shaka-player'

import i18n from '../../../i18n/index'

// The iOS app's fullscreen keeps the player's own controls (like YouTube's app),
// instead of using the system's video player, see setUpIOSFullscreen in ft-shaka-video-player.js

const FULLSCREEN_ICON = 'M200-200h80q17 0 28.5 11.5T320-160q0 17-11.5 28.5T280-120H160q-17 0-28.5-11.5T120-160v-120q0-17 11.5-28.5T160-320q17 0 28.5 11.5T200-280v80Zm560 0v-80q0-17 11.5-28.5T800-320q17 0 28.5 11.5T840-280v120q0 17-11.5 28.5T800-120H680q-17 0-28.5-11.5T640-160q0-17 11.5-28.5T680-200h80ZM200-760v80q0 17-11.5 28.5T160-640q-17 0-28.5-11.5T120-680v-120q0-17 11.5-28.5T160-840h120q17 0 28.5 11.5T320-800q0 17-11.5 28.5T280-760h-80Zm560 0h-80q-17 0-28.5-11.5T640-800q0-17 11.5-28.5T680-840h120q17 0 28.5 11.5T840-800v120q0 17-11.5 28.5T800-640q-17 0-28.5-11.5T760-680v-80Z'
const EXIT_FULLSCREEN_ICON = 'M240-240h-80q-17 0-28.5-11.5T120-280q0-17 11.5-28.5T160-320h120q17 0 28.5 11.5T320-280v120q0 17-11.5 28.5T280-120q-17 0-28.5-11.5T240-160v-80Zm480 0v80q0 17-11.5 28.5T680-120q-17 0-28.5-11.5T640-160v-120q0-17 11.5-28.5T680-320h120q17 0 28.5 11.5T840-280q0 17-11.5 28.5T800-240h-80ZM240-720v-80q0-17 11.5-28.5T280-840q17 0 28.5 11.5T320-800v120q0 17-11.5 28.5T280-640H160q-17 0-28.5-11.5T120-680q0-17 11.5-28.5T160-720h80Zm480 0h80q17 0 28.5 11.5T840-680q0 17-11.5 28.5T800-640H680q-17 0-28.5-11.5T640-680v-120q0-17 11.5-28.5T680-840q17 0 28.5 11.5T720-800v80Z'
const ROTATE_ICON = 'M200-640h560q33 0 56.5 23.5T840-560v160q0 33-23.5 56.5T760-320H200q-33 0-56.5-23.5T120-400v-160q0-33 23.5-56.5T200-640Zm0 80v160h560v-160H200Zm280-320q86 0 158 46l42-42v136H544l46-46q-49-28-110-28t-110 28q-14 8-29.5 4T317-800q-8-14-4-29.5t18-23.5q69-27 149-27Zm0 800q-86 0-158-46l-42 42v-136h136l-46 46q49 28 110 28t110-28q14-8 29.5-4t23.5 18q8 14 4 29.5T629-107q-69 27-149 27Z'

export class IOSFullscreenButton extends shaka.ui.Element {
  /**
   * @param {() => boolean} isFullscreen
   * @param {(fullscreen: boolean) => void} setFullscreen
   * @param {EventTarget} events
   * @param {HTMLElement} parent
   * @param {shaka.ui.Controls} controls
   */
  constructor(isFullscreen, setFullscreen, events, parent, controls) {
    super(parent, controls)

    /** @private */
    this.button_ = document.createElement('button')
    this.button_.classList.add('shaka-fullscreen-button', 'ios-fullscreen-button')
    /** @private */
    this.icon_ = new shaka.ui.Icon(this.button_, FULLSCREEN_ICON)
    this.parent.appendChild(this.button_)

    /** @private */
    this.isFullscreen_ = isFullscreen

    this.eventManager.listen(this.button_, 'click', () => {
      setFullscreen(!this.isFullscreen_())
    })

    this.eventManager.listen(events, 'setFullWindow', () => this.update_())
    this.eventManager.listen(events, 'localeChanged', () => this.update_())
    this.update_()
  }

  /** @private */
  update_() {
    const fullscreen = this.isFullscreen_()
    this.icon_.use(fullscreen ? EXIT_FULLSCREEN_ICON : FULLSCREEN_ICON)
    this.button_.ariaLabel = fullscreen ? i18n.global.t('Video.Player.Exit Full Window') : i18n.global.t('Video.Player.Full Window')
  }
}

export class IOSRotateButton extends shaka.ui.Element {
  /**
   * @param {() => void} rotate
   * @param {HTMLElement} parent
   * @param {shaka.ui.Controls} controls
   */
  constructor(rotate, parent, controls) {
    super(parent, controls)

    /** @private */
    this.button_ = document.createElement('button')
    this.button_.classList.add('ios-rotate-button')
    this.button_.ariaLabel = 'Rotate'
    /** @private */
    this.icon_ = new shaka.ui.Icon(this.button_, ROTATE_ICON)
    this.parent.appendChild(this.button_)

    this.eventManager.listen(this.button_, 'click', () => rotate())
  }
}
