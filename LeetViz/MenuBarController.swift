import AppKit
import Foundation
import ServiceManagement

/// Hosts the status item, owns the audio + FFT pipeline, and adapts its render
/// rate to keep battery impact unnoticeable:
///   - Render timer is suspended when the system is silent.
///   - Audio callback wakes it the instant audio returns.
///   - Frame rate halves on Low Power Mode.
///   - No-op redraws are skipped (the renderer tells us when nothing changed).
final class MenuBarController: NSObject, AudioCaptureManagerDelegate {
    // Render rates: tweak here to trade smoothness for power. 15 fps in a
    // ~100×22 pt menu bar item is plenty — the eye can't resolve more on
    // something this small, and dropping from 30 cuts render work in half.
    private let activeFPS: Double = 15
    private let lowPowerFPS: Double = 8
    /// Frames of consecutive silence before we suspend the render timer.
    /// At 30fps, 24 frames ≈ 800ms — long enough to let bars decay visually.
    private let silenceFramesToIdle: Int = 24
    /// Per-frame level below which we count as silent for idle bookkeeping.
    private let silenceLevelThreshold: Float = 0.01

    private let statusItemWidth: CGFloat = 100

    private var statusItem: NSStatusItem!
    private let renderer = VisualizerView(frame: .zero)
    private var menu: NSMenu!

    private let audio = AudioCaptureManager()
    private let fft = FFTProcessor(fftSize: 1024, bandCount: 16, sampleRate: 48_000)

    private var renderTimer: Timer?
    private var silenceFrames = 0
    private var permissionItemInMenu = false

    private var imageSize: NSSize {
        // Menu bar thickness varies (notch-era Macs report ~24). Fall back to 22.
        let h = max(18, NSStatusBar.system.thickness)
        return NSSize(width: statusItemWidth, height: h)
    }

    func start() {
        NSLog("LeetViz: start() — building status item")
        statusItem = NSStatusBar.system.statusItem(withLength: statusItemWidth)
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            (button.cell as? NSButtonCell)?.highlightsBy = []
            NSLog("LeetViz: status button bounds=%@", NSStringFromRect(button.bounds))
        } else {
            NSLog("LeetViz: WARNING statusItem.button is nil")
        }

        renderer.style = SettingsStore.shared.style
        renderer.accent = SettingsStore.shared.accent

        buildMenu()
        statusItem.menu = menu

        // Render the initial baseline frame so the menu bar item is visible
        // immediately — before any audio samples have arrived.
        renderAndAssign()

        audio.delegate = self
        audio.start()
        NSLog("LeetViz: audio.start() invoked")

