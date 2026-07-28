# yPrompt - Cross-Platform Teleprompter App
## Complete Build Prompt for Claude Code in Xcode

---

## Project Overview
Build a minimal, elegant teleprompter app for macOS 14+, iOS 17+, iPadOS 17+, and watchOS 10+. The app lets users write and display text with extensive customization (fonts, colors, scroll speed, transparency). Uses SwiftUI for UI, SwiftData for local storage, CloudKit for iCloud sync, and StoreKit 2 for monetization.

**Tech Stack:**
- SwiftUI (all platforms)
- SwiftData (local persistence)
- CloudKit (iCloud sync)
- StoreKit 2 (in-app purchases)
- Combine (reactive state)

**Target Platforms:**
- macOS 14.0+
- iOS 17.0+
- iPadOS 17.0+ (iPad-optimized layout)
- watchOS 10.0+ (controls only)

**Monetization:**
- In-app purchase option: Lifetime ($39.99)
- StoreKit paywall with subscription fallback ($4.99/mo or $39/yr)
- Local free tier (limited to 3 scripts)

---

## Phase 1: Core Features (MVP)

### 1. Data Models

#### Script Model (SwiftData)
```
- id: UUID
- title: String
- content: String (large text)
- createdAt: Date
- modifiedAt: Date
- customization: TextCustomization (embedded)
- cloudSyncState: CloudSyncState (persisted)
- isFavorite: Bool
```

#### TextCustomization Model (embedded)
```
- fontName: String (default: "Menlo")
- fontSize: CGFloat (default: 28)
- textColor: Color (default: black)
- backgroundColor: Color (default: white)
- lineHeight: CGFloat (default: 1.4)
- textAlignment: TextAlignment
- transparency: Double (0.0-1.0, default: 1.0)
- scrollSpeed: Double (0.5-3.0x, default: 1.0)
- isMirrored: Bool (default: false)
- isAutoScroll: Bool (default: true)
```

#### AppSettings Model (SwiftData, singleton)
```
- lastOpenedScriptID: UUID?
- defaultFontName: String
- defaultTextColor: Color
- defaultBackgroundColor: Color
- darkModeEnabled: Bool
- cloudSyncEnabled: Bool
- purchaseState: PurchaseState (free, lifetime, subscribed)
- lastSyncDate: Date?
```

### 2. Core Views

#### ContentView (main hub)
- Tab navigation (Editor, Scripts, Teleprompter, Settings)
- macOS: sidebar on left, content on right
- iOS/iPadOS: bottom tab bar
- watchOS: simple list of recent scripts

#### ScriptsListView
- List of all scripts (local + synced)
- Search + filter
- Long-press to delete/duplicate
- Tap to open editor
- Display: title, modified date, preview snippet
- Favorite toggle via heart icon

#### EditorView
- Large text editor for script content
- Real-time preview (right panel on macOS, inline on iOS)
- Floating toolbar with customization buttons
- Save on keystroke (debounced 1 second)
- Character count display

#### TeleprompterView (full-screen presentation)
- Script content scrolls vertically
- Floating control panel (tap to show/hide, 3 second auto-hide)
- Controls: Play/Pause, Speed slider (0.5-3.0x), Reset scroll
- Tap-to-advance option (pause auto-scroll, advance per tap)
- Transparency slider (for reading over camera)
- iOS/iPadOS: landscape only
- watchOS: speed + play/pause only

#### CustomizationView (popup/modal)
- Font picker (15+ system fonts + custom)
- Font size slider (8-120pt)
- Text color picker (12 preset + custom)
- BG color picker (12 preset + custom)
- Line height slider (1.0-2.0)
- Text alignment buttons (L, C, R, J)
- Mirror toggle
- Transparency slider
- Apply to current script or set as default

#### SettingsView
- App version + build
- iCloud sync toggle (if enabled, show sync status)
- Purchase status + upgrade button (opens StoreKit paywall)
- "Upgrade to Lifetime" / "Manage Subscription"
- Reset app button (deletes all local data)
- About + privacy policy link
- Feedback button

### 3. Services

#### CloudKitService
- Sync scripts to/from iCloud (CloudKit)
- Handle conflicts (last-write-wins)
- Sync status: idle, syncing, synced, error
- Retry logic (exponential backoff)
- User authentication check

#### StorageService
- Save/load scripts from SwiftData
- Query scripts (all, favorites, search by title)
- Delete script
- Update sync metadata

#### StoreKitService
- Fetch in-app purchase products
- Handle purchases (lifetime + subscriptions)
- Check subscription validity
- Restore purchases
- Handle errors (network, user cancelled, etc.)

#### TeleprompterViewModel
- Scroll speed state + animation
- Play/pause state
- Current scroll position (0.0-1.0)
- Tap-to-advance toggle
- Transparency state
- Reset to top

