# Cheoma (처마)

English · [한국어](README.ko.md)

A **cheoma** is the long, curved eave of a traditional Korean house. It shades the rooms from sun and rain. People hang everyday things under it, like dried persimmons, and a wind chime at its tip rings when the wind blows.

Cheoma does the same for your MacBook's notch:

- **Shelters the clutter.** Menu bar icons hidden behind the notch drop down in a panel right under it, ready to click.
- **Rings the chime.** Charger, unlock, overheating, low memory and low battery show up as small alerts around the notch.
- **Watches the weather inside your Mac.** Hover over the notch to see CPU, GPU, memory, power, network, storage, temperatures and the apps using the most.
- **Keeps things cool.** Set fan speeds yourself: a fixed RPM per fan, or a temperature curve.

Free, for Apple Silicon Macs on macOS 14 or later.

## Features

- **Notch dashboard**: hover over the notch to open it
  - Shape: click the columns button at the top right of the dashboard (or right-click `⌄` › 노치 모양) to switch between **Basic** (rounded) and **Gwanghwamun** (a black silhouette of the palace gate, with the dashboard set in its stone base)
  - Overview: CPU (per core), GPU, memory, power, network, storage
  - Graphs: CPU, GPU, power and network over 1 minute, 10 minutes, 1 hour or 24 hours (history survives restarts)
  - Power: whole system, CPU, GPU, Neural Engine, memory, display, battery health
  - Thermal: CPU, GPU, SSD and battery temperatures, fan RPM, 10-minute temperature graph
  - Fans: automatic, fixed RPM (per fan, saved presets, stop) or a temperature curve (30–100 °C, smooth or stepped)
  - Apps: top apps by CPU, CPU power and memory (helper processes grouped into their app)
- **Hidden menu bar icons**: click `⌄` in the menu bar to show icons that macOS hid behind the notch. Clicks go through the Accessibility API; the app never moves your mouse.
- **Notch alerts**: charger, unlock, overheating, low memory, battery 20% / 10%, or your own with `--notify`
- **Light on resources**: about 0.2% CPU when closed and about 1% with the dashboard open

## Install

1. Download `Cheoma.zip` from [Releases](https://github.com/m-kim77/cheoma/releases), unzip it, and move `Cheoma.app` to Applications.
2. macOS blocks the first launch because the app is not signed with a paid Apple Developer ID. Open System Settings › Privacy & Security, scroll down, and click **Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/Cheoma.app`.
3. Click `⌄` in the menu bar and allow Accessibility access (needed to click hidden icons).

If hidden icons stop responding after an update, remove Cheoma from the Accessibility list with `−` and allow it again.

## Permissions

| Feature | Needs |
|---|---|
| Reading and clicking hidden icons | System Settings › Privacy & Security › Accessibility |
| Fan control | A small root helper, installed from the Fans tab (asks for an administrator password) |
| Launch at login | Right-click `⌄` › Launch at login |

The fan helper can only set each fan between its own minimum and maximum speed, or hand control back to macOS. It returns the fans to automatic when the CPU goes over 95 °C (85 °C while stopped), or when the app quits or stops responding. Remove it from the Fans tab at any time.

## Build

```sh
scripts/build-app.sh --install   # release build → ~/Applications/Cheoma.app
open ~/Applications/Cheoma.app
```

Requires Xcode command line tools (Swift 5.9+). During development, `swift build && .build/debug/Cheoma` also works.

Developer options:

| Option | What it does |
|---|---|
| `--stats` | Print sensor readings for 3 seconds without UI |
| `--menubar-items` | List menu bar icons and whether they are hidden |
| `--render <folder>` | Save the notch UI as PNGs and check that every tab fits its open size (debug builds) |
| `--bench [seconds] [tab]` | Measure sensor read times and CPU usage per state |
| `--notify "text" [--symbol name] [--color green]` | Show an alert in the running app |

## Notes

- The interface is in Korean for now.
- Per-component power (IOReport) and live power, temperature and fan readings (SMC) use interfaces Apple does not document. If a macOS update blocks one, only that value shows "—".
- Frame rates of other apps are not available through public APIs, so only the display's refresh rate is shown.
- Fan control is tested on a MacBook Pro (M5 Max). MacBook Air has no fans, so the Fans tab is hidden there.

## License

[GPL-3.0](LICENSE). If you distribute a modified version, you must share its source under the same license. Please don't use the name "Cheoma" or its icon for forks.
