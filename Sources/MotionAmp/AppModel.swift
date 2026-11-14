import AVFoundation
import MotionAmpCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
  @Published var info: VideoInfo?
  @Published var analysis: MotionAnalysis?
  @Published var audioSpectrum: (binHz: Double, amplitude: [Float])?
  @Published var lo = 5.0
  @Published var hi = 15.0
  @Published var alpha = 20.0
  @Published var showOverlay = true
  @Published var overlayOpacity = 0.85
  @Published var heat: CGImage?
  @Published var heatMax: Float = 0
  @Published var filterAudio = true
  @Published var showAmplified = false
  @Published var hasAmplified = false
  @Published var amplifiedLabel = ""
  @Published var status = "Open a video to begin."
  @Published var progress: Double?
  @Published var isPlaying = false
  @Published var time = 0.0
  @Published var rate: Float = 1
  @Published var renderMaxDimension = 0
  @Published var cellSpectrum: [Float]?
  @Published var cellLabel = ""
  @Published var captureFps = 0.0
  /// Values of the `--fps`, `--lo`, and `--hi` launch arguments.
  var launchOptions: [String: Double] = [:]

  let player = AVPlayer()
  private var audio: AudioData?
  private var amplifiedURL: URL?
  private var job: Task<Void, Never>?
  private let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("MotionAmp-\(UUID().uuidString)")

  init() {
    try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    player.addPeriodicTimeObserver(
      forInterval: CMTime(value: 1, timescale: 30), queue: .main
    ) { [weak self] t in
      Task { @MainActor in self?.time = t.seconds }
    }
    NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.isPlaying else { return }
        // Loop.
        await self.player.seek(to: .zero)
        self.player.rate = self.rate
      }
    }
  }

  var busy: Bool { progress != nil }

  // MARK: Open

  func openPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie]
    if panel.runModal() == .OK, let url = panel.url { open(url) }
  }

  func open(_ url: URL) {
    job?.cancel()
    player.pause()
    isPlaying = false
    analysis = nil
    audioSpectrum = nil
    audio = nil
    heat = nil
    cellSpectrum = nil
    amplifiedURL = nil
    hasAmplified = false
    showAmplified = false
    status = "Reading \(url.lastPathComponent)"
    progress = 0
    job = Task {
      do {
        let info = try await VideoInfo.load(url)
        self.info = info
        await rebuildItem()
        async let audioLoad = Task.detached { try await AudioData.load(url) }.value
        status = "Measuring motion"
        let result = try await Task.detached(priority: .userInitiated) { [weak self] in
          try await analyzeMotion(url: url) { p in
            Task { @MainActor in self?.progress = p }
          }
        }.value
        if let a = try await audioLoad {
          audio = a
          audioSpectrum = await Task.detached { a.spectrum() }.value
        }
        analysis = result
        captureFps = result.fps
        progress = nil
        if let top = result.peaks(count: 1).first {
          selectPeak(top.hz)
        } else {
          setBand(lo: lo, hi: hi, final: true)
        }
        status = String(
          format: "%d frames at %.1f fps. Vibrations up to %.0f Hz are measurable.",
          result.frames, result.fps, result.nyquist)
        if let fps = launchOptions["--fps"] { setCaptureFps(fps) }
        if let lo = launchOptions["--lo"], let hi = launchOptions["--hi"] {
          setBand(lo: lo, hi: hi, final: true)
        }
        launchOptions = [:]
        await debugSnapshot()
      } catch is CancellationError {
      } catch {
        progress = nil
        status = "Failed: \(error)"
      }
    }
  }

  /// Writes a PNG file of the window for scripted checks.
  ///
  /// If the `MOTIONAMP_AUTORENDER` environment variable is set, renders the
  /// amplified video first. If `MOTIONAMP_SNAPSHOT` holds a file path, writes
  /// the snapshot there and quits. The snapshot omits the video layer.
  private func debugSnapshot() async {
    if ProcessInfo.processInfo.environment["MOTIONAMP_AUTORENDER"] != nil {
      render()
      await job?.value
    }
    guard let path = ProcessInfo.processInfo.environment["MOTIONAMP_SNAPSHOT"] else { return }
    try? await Task.sleep(nanoseconds: 1_500_000_000)
    if let item = player.currentItem {
      let tracks = (try? await item.asset.load(.tracks)) ?? []
      print(
        "item status \(item.status.rawValue), error \(String(describing: item.error)),",
        "duration \(item.duration.seconds), tracks \(tracks.map { $0.mediaType.rawValue })")
    }
    if let view = NSApp.windows.first?.contentView,
      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    {
      view.cacheDisplay(in: view.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    print("status: \(status)")
    NSApp.terminate(nil)
  }

  /// Reinterprets the clip at a different capture rate.
  ///
  /// High-speed footage is often stored at 30 frames per second. The
  /// frequencies in the plot and the band then scale with the true rate.
  func setCaptureFps(_ fps: Double) {
    guard let a = analysis, fps >= 1, fps != a.fps else {
      captureFps = analysis?.fps ?? 0
      return
    }
    let ratio = fps / a.fps
    analysis = a.rescaled(fps: fps)
    captureFps = fps
    cellSpectrum = nil
    cellLabel = ""
    setBand(lo: lo * ratio, hi: hi * ratio, final: true)
    status = String(format: "Capture rate set to %.1f fps. Vibrations up to %.0f Hz are measurable.", fps, fps / 2)
  }

  // MARK: Band

  /// Sets the band to a narrow range around a frequency.
  func selectPeak(_ hz: Double) {
    let half = max(1.0, hz * 0.06)
    setBand(lo: hz - half, hi: hz + half, final: true)
  }

  /// Sets the frequency band and updates the heat map.
  ///
  /// - Parameter final: If true, also rebuilds the filtered audio.
  func setBand(lo newLo: Double, hi newHi: Double, final: Bool) {
    let top = (analysis?.nyquist ?? 60) * 0.98
    lo = min(max(0.2, newLo), top - 0.5)
    hi = min(max(lo + 0.5, newHi), top)
    updateHeat()
    if final, filterAudio { Task { await rebuildItem() } }
  }

  func updateHeat() {
    guard let a = analysis, let info else { return }
    let values = a.heat(lo: lo, hi: hi)
    // Scale to the 99.8th percentile, but never under three times the noise
    // floor. A band that holds only noise then stays mostly transparent.
    let sorted = values.sorted()
    let p = sorted[min(sorted.count - 1, sorted.count * 998 / 1000)]
    heatMax = max(p, 3 * a.noiseFloor)
    heat = heatImage(
      values: values, width: a.gridWidth, height: a.gridHeight, maxValue: heatMax,
      quarterTurns: info.quarterTurns)
  }

  /// Selects the grid cell under a point given as fractions of the displayed frame.
  func selectCell(u: Double, v: Double) {
    guard let a = analysis, let info else { return }
    // Undo the display rotation to get encoded-frame fractions.
    let (x, y): (Double, Double)
    switch info.quarterTurns {
    case 1: (x, y) = (v, 1 - u)
    case 2: (x, y) = (1 - u, 1 - v)
    case 3: (x, y) = (1 - v, u)
    default: (x, y) = (u, v)
    }
    let cx = min(a.gridWidth - 1, max(0, Int(x * Double(a.gridWidth))))
    let cy = min(a.gridHeight - 1, max(0, Int(y * Double(a.gridHeight))))
    let s = a.spectrum(cellX: cx, cellY: cy)
    cellSpectrum = s
    let peak = (2..<s.count).max { s[$0] < s[$1] } ?? 0
    cellLabel = String(
      format: "Selected point: strongest at %.1f Hz, %.3f px", Double(peak) * a.binHz, s[peak])
  }

  // MARK: Playback

  func togglePlay() {
    if isPlaying {
      player.pause()
    } else {
      player.rate = rate
    }
    isPlaying.toggle()
  }

  func setRate(_ r: Float) {
    rate = r
    if isPlaying { player.rate = r }
  }

  func seek(_ seconds: Double) {
    player.seek(
      to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
      toleranceAfter: .zero)
  }

  /// Builds the player item from the chosen video and audio sources.
  func rebuildItem() async {
    guard let info else { return }
    do {
      let composition = try await makeComposition(info: info)
      let t = player.currentTime()
      player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
      if t.isValid, t.seconds > 0 {
        await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
      }
      if isPlaying { player.rate = rate }
    } catch {
      status = "Playback setup failed: \(error)"
    }
  }

  private func makeComposition(info: VideoInfo) async throws -> AVMutableComposition {
    let composition = AVMutableComposition()
    let videoURL = (showAmplified ? amplifiedURL : nil) ?? info.url
    let videoAsset = AVURLAsset(url: videoURL)
    if let track = try await videoAsset.loadTracks(withMediaType: .video).first,
      let out = composition.addMutableTrack(
        withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
    {
      let range = try await track.load(.timeRange)
      try out.insertTimeRange(range, of: track, at: range.start)
      out.preferredTransform = info.transform
    }
    guard let audio else { return composition }
    var audioURL = info.url
    var start: CMTime?
    if filterAudio, analysis != nil {
      let band = (lo, hi)
      let file = workDir.appendingPathComponent("audio-\(UUID().uuidString).caf")
      try await Task.detached {
        try audio.write(to: file, lo: band.0, hi: band.1, normalize: true)
      }.value
      audioURL = file
      start = CMTime(seconds: audio.startTime, preferredTimescale: 48000)
    }
    // Keep the asset alive until the insert. A track of a released asset
    // fails to insert with error -12780.
    let audioAsset = AVURLAsset(url: audioURL)
    if let track = try await audioAsset.loadTracks(withMediaType: .audio).first,
      let out = composition.addMutableTrack(
        withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    {
      let range = try await track.load(.timeRange)
      try out.insertTimeRange(range, of: track, at: start ?? range.start)
    }
    return composition
  }

  // MARK: Render and export

  func render() {
    guard let info, let a = analysis, !busy else { return }
    let (lo, hi, alpha) = (self.lo, self.hi, self.alpha)
    let maxDim = renderMaxDimension > 0 ? renderMaxDimension : nil
    let output = workDir.appendingPathComponent("amplified-\(UUID().uuidString).mov")
    status = "Rendering amplified video"
    progress = 0
    job = Task {
      do {
        let started = Date()
        try await Task.detached(priority: .userInitiated) { [weak self] in
          try await renderMagnified(
            url: info.url, output: output, lo: lo, hi: hi, alpha: alpha, fps: a.fps,
            maxDimension: maxDim
          ) { p in
            Task { @MainActor in self?.progress = p }
          }
        }.value
        amplifiedURL = output
        hasAmplified = true
        showAmplified = true
        amplifiedLabel = String(format: "%.1f–%.1f Hz, gain %.0f", lo, hi, alpha)
        progress = nil
        status = String(format: "Rendered in %.0f s.", Date().timeIntervalSince(started))
        await rebuildItem()
      } catch is CancellationError {
        progress = nil
        status = "Render canceled."
      } catch {
        progress = nil
        status = "Render failed: \(error)"
      }
    }
  }

  func cancelJob() { job?.cancel() }

  /// Saves the video and audio that the player shows to a movie file.
  func export() {
    guard let info, !busy else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.quickTimeMovie]
    panel.nameFieldStringValue =
      info.url.deletingPathExtension().lastPathComponent + "-amplified.mov"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      do {
        let composition = try await makeComposition(info: info)
        guard
          let session = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough)
        else { throw EngineError.message("The export session failed to start.") }
        try? FileManager.default.removeItem(at: url)
        try await session.export(to: url, as: .mov)
        status = "Exported \(url.lastPathComponent)."
      } catch {
        status = "Export failed: \(error)"
      }
    }
  }
}
