# Quik

[中文](README.md) · [English](README.en.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [日本語](README.ja.md)

A macOS stall monitor that lives in the menu bar. It answers two questions: is the system stalling right now, and what is causing it.

Native Swift, no third-party dependencies. Measured steady-state cost is 0.8% of one core (0.07% of 12 cores), with about 25 MB resident. The method is in `docs/metric-validation.md`. The app interface is currently in Chinese.

## Install

Download `Quik-<version>.dmg` from [Releases](https://github.com/lesliechowsh/quik/releases/latest), open it, and drag Quik into Applications. Requires macOS 14 or later, on Apple Silicon and Intel.

Releases are signed with a Developer ID and notarized by Apple, so the first launch shows no security warning. Builds from source are ad-hoc signed; their first launch needs System Settings > Privacy & Security > Open Anyway.

To publish, set `QUIK_SIGN_IDENTITY` and `QUIK_NOTARY_PROFILE`; `scripts/package.sh` signs, notarizes, and staples.

## Build and run

Requires Xcode 26 and `xcodegen`.

```bash
brew install xcodegen
scripts/build.sh
scripts/run.sh
```

`scripts/run.sh` opens a floating window in the top-right corner of the screen. It shows the score, the state, and the top suspect. Click it to open the panel, which unfolds below the floating window and only grows downward when the mode changes. Drag to move it; the position is remembered. The window does not activate the app, does not steal focus, and stays visible on every desktop space.

Right-click the floating window, or click "隐藏悬浮窗" (hide floating window) at the bottom right of the panel, to tuck it away. The choice is stored in the `hudVisible` setting and survives a restart. Bring it back with the panel button, or by right-clicking the menu bar item and checking "显示悬浮窗" (show floating window).

The Dock icon mirrors the state. Plain mode shows the state and the top suspect's name, turning orange or red when the system stalls. Advanced mode puts the score in the upper half and the state label directly beneath it. The font size follows the digit count, 70 points for two digits and 52 for three, so "100" stays whole instead of being truncated to "1…". Click the Dock icon to open the panel.

A menu bar status item appears as well:

- `● 12` in green or no color, the system is fluid.
- `▲ Slack Helper 44%` in orange, the system is sluggish. The trailing text is the top suspect and its share of one core.
- `■ Slack Helper 44%` in red, the system is stalled.

When menu bar space runs short, macOS pushes the status item under the app menu. The floating window is unaffected, so it carries the always-on signal. Click the status item or the floating window to open the panel. The panel shows the stall score, its attribution (CPU, memory, disk, response latency, thermal), the top 5 suspects, and the actions available for each: sample 3 seconds, open Activity Monitor, quit.

Plain mode is the default. It answers three things: is it stalling, who is responsible, should it be quit. The score, attribution detail, history chart, and sampling entry live behind "Advanced mode", toggled at the bottom right of the panel.

Suspects are shown as the app, not the executable name. `Slack Helper (Renderer)` appears as "Slack · 页面渲染" (page renderer), and the Dock and the floating window use the same name. Command-line processes with no app owner are told apart by their working directory, for example "node · running in the my-project folder". Quitting Slack quits Slack itself, not the helper process.

The `sample` report is written to a temporary directory and opened automatically. It holds 3 seconds of call stacks and shows which function the process is stuck in. This entry appears only in advanced mode.

## AI assistant

Once installed, an AI assistant (Claude Code, Codex, Cursor, and others) can also answer "is the machine stalled right now". You decide whether to install: in plain mode, click "安装到 AI 助手" at the bottom of the panel, then click "安装" on the page that opens. Quik follows the Agent Skills open standard — a skill is a folder with a `SKILL.md` that compatible assistants discover on startup — and writes the monitoring skill into the two standard skill directories: `~/.agents/skills/quik` (read by Codex, Cursor, Cline, Zed, Warp and others) and `~/.claude/skills/quik` (read by Claude Code), plus the command-line tool at `~/.local/bin/quik`. Until you install, Quik writes nothing into your home directory. The skill references only these fixed locations and carries no machine paths. After an install, a Quik update refreshes the skill and the command, so there is nothing to reinstall; the same page has "移除", which deletes both and leaves Quik running.

`quik` prints a human-readable summary, `quik --json` prints machine-readable JSON, and the exit code states the verdict: 0 fluid, 1 sluggish, 2 stalled, 3 no data. Every second the app atomically rewrites `~/Library/Application Support/Quik/status.json`, measured at 516 bytes; it is removed on quit, and data older than 5 seconds counts as stale. The skill file teaches the assistant to quote the ready-made summary and not to run top or sampling on its own. Uninstalling needs no file hunt: right-click the menu-bar icon and choose "卸载 Quik", which deletes the quik skill from both directories, `~/.local/bin/quik` and `~/Library/Application Support/Quik` in one step, then quits; drag the app to the Trash afterwards. macOS runs no code after an app is deleted, so the cleanup must happen while the app is alive. The skill file carries the same cleanup instructions, so asking any assistant to "uninstall Quik" works too.

## Verification

```bash
# Unit tests: decision, hysteresis, ranking, display stability
xcodebuild -project Quik.xcodeproj -scheme Quik -configuration Debug -derivedDataPath build test

# UI loop: inject fixed states, screenshot the real panel, assert it stays on screen and is not blank
scripts/ui-check.sh

# Measurement loop: controlled CPU overload, checks the probe and the decision
# Flapping measurement: 6 s full load / 6 s idle cycles, counts state and ranking changes (scripts/flap-check.sh)
scripts/verify-experience.sh
```

```bash
# Floating window loop: stays hidden or shown across restarts, hides and returns while running
scripts/verify-hud.sh

# Quit action loop: signals a real process and checks that it exits
scripts/verify-quit.sh
```

```bash
# Package loop: mounts the DMG, checks architectures, signing, and the drag target, then launches it once
scripts/verify-package.sh

# Agent loop: a default launch writes nothing, explicit install and remove, both CLI outputs, staleness, and cleanup on quit
scripts/verify-agent.sh
```

Maintainer release steps are in `docs/distribution.md`.

`scripts/ui-check.sh` writes screenshots to `/tmp/quik-ui` and asserts three things: the window rectangles of the panel and the floating window staying on screen, every capture drawing more than one color instead of a blank window, and the Dock icon text staying inside the tile. It reads no text with OCR: OCR on small UI text produced false passes, and once reported a floating-window capture that was really the panel. The screenshots stay in the directory for a person to look at. Any failed assertion returns a non-zero exit code.

Window position is asserted separately because a screenshot by window ID proves the content is right, not that the window is on screen. An early version put the panel above the top of the screen; its content screenshot looked fine and the check still passed.

The icon check reads PNGs exported by the app, which come from the same `ImageRenderer` output the Dock draws. It asserts a square tile, text pixels not touching the edge, and text taller than half the tile. Advanced mode adds two measurable constraints: the vertical gap between score and label stays within 12% of the tile side, and the label's bottom edge sits at least 20 pixels above the tile bottom. A unit test also renders a score of 100 and measures the horizontal span of its white pixels, so a truncated three-digit score fails the build without any OCR.

## Measurement boundaries

Quik measures system contention, not the UI frame time of another app. macOS has no public interface that lets one process read another process's main-thread stalls from the outside.

The panel therefore reports "who is using the resources" and "can the system still schedule interactive threads in time", not "this app is frozen". When the CPU is saturated but response latency is normal, Quik reports sluggish, not stalled. Memory pressure at critical or thermal at critical is the exception: the kernel is already freezing apps or reducing clock speed, so Quik reports stalled directly.

The full load-to-state mapping and the basis for the decision curve are in `docs/metric-validation.md`.

## Layout

```
Sources/Core/       decision engine, deltas, experience probe, history, agent status file
Sources/Probe/      mach, sysctl, libproc, IOKit sampling and the C bridge
Sources/UI/         menu bar, panel, actions, preview states
Sources/CLI/        the quik command-line tool
Sources/Resources/  the AI-assistant skill file shipped with the app
Sources/App/        entry point
Tests/              unit tests
scripts/            build, UI checks, measurement experiments
docs/               decision log and measurement validation
```

## License

MIT. See `LICENSE`.
