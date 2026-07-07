---
name: ios-widget-appgroup-suitename-hardcoded
description: iOS widget/share-extension stays empty on personal fork because Swift suiteName constants hardcode the App Group name — must patch code, not just entitlements
metadata:
  node_type: memory
  type: project
---

On the personal fork (team `D3S5M885YQ`, App Group `group.com.mdbraber.readest`) the iOS home-screen reading widget rendered only the placeholder book icon — the App **writes** its snapshot and the widget **reads** it through a shared App Group container, but the suite name is **hardcoded in Swift** to upstream's `group.com.bilingify.readest` in four places:

- `src-tauri/plugins/tauri-plugin-native-bridge/ios/Sources/ReadingWidgetWriter.swift` (`suiteName`) — app writes here
- `src-tauri/gen/apple/ReadestWidget/WidgetSnapshot.swift` (`suiteName`) — widget reads here
- `src-tauri/plugins/tauri-plugin-native-bridge/ios/Sources/AppGroupBridge.swift` (`suiteName`)
- `src-tauri/gen/apple/ShareExtension/AppGroupBridge.swift` (`suiteName`) — mirror of the plugin one; keep both byte-aligned

Since the app is entitled **only** for `group.com.mdbraber.readest`, `UserDefaults(suiteName:)` and `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` return **nil** for the bilingify group → the writer writes into the void and the widget reads nothing. Fix = set all four `suiteName` constants to `group.com.mdbraber.readest` (matching the entitlement) and rebuild.

**Key gotcha:** renaming the App Group only in `ReadestWidget.entitlements` + `project.yml` (what fork commit `3d5cf45e` on branch `testing-ios` did) is NOT enough — config said `mdbraber`, Swift code still said `bilingify`. The runtime App Group name lives in these Swift `suiteName` constants; patch code alongside entitlements. Same class of issue as [[ios-share-txt-stuck-supportstext]] (share-extension App Group behavior). Keychain service strings (`com.bilingify.readest.sync-passphrase`, `.secure-items` in `NativeBridgePlugin.swift`) are plain service names, NOT access groups — they don't need patching.

Verify the built binary bakes the right group: `strings Readest.app/PlugIns/ReadestWidget.appex/ReadestWidget | grep group.com` and same for the main `Readest` binary. Widget only populates after the app writes a snapshot, i.e. after opening/reading a book (the JS `useReadingWidget` flow → `update_reading_widget` command).
