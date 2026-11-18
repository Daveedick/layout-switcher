# Layout Switcher

**English** · [Русский](README.ru.md)

A native Swift utility for Apple Silicon Macs. Fix the last typed word or selected text between English and Russian with one shortcut. An alternative to Punto Switcher.

**Apple Silicon (arm64) · macOS 14+ · Public preview**

Select text or finish typing a word, then press and release **⌥⌘** to convert it between ABC and Russian – PC.

## What it does

- Corrects a selection or the last typed word with a configurable shortcut. For example, `ghbdtn` becomes `привет`.
- Swaps both layouts within a mixed selection. `привет hello` becomes `ghbdtn руддщ`.
- Runs in the menu bar. The Dock icon appears while a Layout Switcher window is visible.
- Offers opt-in launch at login and recovery after an unexpected exit through macOS launchd.

## Install

1. Download `Layout-Switcher-0.3.3-arm64.dmg` from the [v0.3.3 preview release](https://github.com/Daveedick/layout-switcher/releases/tag/v0.3.3). The release includes a SHA-256 checksum.
2. Open the disk image, drag **Layout Switcher** into Applications, and launch that copy.
3. Grant **Accessibility** and **Input Monitoring** in System Settings, then use **Проверить разрешения** in the app or reopen it. Add ABC and Russian – PC to your macOS input sources if needed.

The preview has an ad-hoc signature and comes without Apple notarization. macOS may show an unidentified-developer prompt. After checking the source and checksum, use the app-specific **Open Anyway** option in **System Settings → Privacy & Security**, if offered. An update may require granting both permissions again.

Use **Сочетание клавиш…** in the menu to set a shortcut. **Включить вход и восстановление после сбоя…** opts into launch at login and recovery. **Завершить** exits for the current session and keeps the login setting. The menu also has an action to turn off automatic launch and exit.

## Privacy and compatibility

Text processing stays on the Mac. The app keeps a short in-memory buffer for recent-word correction and skips protected input. The Codex selection path briefly uses the system clipboard and restores the previous contents while it still owns the write. The app stores no typing or clipboard history and makes no network requests.

Correction runs on demand. If you already use Punto Switcher, quit it before testing Layout Switcher to avoid conflicts. Editors expose selection and text editing differently, so compatibility can vary by app and field. Text typed before launch or pasted from the clipboard can be corrected by selecting it explicitly.

## Build

Install the Swift toolchain, then run:

```sh
scripts/test.sh
scripts/test-input-sources.sh
scripts/test-clipboard.sh
scripts/build.sh
```

The signed local bundle is `dist/Layout Switcher.app`. Icon regeneration is optional. `python3 scripts/generate-icons.py --app-only` rebuilds the Finder and Dock artwork, and `--menu-only` rebuilds the menu bar template.

## Third-party notices

The project adapts parts of [ShiftSwitch](https://github.com/imakarov/shiftswitch) under the MIT License. Its notice ships in the app. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The project's original code has no separate license at this time.
