# WaveBar

Real-time audio visualizer for the macOS menu bar. Captures system audio via ScreenCaptureKit and displays animated frequency bands directly in your menu bar.

## Features

- **9 visualization styles**: Bars, Bars (Inverted), Mirror Bars, Wave, Blocks, Line, Circle Blob, Circle Rays, Circle Dots
- **7 color schemes**: Cyan, Purple, Green, Orange, Pink, Rainbow, White
- **Adjustable width**: Extra Narrow / Narrow / Medium / Wide / Extra Wide
- **Sensitivity control**: Low / Medium / High / Max
- **System audio capture** via ScreenCaptureKit (falls back to microphone if permission not granted)
- **Dark/light mode** support
- **Menu bar only** — no Dock icon, minimal footprint
- **Animation continues** while the settings menu is open

## Requirements

- macOS 14+
- Swift 6.0+
- Command Line Tools or Xcode

## Build & Run

```bash
chmod +x build.sh
./build.sh
open WaveBar.app
```

## Permissions

On first launch, macOS will ask for **Screen Recording** permission. This is required to capture system audio (not the screen). You can grant it in **System Settings → Privacy & Security → Screen Recording**.

If the permission is not granted, WaveBar falls back to microphone input.

## Architecture

| File | Role |
|---|---|
| `main.swift` | App entry point, NSApplication setup |
| `AppDelegate.swift` | Menu bar UI, settings menus, display timer |
| `AudioCaptureManager.swift` | ScreenCaptureKit stream + microphone fallback |
| `AudioAnalyzer.swift` | FFT via Accelerate/vDSP, logarithmic band grouping |
| `VisualizerView.swift` | Custom NSView rendering all visualization styles |

## License

MIT
