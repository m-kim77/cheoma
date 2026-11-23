# Changelog

What changed in each release of Cheoma. Downloads are on the [Releases](https://github.com/m-kim77/cheoma/releases) page, and the [README](README.md#update) explains how to update.

## 0.3.0 (2026-11-23)

### Added

- **Dictation** (받아쓰기): hold right ⌥ (or right ⌘, fn), talk, and let go to type into the app you're using. Off until you turn it on in Settings › 받아쓰기.
  - A double press keeps listening until you press again. Esc cancels without reaching the app underneath. Up to 2 minutes at a time.
  - Two on-device engines: Apple speech recognition on macOS 26, with the words shown in the notch as you speak, and whisper.cpp (`whisper-cli` and a `ggml-*.bin` model), better with Korean mixed with English terms.
  - A glossary turns spoken terms into their spelling (도커를 → Docker를), with common developer terms built in.
  - Pastes with ⌘V, or through the Edit menu in Chromium and Electron apps. Password fields and secure input get the clipboard only. Your clipboard can be put back afterwards.
  - The notch shows the mic level and what was heard, even with the dashboard open.
- **More agents**: Hermes Agent and Antigravity CLI (agy) sessions, with agy's weekly limits from `agy -p /usage` (no model call) and resuming agy conversations.
- **Several Codex accounts**: every `~/.codex-*` folder used with `CODEX_HOME`, grouped in the usage strip, picked in the launcher, and switchable for a running or finished session.
- **Add an account from Settings**: Settings › 계정 › 계정 추가 makes the next `~/.claude-accountN` or `~/.codex-accountN` folder, adds an alias like `claude3` to your shell file, and starts the login in Terminal.
- **Local models**: loaded models and their memory for Ollama, LM Studio, Unsloth Studio and llama.cpp `llama-server`.
- **Hide agents** you don't use in Settings › 에이전트. They leave the session list, launcher, usage strip and alerts.
- **Power tab**: memory controller rails count as memory, and a new **SoC 기타** (SoC other) row takes most of what used to land in "other".

### Changed

- Interface text reads like System Settings: shorter labels, status words such as 허용됨 and 연결 안 됨, and fewer explanations. The right-click menu items are now **로그인 시 열기** (Open at login) and **업데이트 확인…** (Check for updates…).
- Each agent is marked with the glyph it shows in its own terminal (Claude Code ✻, Codex >_, pi π, and so on).
- The agents tab has a resize handle at the bottom right that works from the first click. The size is kept relative to 100% text, so changing the text size no longer makes the tab grow each time, and it can be made smaller than the default.
- Every signed-in account stays in the usage strip; when space runs out the cards scroll sideways.
- The dashboard header shows only the time, on every tab.

### Fixed

- A closed Settings window kept redrawing its tabs, which held Cheoma at 2 to 4% CPU at idle and slowly used more memory. It is now released when closed.

## 0.2.0 (2026-11-01)

### Added

- **Coding agents tab** (에이전트): watches Claude Code, Codex, OpenCode and pi running in Terminal.app or tmux.
  - Each session shows whether it's working, waiting for a choice or waiting for input, with a preview of its terminal screen. An alert appears beside the notch when an agent asks something or finishes its turn.
  - Answer from the notch: pick a numbered choice or type a reply. tmux sessions get every key; Terminal.app tabs get text and Return.
  - **터미널로 가기** (Go to terminal) brings the session's window to the front.
  - **New agent** starts an agent in a folder you pick, in a new tmux session. For Claude Code you pick the account; by default it's the one with the most of its 5-hour limit left.
  - **Resume** a finished session from the recent list, in the same Claude account or in another one. Cheoma copies the conversation to the other account and leaves the original in place.
  - **모두 연결** (Connect all) adds hooks so alerts arrive right away: Claude Code hooks and status line in each config folder, and Codex `notify`. The original files are kept as `.cheoma-backup`, and **연결 끊기** (Disconnect) removes only Cheoma's entries.
- **Subscription limits**: how much of the 5-hour and weekly limits Codex and each Claude account have used, with reset times. Claude can be shown as an estimated API cost instead.
- **Account overview**: every signed-in Claude account with its email, plan, limits and running sessions, and the Codex login.
- **Settings window**: right-click `⌄` › 설정… (⌘,). General, agents, accounts and updates in one window.
- **Agents tab size**: drag the bottom-right corner. Double-click it to go back to the default size.
- **Agents tab text size**: 115%, 130% or 150%. The tab grows with it.
- **Terminal preview text size**, separate from the tab: **맞춤** (Fit, the default) or 11 to 20 pt, wrapping lines that don't fit.
- **New version alerts**: shortly after launch and then once a day, Cheoma asks GitHub for the latest release. A new version shows up in the notch once; click it to open the release page. Settings › 업데이트 (Updates) shows what changed and turns the check off. This is the only network request Cheoma makes.

### Changed

- The fan helper is now version 4 and needs reinstalling once (the Fans tab shows **다시 설치**). It only takes commands from an app signed the same way as the one that installed it, stays in manual mode and retries if handing the fans back to macOS fails, and copes better with sleep and restarts.
- Warnings (heat, memory, battery) are no longer covered by other alerts, and Cheoma warns at launch if the Mac is already hot, low on memory or low on battery.
- The notch opens after a short hover even while the pointer keeps moving.
- Sensors are read on a background queue, so the dashboard animates smoothly.

### Fixed

- The graphs tab used up to 110% CPU because it kept re-laying out the window. The 1-minute view now uses about 5%.
- Switching the graph range from 24 hours to 1 minute could freeze the graphs for up to 5 minutes.
- Disk and network rates jumped to absurd values, which were saved in the history, when an external disk, disk image, USB Ethernet or tethering went away.
- A hidden menu bar icon stayed revealed for minutes after you opened it, and picking an icon in arrange mode could press the wrong spot.
- On screens without a notch, the closed virtual notch no longer floats over full-screen video.
- Units roll over correctly ("1000KB/s" is now "1.0MB/s"), and battery details refresh as soon as the charger is plugged in or out.

## 0.1.0 (2026-10-30)

First public release (beta), tested on a MacBook Pro (M5 Max) with macOS 26.

- Notch dashboard: overview, graphs (up to 24 hours), power, thermal, fans and apps
- Hidden menu bar icons: icons macOS hid behind the notch, in a panel you can click
- Notch alerts: charger, unlock, overheating, low memory, low battery, and your own from Terminal
- Fan control: automatic, fixed RPM per fan, or a temperature curve
- Two shapes: Basic and Gwanghwamun
