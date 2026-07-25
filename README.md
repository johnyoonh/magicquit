<p align="center">
  <img src="MagicQuit/Assets.xcassets/Image.imageset/256.png" width="128" alt="MagicQuit icon">
</p>

<h1 align="center">MagicQuit</h1>

<p align="center">Automatically quits apps you are no longer using.<br>Lives in the menu bar, stays out of your way.</p>

---

MagicQuit keeps your Mac tidy with two independently configurable mechanisms per app:

- **Idle quit** — quit an app after it has not been active for its configured duration.
- **Last-window quit** — quit an app after its final real window closes.

Automatic quits use a 30-second cancelable warning by default. Manual quits remain immediate. MagicQuit sends a normal termination request equivalent to ⌘Q; it never force-kills an app, and apps with unsaved work can still ask you to save.

## Install

Download the latest signed release from this repository's Releases page and drag `MagicQuit.app` into `/Applications`.

Requires macOS 14 or later.

## Usage

- Click the menu bar icon to search running apps, sort by time remaining, and configure each app.
- Use **Idle quit** and **Last-window quit** separately; disabling one does not silently disable the other.
- Choose a per-app idle duration or inherit the global default.
- Reset a timer, cancel an upcoming automatic quit, or snooze it for 15 minutes.
- Settings include launch at login, the global idle duration, configuration backup/restore, window-close permissions, and exclusion management.

## Automatic configuration persistence

MagicQuit automatically mirrors the complete configuration to:

```text
~/Library/Application Support/MagicQuit/configuration.json
```

The file includes global behavior, idle and window-close exclusions, and per-app durations. A new build automatically reads this stable file, so users do not need to re-enter settings after replacing or rebuilding the app. Existing `UserDefaults` values are migrated automatically and remain as a fallback.

Manual JSON export/import remains available for backup or moving configuration to another Mac. Imported files are versioned, size-limited, validated, and written atomically.

## Accessibility permission

Last-window quitting uses the Accessibility API to observe window creation and destruction. MagicQuit cross-checks Accessibility results against Core Graphics windows so minimized, full-screen, and other-Space windows are not mistaken for a closed app. Idle quitting does not require Accessibility access.

## Updates and releases

Sparkle updates are disabled in Debug builds. Release builds only start the updater when a fork-owned Sparkle public key is configured and the feed points to `johnyoonh/magicquit`. The release script validates repository ownership, versions, signatures, notarization, appcast URLs, and Homebrew metadata before publishing.

## Building

Open `MagicQuit.xcodeproj` in Xcode 16 or later and build the `MagicQuit` scheme.

```bash
xcodebuild test -project MagicQuit.xcodeproj -scheme MagicQuit -destination 'platform=macOS'
```

GitHub Actions builds Debug and Release configurations, runs tests, validates property lists and scripts, and rejects stale upstream distribution URLs.

## License

[MIT](LICENSE)