### 4. Typography + Design System
- **Fonts available:**
  - Menlo (monospace, default)
  - SF Mono
  - Courier New
  - SF Pro (system font)
  - Georgia
  - Times New Roman
  - Comic Sans MS
  - Helvetica Neue
  - Arial
  - Trebuchet MS
  - Palatino
  - Garamond
  - System fonts only (no external dependencies)

- **Colors (presets + custom picker):**
  - Text: Black, White, Red, Blue, Green, Yellow, Purple, Gray, Orange, Cyan, Pink, Brown
  - BG: White, Black, Dark Gray, Light Gray, Cream, Light Blue, Light Yellow, Light Green, Navy, Charcoal, Beige, Mint

- **Spacing & layout:**
  - macOS: Full window, resizable, min 800x600
  - iOS: Full screen, landscape preferred (lock to landscape for teleprompter)
  - iPadOS: Split view support (iPad Pro landscape)
  - watchOS: Compact, single column

---

## Phase 1: File-by-File Instructions

### Models/Script.swift
Create a SwiftData model for scripts with all fields listed above. Include codable conformance for cloud sync.

### Models/AppSettings.swift
Singleton SwiftData model for app-wide settings. Include publisher hooks for Combine reactivity.

### Views/ContentView.swift
Main app shell with TabView (macOS: sidebar, iOS: bottom tabs). Show appropriate tabs based on platform. Include onAppear hook to check purchase status and sync.

### Views/ScriptsListView.swift
Scrollable list of scripts from SwiftData query. Include:
- Search bar at top
- Empty state ("No scripts. Create one!")
- Favorite heart toggle
- Edit/Delete context menu
- Tap to navigate to editor

### Views/EditorView.swift
Large text area + preview. Use TextEditor for input. Show character count. Debounced auto-save.

### Views/TeleprompterView.swift
Full-screen scroll view with:
- VStack(spacing: 0) for text content
- ScrollViewReader for jump-to-top
- Floating control bar: play/pause, speed slider, transparency slider
- iOS: Lock to landscape orientation
- Auto-scroll using Timer + scroll position updates

### Views/CustomizationView.swift
Modal/popup with all customization controls. Apply button saves to script, "Set as Default" saves to AppSettings.

### Views/SettingsView.swift
List view with sections:
- Version info
- iCloud sync toggle + status
- Purchase section (StoreKit integration)
- Reset data button (confirmation)
- About / Privacy / Feedback

### ViewModels/ScriptViewModel.swift
Manages a single script's state. Handles save/load, customization updates, cloud sync status.

### ViewModels/TeleprompterViewModel.swift
Manages teleprompter playback state:
- @Published var isPlaying: Bool
- @Published var scrollSpeed: Double
- @Published var scrollPosition: CGFloat
- @Published var transparency: Double
- Timer-based auto-scroll logic
- Tap-to-advance logic

### Services/CloudKitService.swift
- Async/await functions for sync
- Handle CloudKit errors gracefully
- Update sync status state
- Conflict resolution

### Services/StorageService.swift
- SwiftData query + CRUD operations
- Favorite toggle
- Search

### Services/StoreKitService.swift
- Fetch products (lifetime + subscriptions)
- Process purchases
- Check entitlements
- Handle errors

### Utilities/Constants.swift
- Font names array
- Color presets (RGB tuples)
- Default settings
- StoreKit product IDs

### Utilities/Extensions.swift
- Color<->String codable
- CGFloat formatting
- Platform detection (@available guards)
- View extensions (placeholder style, etc.)

---

## Phase 1 Requirements Checklist

### Functional
- [ ] Create new script (empty)
- [ ] Edit script title + content
- [ ] Delete script
- [ ] Favorite/unfavorite
- [ ] Search scripts by title
- [ ] Customize: font, size, color, BG, line height, alignment, mirror
- [ ] Teleprompter: smooth vertical scroll, play/pause, speed control
- [ ] Transparency slider (for camera overlay)
- [ ] Tap-to-advance mode
- [ ] Auto-save on edit (debounced)
- [ ] Reset to top button

### Data
- [ ] SwiftData models compile
- [ ] Scripts persist locally (quit + relaunch)
- [ ] Customization persists per script
- [ ] AppSettings persist globally

### Monetization
- [ ] StoreKit 2 integration (no actual purchases needed yet)
- [ ] Purchase/subscription display (can be mock)
- [ ] Free tier limited to 3 scripts
- [ ] Paid users: unlimited scripts

### Platforms
- [ ] macOS 14.0+ builds and runs
- [ ] iOS 17.0+ builds and runs
- [ ] iPadOS 17.0+ builds and runs
- [ ] watchOS 10.0+ builds and runs (minimal controls)
- [ ] UI responsive on each platform

