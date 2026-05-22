# LeetViz

A tiny macOS menu bar app that visualizes whatever music is playing on your Mac. Captures system audio (not the mic) via ScreenCaptureKit, runs a real FFT, and draws bars / waveform / pulsing blocks straight inside the status item.

Designed to be unnoticeably light: the render loop suspends itself when the system is silent, drops to 15 fps on Low Power Mode, and never animates faster than 30 fps.

## Build & run

1. Open `LeetViz.xcodeproj` in Xcode (15 or later).
2. Set the signing team on the **LeetViz** target if Xcode asks (Signing & Capabilities → Team). Personal Team is fine.
3. ⌘R to build and run. The Dock icon will not appear; look for the visualizer in your menu bar.

Requires macOS 13 or later.

## Grant Screen Recording permission

System audio capture goes through the OS's Screen Recording permission. The first time you launch, macOS will prompt you. If you decline, you'll see a `⚠ Grant Screen Recording permission…` item at the top of the right-click menu — pick it (or the "Open Screen Recording Settings…" item below) to jump straight to the right pane.

After enabling LeetViz in **System Settings → Privacy & Security → Screen Recording**, **quit and relaunch the app** (TCC only re-reads the grant on next launch).

## Using it

- Left- or right-click the status item to open the menu.
- **Visualizer Style** → pick spectrum bars (default), waveform, or pulsing blocks.
- **Accent Color** → cyan / magenta / green / orange / white.
- Both choices persist via `UserDefaults`.

## Tweaking

- Band count, FFT size, smoothing, decay, sensitivity: top of `FFTProcessor.swift`.
- Render frame rate, idle threshold, silence detection: top of `MenuBarController.swift`.
- Wake threshold (how loud before the render loop unparks): `wakeThreshold` on `AudioCaptureManager`.

## Files

```
LeetViz/
├── AppDelegate.swift          – entry point, sets accessory activation policy
├── MenuBarController.swift    – status item, menu, render loop, idle/wake state machine
├── VisualizerView.swift       – the three drawing modes
├── AudioCaptureManager.swift  – SCStream setup, ring buffer, peak detection
├── FFTProcessor.swift         – vDSP forward FFT + log-spaced band binning
├── SettingsStore.swift        – UserDefaults wrapper for style & accent
├── Info.plist                 – LSUIElement = YES, macOS 13 minimum
└── LeetViz.entitlements       – sandbox off (ScreenCaptureKit + non-store distribution)
```
