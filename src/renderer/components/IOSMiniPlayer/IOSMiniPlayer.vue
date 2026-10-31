<template>
  <div
    class="iosMiniPlayer"
    :class="{ iosMiniPlayerActive: iosMiniPlayerState.active }"
    :inert="!iosMiniPlayerState.active"
  >
    <div
      ref="host"
      class="iosMiniPlayerVideo"
    />
    <button
      class="iosMiniPlayerInfo"
      type="button"
      @click="expand"
    >
      <span class="iosMiniPlayerTitle">{{ iosMiniPlayerState.title }}</span>
      <span class="iosMiniPlayerChannel">{{ iosMiniPlayerState.channelName }}</span>
    </button>
    <button
      class="iosMiniPlayerButton"
      type="button"
      :aria-label="iosMiniPlayerState.playing ? 'Pause' : 'Play'"
      @click="toggleIOSMiniPlayer"
    >
      <svg
        viewBox="0 0 24 24"
        aria-hidden="true"
      >
        <path
          v-if="iosMiniPlayerState.playing"
          d="M7 4.5h3.5v15H7zM13.5 4.5H17v15h-3.5z"
        />
        <path
          v-else
          d="M8 4.8v14.4a.8.8 0 0 0 1.2.7l11.5-7.2a.8.8 0 0 0 0-1.4L9.2 4.1A.8.8 0 0 0 8 4.8z"
        />
      </svg>
    </button>
    <button
      class="iosMiniPlayerButton"
      type="button"
      :aria-label="t('Close')"
      @click="stopIOSMiniPlayer"
    >
      <svg
        viewBox="0 0 24 24"
        aria-hidden="true"
      >
        <path d="M6 6l12 12M18 6L6 18" />
      </svg>
    </button>
    <span
      class="iosMiniPlayerProgress"
      :style="{ transform: `scaleX(${iosMiniPlayerState.progress})` }"
    />
  </div>
</template>

<script setup>
import { onBeforeUnmount, onMounted, useTemplateRef, watch } from 'vue'
import { useI18n } from 'vue-i18n'
import { useRoute, useRouter } from 'vue-router'

import {
  getIOSMiniPlayerTime,
  handoffIOSMiniPlayer,
  iosMiniPlayerHost,
  iosMiniPlayerState,
  stopIOSMiniPlayer,
  toggleIOSMiniPlayer
} from '../../helpers/iosMiniPlayer'

const { t } = useI18n()
const route = useRoute()
const router = useRouter()

const host = useTemplateRef('host')

onMounted(() => {
  iosMiniPlayerHost.value = host.value
})

onBeforeUnmount(() => {
  iosMiniPlayerHost.value = null
})

watch(() => iosMiniPlayerState.active, (active) => {
  document.body.classList.toggle('iosMiniPlayerVisible', active)
})

// opening any video replaces the one in the mini player
watch(() => route.path, (path) => {
  if (iosMiniPlayerState.active && !iosMiniPlayerState.handoff && path.startsWith('/watch/')) {
    stopIOSMiniPlayer()
  }
})

async function expand() {
  const videoId = iosMiniPlayerState.videoId
  const time = Math.floor(getIOSMiniPlayerTime())

  handoffIOSMiniPlayer()

  router.push({
    path: `/watch/${videoId}`,
    query: time > 0 ? { timestamp: time } : {}
  })
}
</script>
