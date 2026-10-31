# FreeTube for iOS

A native iOS shell around the FreeTube renderer, with the local API (YouTube.js) working like on desktop.

- `AppSchemeHandler.swift` serves the web app on `freetube://app/` and proxies its requests (`Bootstrap.js` routes `fetch`/`XMLHttpRequest` there), so there are no CORS restrictions and the YouTube headers/cookie rules from `src/main/index.js` apply (`NetworkProxy.swift`).
- `PoTokenGenerator.swift` runs BotGuard (`src/botGuardScript.js`) in a separate, throwaway web view, like `src/main/poTokenGenerator.js`.
- `NativeChrome.swift` replaces the top and side navigation with Liquid Glass controls (iOS 26+). The web side of it is the iOS region in `src/renderer/components/TopNav/TopNav.vue` and `src/renderer/ios.css`.

## Building

Requires Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and pnpm.

```sh
pnpm install
./ios/build.sh            # ios/build/FreeTube.ipa (unsigned)
./ios/build.sh simulator  # ios/build/simulator/FreeTube.app
```

The `.ipa` is unsigned, install it with a tool that signs it with your Apple ID (AltStore, SideStore, Sideloadly) or with TrollStore.

The app icon is generated from the FreeTube logo with `ios/tools/make-icons.sh`.
