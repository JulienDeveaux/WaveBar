# WaveBar

Real-time audio visualizer for the macOS menu bar. Captures system audio via CoreAudio Process Taps and displays animated frequency bands directly in your menu bar.

## Features

- **9 visualization styles**: Bars, Bars (Inverted), Mirror Bars, Wave, Blocks, Line, Circle Blob, Circle Rays, Circle Dots
- **7 color schemes**: Cyan, Purple, Green, Orange, Pink, Rainbow, White
- **Adjustable width**: Extra Narrow / Narrow / Medium / Wide / Extra Wide
- **System audio capture** via CoreAudio Process Taps — no screen recording icon in the menu bar
- **Start at Login** option
- **Dark/light mode** support
- **Menu bar only** — no Dock icon, minimal footprint
- **Animation continues** while the settings menu is open

## Requirements

- macOS 15+
- Swift 6.0+
- Command Line Tools or Xcode

## Build & Run

```bash
chmod +x build.sh
./build.sh
open WaveBar.app
```

## Permissions

On first launch, WaveBar will prompt you to grant **System Audio Recording** permission. If no audio is detected after a few seconds, it will offer to open **System Settings → Privacy & Security → Audio Capture** where you can add WaveBar.

The app automatically retries capture after permission is granted — no need to relaunch manually.

## Architecture

| File | Role |
|---|---|
| `main.swift` | App entry point, NSApplication setup, Launch Services registration |
| `AppDelegate.swift` | Menu bar UI, settings menus, display timer, login item |
| `AudioCaptureManager.swift` | CoreAudio Process Tap + aggregate device, permission flow |
| `AudioAnalyzer.swift` | FFT via Accelerate/vDSP, logarithmic band grouping, auto gain |
| `VisualizerView.swift` | Custom NSView rendering all 9 visualization styles |

## License

MIT
