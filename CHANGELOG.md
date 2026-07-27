# Changelog

All notable changes to this project are documented here.
Format loosely follows [Keep a Changelog](https://keepachangelog.com/).

## [1.5.0] - 2026-07-27

### Added
- Optional sound cues, configurable per lock and separately for the ON and OFF
  transition. Choose a Windows system sound or supply a custom WAV, with a
  **Play** button to audition it.
- **Still play sound cues while hidden** (General tab, on by default) — badges
  are suppressed during full-screen apps, so audio becomes the only channel
  exactly when it matters most, in games.

### Notes
- System sounds are played via `SoundPlay`, which is asynchronous and honours
  the user's Windows sound scheme and mute state. Synthesised tones
  (`SoundBeep`/`Beep`) are deliberately not used: they block the single
  AutoHotkey thread and would stall the fade animation.
- Cues are rate-limited to one per 120ms so two locks toggling together do not
  talk over each other.

## [1.4.0] - 2026-07-27

### Added
- Configurable stack anchor — choose which lock's saved position the row grows from
- Preview header now states when a position is being computed rather than used

### Changed
- Position fields, **Drag to place** and **Reset pos** are disabled for non-anchor
  badges while stacking is on, instead of silently having no effect
- Stack order is now anchor first, then the remaining locks

## [1.3.0] - 2026-07-27

### Added
- **Test all badges** button — flashes every enabled badge together, timed to the
  longest duration, so the stack can be judged in motion
- **Show every enabled badge while editing** option

### Changed
- All enabled badges now stay visible while Settings is open, and while dragging
  one into place. Placement is a relative judgement and can't be made against
  invisible neighbours.

### Fixed
- Stack layout no longer re-anchors mid-drag, which previously yanked the badge
  out from under the cursor

## [1.2.1] - 2026-07-27

### Removed
- Fn Lock tab. Fn is handled by keyboard firmware and never reaches Windows;
  the reasoning now lives in the source header instead of the UI.

### Fixed
- Tab strip wrapping to a second row, which shifted every page's content up
  behind it and clipped the first control. `-Wrap` now forbids a second row.

## [1.2.0] - 2026-07-27

### Removed
- Password-field detection. It read the focused control's `ES_PASSWORD` style to
  hold the badge visible in password boxes. Removed because pressing caps in a
  field already triggered the normal flash, it could only see native Win32
  controls (never browsers), and browsers already warn about caps lock. It was
  the only code that reached into another process.

### Changed
- Privacy claim is now absolute: nothing inside any other process is inspected

## [1.1.0] - 2026-07-27

### Added
- Fullscreen suppression — badges hide while a fullscreen app is foreground,
  with state still tracked so nothing flashes on exit
- Optional monitor follow, re-applying a badge's within-monitor offset to the
  screen holding the focused window
- Optional exclusion from screen capture via `WDA_EXCLUDEFROMCAPTURE`
- Security design constraints documented in the source header

### Changed
- Renamed from CapsBadge to LockBadges; settings migrate automatically from
  `%APPDATA%\CapsBadge` on first run, and the old Startup shortcut is removed

## [1.0.0] - 2026-07-27

### Added
- Independent badges for Caps Lock, Num Lock and Scroll Lock, in a tabbed
  settings window
- Live preview with true alpha-composited colours over a selectable backdrop
- Drag-to-place, drag-to-resize, and four size presets
- 40-swatch colour palette plus the native Windows colour picker
- Font selection with bold/italic
- Flash-on-change or stay-visible-until-toggled-off, per lock
- Optional vertical or horizontal stacking
- Autostart toggle and INI persistence

[1.5.0]: ../../releases/tag/v1.5.0
[1.4.0]: ../../releases/tag/v1.4.0
[1.3.0]: ../../releases/tag/v1.3.0
[1.2.1]: ../../releases/tag/v1.2.1
[1.2.0]: ../../releases/tag/v1.2.0
[1.1.0]: ../../releases/tag/v1.1.0
[1.0.0]: ../../releases/tag/v1.0.0
