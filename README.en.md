<p align="center"><img src="assets/hero.svg" alt="Codex Glance — native macOS menu-bar allowance monitor" width="100%"></p>
<p align="center"><b>Your Codex allowance, at a glance.</b><br>A minimal, native macOS menu-bar monitor.</p>
<p align="center"><a href="https://github.com/taizi0125/codex-glance/releases/latest/download/Codex-Glance-macOS.zip"><b>Download for macOS ↓</b></a> · <a href="README.md">简体中文</a> · <a href="https://github.com/taizi0125/codex-glance/issues">Report an issue</a></p>

---

## Less checking, more making

Keep your five-hour and weekly Codex allowance visible in your Mac's menu bar.

```text
Codex ◉ 5H 68%  |  W 84%
```

Percentages show **remaining allowance**. The illustration uses sample data.

- Native Swift + AppKit menu-bar app, with no Dock icon.
- Refreshes every 20 seconds and on Codex usage-update notifications.
- Optional launch at login, available directly from the menu.
- English and Chinese menus based on your preferred system language.
- Local reset times, automatic reconnection, and `--%` when disconnected or stale.
- Uses your existing Codex sign-in; no separate API key required.

## Install

Requires **macOS 13+**, Apple Silicon or Intel, and a signed-in ChatGPT / Codex desktop app or Codex CLI.

1. [Download the latest ZIP](https://github.com/taizi0125/codex-glance/releases/latest/download/Codex-Glance-macOS.zip) and extract it.
2. Move **Codex Glance.app** to Applications.
3. Open it. Enable **Launch at login** from its menu if desired.

The current release is ad-hoc signed and **not Apple-notarized**. If macOS blocks it, review the download source and use the system's **Privacy & Security** flow to allow it. Alternatively, build from source.

## Build from source

With Xcode Command Line Tools installed:

```sh
git clone https://github.com/taizi0125/codex-glance.git
cd codex-glance
bash scripts/build.sh
open 'dist/Codex Glance.app'
```

Create a universal ZIP and SHA-256 checksum:

```sh
bash scripts/package.sh universal
```

Outputs go into `dist/`. No account data, credentials, or personal filesystem paths are bundled.

## How it works

The app starts the installed `codex app-server --stdio`, calls `account/rateLimits/read`, and listens for usage-update notifications. It uses Codex's existing sign-in without separately reading, storing, or uploading authentication tokens. The local Codex process contacts OpenAI to obtain usage, so an internet connection is required. Server-side updates determine how fresh the values are.

There is no custom backend, telemetry, analytics, or chat-history collection. This is an independent community project, not affiliated with OpenAI. The app-server interface may change between Codex releases.

Codex executables are discovered in standard system and user Applications locations, Homebrew paths, and the inherited `PATH`. For a custom development installation, set `CODEX_GLANCE_CODEX_PATH` to your Codex executable when launching from a shell.

## Troubleshooting

- **`--%` in the menu:** check network access and Codex sign-in. Run `codex login` if your CLI is not signed in. A window not returned by the service also displays `--%`. Click the item for connection status.
- **Item not visible:** free up menu-bar space, especially on Macs with a notch.
- **Reset times:** shown in your Mac's local timezone.
- **Upgrading from the old Chinese-named monitor:** quit the old app and remove its login item before starting Codex Glance. They are separate applications.
- **Uninstall:** disable Launch at login, quit, then move the app to Trash.

## Contribute

See [CONTRIBUTING.md](CONTRIBUTING.md) for decoding checks and a private-data-free connection check. Tagged `v*` pushes automatically build and publish universal macOS releases through GitHub Actions.

[MIT License](LICENSE) · Built by [taizi0125](https://github.com/taizi0125).