        startRenderTimer()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(powerStateChanged),
            name: NSNotification.Name.NSProcessInfoPowerStateDidChange,
            object: nil
        )
    }

    func stop() {
        renderTimer?.invalidate()
        renderTimer = nil
        audio.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Render loop

    private func currentFPS() -> Double {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? lowPowerFPS : activeFPS
    }

    private func startRenderTimer() {
        renderTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / currentFPS(), repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        renderTimer = timer
    }

    private func stopRenderTimer() {
        renderTimer?.invalidate()
        renderTimer = nil
        renderer.clear()
        renderAndAssign() // freeze a clean baseline frame on the menu bar
    }

    @objc private func powerStateChanged() {
        guard renderTimer != nil else { return }
        startRenderTimer()
    }

    private func renderAndAssign() {
        let image = renderer.renderImage(size: imageSize)
        statusItem.button?.image = image
    }

    private func visiblyChanged(newBands: [Float], newLevel: Float) -> Bool {
        if abs(newLevel - lastDrawnLevel) > visualEpsilon { return true }
        guard lastDrawnBands.count == newBands.count else { return true }
        for i in 0..<newBands.count {
            if abs(newBands[i] - lastDrawnBands[i]) > visualEpsilon { return true }
        }
        return false
    }

    private var loggedFirstAudio = false

    // Track what we last drew so we can skip redraws when the difference is too
    // small to see — saves CGImage creation + AppKit invalidation each frame.
    private var lastDrawnBands: [Float] = []
    private var lastDrawnLevel: Float = -1
    /// Minimum band-value delta that's worth a redraw. 0.012 ≈ ~0.25 px on the
    /// tallest bar — anything smaller than that is invisible anyway.
    private let visualEpsilon: Float = 0.012

    // Waveform shaping. The raw signal has too much high-frequency content
    // packed into too few pixels — it just looks like noise. Three fixes:
    //  1. Single-pole low-pass to keep only the visually-coherent low/mid bands
    //     (~1.5 kHz cutoff, set by `waveLPFAlpha`).
    //  2. Trigger on a rising zero-crossing so consecutive frames line up
    //     (classic oscilloscope sync — without it the wave appears to "scroll"
    //     unpredictably).
    //  3. Temporal blending so what little jitter remains is dampened.
    private let waveSourceCount = 1024
    private let waveDisplayCount = 256
    private let waveLPFAlpha: Float = 0.18
    private let waveBlend: Float = 0.45 // how much of last frame to keep
    private var waveLPFState: Float = 0
    private var smoothedWave: [Float] = [Float](repeating: 0, count: 256)

    // Level smoothing for the pulsing-blocks fallback / silence detector.
    private var smoothedLevel: Float = 0

    private func smoothedLevel(from raw: Float) -> Float {
        if raw > smoothedLevel {
            smoothedLevel = smoothedLevel + (raw - smoothedLevel) * 0.45
        } else {
            smoothedLevel = smoothedLevel * 0.90
        }
        return smoothedLevel
    }

    private func processWave(from samples: [Float]) -> [Float] {
        guard samples.count >= waveSourceCount else { return smoothedWave }
        let buf = Array(samples.suffix(waveSourceCount))

        var filtered = [Float](repeating: 0, count: buf.count)
        var state = waveLPFState
        for i in 0..<buf.count {
            state += (buf[i] - state) * waveLPFAlpha
            filtered[i] = state
        }
        waveLPFState = state

        // Look for a rising zero-crossing in the first half of the buffer so
        // the displayed window starts at consistent phase across frames.
        let searchEnd = max(1, filtered.count - waveDisplayCount)
        var startIdx = 0
        for i in 1..<searchEnd {
            if filtered[i - 1] <= 0 && filtered[i] > 0 {
                startIdx = i
                break
            }
        }
        let endIdx = min(startIdx + waveDisplayCount, filtered.count)
        let triggered = Array(filtered[startIdx..<endIdx])

        if smoothedWave.count == triggered.count {
            for i in 0..<triggered.count {
                smoothedWave[i] = smoothedWave[i] * waveBlend + triggered[i] * (1 - waveBlend)
            }
        } else {
            smoothedWave = triggered
        }
        return smoothedWave
    }

    private func tick() {
        let samples = audio.recentSamples()

        let bands: [Float]
        let wave: [Float]
        let level: Float

        if samples.count >= 1024 {
            if !loggedFirstAudio {
                loggedFirstAudio = true
                NSLog("LeetViz: first audio batch received (%d samples in ring)", samples.count)
            }
            bands = fft.process(samples: samples)
            let tail = samples.suffix(512)
            var sum: Float = 0
            for s in tail { sum += s * s }
            let rms = sqrtf(sum / Float(max(1, tail.count)))
            level = smoothedLevel(from: min(Float(1), rms * 6))
            wave = processWave(from: samples)
        } else {
            // No audio yet — keep the baseline frame visible.
            bands = [Float](repeating: 0, count: 16)
            wave = []
            level = 0
        }

        let bandsActive = bands.contains(where: { $0 > silenceLevelThreshold })
        let changed = renderer.update(bands: bands, waveform: wave, level: level)

        // Only push a new image into the menu bar when something visibly changed
        // — sub-pixel deltas are wasted work + cause AppKit invalidation churn.
        if changed && visiblyChanged(newBands: bands, newLevel: level) {
            renderAndAssign()
            lastDrawnBands = bands
            lastDrawnLevel = level
        }

        if !bandsActive && level < silenceLevelThreshold {
            silenceFrames += 1
            if silenceFrames >= silenceFramesToIdle {
                // Bars decayed and there's no audio. Park the render timer; the
                // audio callback will fire `didWake` to bring us back.
                stopRenderTimer()
            }
        } else {
            silenceFrames = 0
        }
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false

        let styleItem = NSMenuItem(title: "Visualizer Style", action: nil, keyEquivalent: "")
        let styleMenu = NSMenu()
        for style in VisualizerStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = style.rawValue
            item.state = (style == SettingsStore.shared.style) ? .on : .off
            styleMenu.addItem(item)
        }
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let accentItem = NSMenuItem(title: "Accent Color", action: nil, keyEquivalent: "")
        let accentMenu = NSMenu()
        for accent in AccentColor.allCases {
            let item = NSMenuItem(title: accent.displayName, action: #selector(selectAccent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = accent.rawValue
            item.state = (accent == SettingsStore.shared.accent) ? .on : .off
            accentMenu.addItem(item)
        }
        accentItem.submenu = accentMenu
        menu.addItem(accentItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Open at Login",
                                   action: #selector(toggleOpenAtLogin),
                                   keyEquivalent: "")
        loginItem.target = self
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        menu.addItem(loginItem)

        let recItem = NSMenuItem(title: "Open Screen Recording Settings…",
                                 action: #selector(openRecordingSettings),
                                 keyEquivalent: "")
        recItem.target = self
        menu.addItem(recItem)

        menu.addItem(.separator())

        // Use our own selector (not NSApplication.terminate:) — Tahoe-era AppKit
        // auto-decorates the system terminate action with an icon we can't easily
        // suppress. Routing through a plain @objc method on self keeps it icon-free.
        let quit = NSMenuItem(title: "Quit LeetViz",
                              action: #selector(quitApp),
                              keyEquivalent: "q")
        quit.target = self
        quit.image = nil
        menu.addItem(quit)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    @objc private func toggleOpenAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                sender.state = .off
                NSLog("LeetViz: Open at Login disabled")
            } else {
                try service.register()
                sender.state = (service.status == .enabled) ? .on : .off
                NSLog("LeetViz: Open at Login enabled (status=%d)", service.status.rawValue)
            }
        } catch {
            NSLog("LeetViz: Open at Login toggle failed: %@", error.localizedDescription)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = VisualizerStyle(rawValue: raw) else { return }
        SettingsStore.shared.style = style
        renderer.style = style
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        renderAndAssign()
        if renderTimer == nil { startRenderTimer() }
    }

    @objc private func selectAccent(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let accent = AccentColor(rawValue: raw) else { return }
        SettingsStore.shared.accent = accent
        renderer.accent = accent
        sender.menu?.items.forEach { $0.state = ($0 == sender) ? .on : .off }
        renderAndAssign()
        if renderTimer == nil { startRenderTimer() }
    }

    @objc private func openRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - AudioCaptureManagerDelegate

    func audioCaptureManagerNeedsPermission(_ manager: AudioCaptureManager) {
        NSLog("LeetViz: audio permission missing — adding banner to menu")
        guard !permissionItemInMenu else { return }
        permissionItemInMenu = true
        let title = "⚠ Grant Screen Recording permission…"
        let item = NSMenuItem(title: title,
                              action: #selector(openRecordingSettings),
                              keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
    }

    func audioCaptureManager(_ manager: AudioCaptureManager, didFailWith error: Error) {
        NSLog("LeetViz audio capture error: %@", error.localizedDescription)
    }

    func audioCaptureManagerDidWake(_ manager: AudioCaptureManager) {
        NSLog("LeetViz: audio wake (silent → audible)")
        silenceFrames = 0
        if renderTimer == nil {
            startRenderTimer()
        }
    }
}