### Polish
- [ ] Dark mode support
- [ ] Orientation: landscape lock on iOS teleprompter
- [ ] Proper keyboard handling (iOS keyboard dismiss on editor save)
- [ ] Loading states (syncing, saving)
- [ ] Error alerts (sync failed, save failed, etc.)
- [ ] No console warnings or errors

---

## Code Style & Conventions

### Structure
- Organize by feature (Models, Views, ViewModels, Services)
- Use MARK comments to section code
- Extract reusable view modifiers

### Naming
- Views: PascalCase + "View" suffix
- ViewModels: PascalCase + "ViewModel" suffix
- Services: PascalCase + "Service" suffix
- Properties: camelCase
- Constants: UPPER_SNAKE_CASE or PascalCase (colors/fonts)

### SwiftUI Best Practices
- Use @State for local UI state only
- Use @ObservedObject / @StateObject for ViewModels
- Use @Environment for app-wide settings
- Prefer computed properties over complex view bodies (extract subviews)
- Use .onAppear sparingly (prefer init + task)

### Error Handling
- Use do-catch for CloudKit + StoreKit calls
- Present errors as alerts or toasts (no crashes)
- Log to console for debugging

### Accessibility
- All text has appropriate font sizes (min 12pt, preferably 14+)
- Buttons have descriptive labels
- Use AccessibilityLabel for icons
- Color is not the only way to communicate state (add text)

---

## Next Steps After Phase 1

### Phase 2 (v1.1)
- iCloud CloudKit sync implementation
- Template packs (10+ pre-written scripts)
- Markdown support
- Script sharing (via iCloud link)
- Teleprompter history (recent scripts)
- Custom keyboard shortcuts (macOS)
- Notch integration (macOS 14+)
- Dynamic Island controls (iOS 16.1+)

### Phase 3 (v1.2)
- visionOS immersive view (Vision Pro)
- AI script generation (OpenAI API)
- Voice-to-text input
- Team/multi-user collaboration
- OBS/StreamLabs integration API
- Preset management (save/load customization profiles)

---

## Build & Run

1. **Build**: Cmd+B
2. **Run macOS**: Cmd+R (simulator or device)
3. **Run iOS**: Select iPhone simulator, Cmd+R
4. **Run watchOS**: Select Watch simulator, Cmd+R
5. **Test iCloud**: Xcode must be signed in with an Apple ID, CloudKit requires entitlements

---

## Important Notes

- **SwiftData**: Introduced in iOS 17 / macOS 14. Use @Query for fetching.
- **CloudKit**: Requires iCloud container entitlement. Use CKContainer for sync.
- **StoreKit 2**: Use StoreKit 2 API (not StoreKit 1). Test with StoreKit Configuration file in Xcode.
- **Async/await**: Use throughout. No completion handlers.
- **Testing**: Manual testing only for Phase 1 (no unit tests yet).

---

## Questions to Answer During Development

1. Should scripts auto-save to cloud every keystroke or only on explicit save?
   → **Auto-save locally every 1s, sync to cloud on save button.**

2. What happens if user deletes a script locally, then syncs? (Conflict)
   → **Last-write-wins: cloud version survives unless user explicitly deleted it server-side.**

3. Should free tier allow custom colors or only presets?
   → **Presets only. Custom color picker locked behind paywall.**

4. Can user set one script's customization as default for all new scripts?
   → **Yes, "Set as Default" button in customization view.**

5. Should teleprompter show line numbers?
   → **No. Minimal design = no line numbers.**

6. Keyboard shortcuts for teleprompter?
   → **Space = play/pause, ↑/↓ = speed, R = reset, T = transparent mode toggle.**

---

## Summary

You're building **yPrompt**, a minimal, cross-platform teleprompter with:
- Full customization (fonts, colors, transparency, speed)
- Local persistence (SwiftData) + iCloud sync (CloudKit)
- Freemium monetization (StoreKit 2)
- macOS, iOS, iPadOS, watchOS support

Focus on Phase 1: a rock-solid MVP with great fundamentals. Make it feel polished, responsive, and delightful to use. Every UI element should justify its existence.

---

## Final Checklist Before Prompting Claude Code

- [ ] Xcode project created with SwiftUI + SwiftData
- [ ] Minimum OS versions set (macOS 14, iOS 17, iPadOS 17, watchOS 10)
- [ ] iCloud + CloudKit capabilities added
- [ ] Folder structure created (Models, Views, ViewModels, Services, Utilities)
- [ ] Empty Swift files created (don't add code yet)
- [ ] Project builds with no errors
- [ ] Ready to paste this prompt into Claude Code

**Go build something amazing.** 🚀

