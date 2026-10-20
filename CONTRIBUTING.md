# Contributing

Bug reports and focused pull requests are welcome. Include your macOS version,
CPU architecture, ChatGPT / Codex version, and the observed menu-bar behavior.
Do not include tokens, account identifiers, raw account responses, or private logs.

Build and run quota-decoding checks:

```sh
bash scripts/build.sh
'dist/Codex Glance.app/Contents/MacOS/CodexGlance' --self-test
```

To check your own local Codex connection without printing account details:

```sh
'dist/Codex Glance.app/Contents/MacOS/CodexGlance' --check
```

The protocol and UI code live in `Sources/main.swift`. All mutable connection
state belongs to the main queue. Keep quota polling at 20 seconds or slower;
prefer the existing notification-driven refresh. Errors must clear displayed
percentages so a disconnected account is never represented as current data.

Maintain both English and Chinese documentation when changing user-facing behavior.
