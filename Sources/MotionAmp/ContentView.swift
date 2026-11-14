import MotionAmpCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      videoArea
      Divider()
      transport.padding(.horizontal, 12).padding(.vertical, 6)
      SpectrumView().frame(height: 170).padding(.horizontal, 12)
      controls.padding(12)
    }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
        if let url { Task { @MainActor in model.open(url) } }
      }
      return true
    }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Button("Open Video…") { model.openPanel() }
      if let info = model.info {
        Text(info.url.lastPathComponent).fontWeight(.medium)
        Text("\(Int(info.displaySize.width))×\(Int(info.displaySize.height))")
          .foregroundStyle(.secondary)
      }
      Spacer()
      Text(model.status).foregroundStyle(.secondary).lineLimit(1)
      if let p = model.progress {
        ProgressView(value: p).frame(width: 140)
        Button("Cancel") { model.cancelJob() }
      }
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }

  private var videoArea: some View {
    ZStack {
      Color.black
      if let info = model.info {
        ZStack {
          PlayerView(player: model.player)
          if model.showOverlay, let heat = model.heat {
            Image(decorative: heat, scale: 1)
              .resizable()
              .interpolation(.medium)
              .opacity(model.overlayOpacity)
              .allowsHitTesting(false)
          }
          GeometryReader { geo in
            Color.clear.contentShape(Rectangle()).onTapGesture { point in
              model.selectCell(u: point.x / geo.size.width, v: point.y / geo.size.height)
            }
          }
        }
        .aspectRatio(info.displaySize, contentMode: .fit)
      } else {
        Text("Drop a video here, or click Open Video.")
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private var transport: some View {
    HStack(spacing: 12) {
      Button {
        model.togglePlay()
      } label: {
        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
      }
      .keyboardShortcut(.space, modifiers: [])
      .disabled(model.info == nil)
      Slider(
        value: Binding(get: { model.time }, set: { model.seek($0) }),
        in: 0...max(0.01, model.info?.duration ?? 1))
      Text(String(format: "%.2f s", model.time)).monospacedDigit().frame(width: 64)
      Picker("Speed", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
        Text("1×").tag(Float(1))
        Text("1/2×").tag(Float(0.5))
        Text("1/4×").tag(Float(0.25))
        Text("1/8×").tag(Float(0.125))
      }
      .frame(width: 130)
      Picker(
        "",
        selection: Binding(
          get: { model.showAmplified },
          set: { v in
            model.showAmplified = v
            Task { await model.rebuildItem() }
          })
      ) {
        Text("Original").tag(false)
        Text("Amplified").tag(true)
      }
      .pickerStyle(.segmented)
      .frame(width: 180)
      .disabled(!model.hasAmplified)
    }
  }

  private var controls: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Text("Band")
        bandField(Binding(get: { model.lo }, set: { model.setBand(lo: $0, hi: model.hi, final: true) }))
        Text("to")
        bandField(Binding(get: { model.hi }, set: { model.setBand(lo: model.lo, hi: $0, final: true) }))
        Text("Hz")
        if let a = model.analysis {
          Text("Peaks:").foregroundStyle(.secondary).padding(.leading, 8)
          ForEach(a.peaks(count: 5), id: \.hz) { p in
            Button(String(format: "%.1f Hz", p.hz)) { model.selectPeak(p.hz) }
              .buttonStyle(.bordered).controlSize(.small)
          }
        }
        Spacer()
        if model.heatMax > 0 {
          Text(String(format: "Red = %.3f px or more", model.heatMax)).foregroundStyle(.secondary)
        }
      }
      HStack(spacing: 14) {
        Toggle("Heat map", isOn: $model.showOverlay)
        Slider(value: $model.overlayOpacity, in: 0.1...1).frame(width: 90)
        Toggle(
          "Filter audio to band",
          isOn: Binding(
            get: { model.filterAudio },
            set: { v in
              model.filterAudio = v
              Task { await model.rebuildItem() }
            }))
        Spacer()
        Text(String(format: "Gain %.0f", model.alpha)).monospacedDigit()
        Slider(value: $model.alpha, in: 2...200).frame(width: 130)
        Picker("Size", selection: $model.renderMaxDimension) {
          Text("Full").tag(0)
          Text("1920").tag(1920)
          Text("1280").tag(1280)
        }
        .frame(width: 120)
        Button("Render Amplified Video") { model.render() }
          .fixedSize()
          .disabled(model.analysis == nil || model.busy)
        Button("Export…") { model.export() }.fixedSize()
          .disabled(model.info == nil || model.busy)
      }
      HStack {
        Text(model.cellLabel.isEmpty ? "Click the video to inspect one point." : model.cellLabel)
        Spacer()
        if model.hasAmplified { Text("Amplified render: \(model.amplifiedLabel)") }
      }
      .font(.callout).foregroundStyle(.secondary)
    }
  }

  private func bandField(_ value: Binding<Double>) -> some View {
    TextField("", value: value, format: .number.precision(.fractionLength(1)))
      .textFieldStyle(.roundedBorder).frame(width: 64).multilineTextAlignment(.trailing)
  }
}

/// Plots the motion and audio spectra and lets the user drag to select a band.
struct SpectrumView: View {
  @EnvironmentObject var model: AppModel
  private let rangeDb: Float = 50

  var body: some View {
    GeometryReader { geo in
      let nyquist = model.analysis?.nyquist ?? 60
      Canvas { ctx, size in
        draw(&ctx, size: size, nyquist: nyquist)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { g in band(g, geo.size.width, nyquist, final: false) }
          .onEnded { g in band(g, geo.size.width, nyquist, final: true) }
      )
    }
  }

  private func band(_ g: DragGesture.Value, _ width: CGFloat, _ nyquist: Double, final: Bool) {
    guard model.analysis != nil else { return }
    let a = Double(g.startLocation.x / width) * nyquist
    let b = Double(g.location.x / width) * nyquist
    if abs(g.translation.width) < 3 {
      if final { model.selectPeak(a) }
    } else {
      model.setBand(lo: min(a, b), hi: max(a, b), final: final)
    }
  }

  /// Gets one value per horizontal point: the largest bin under that point, in dB under the peak.
  private func columns(_ s: [Float], binHz: Double, nyquist: Double, width: Int) -> [Float] {
    let limit = min(s.count, Int(nyquist / binHz))
    guard limit > 2 else { return [] }
    let top = max(1e-12, s[2..<limit].max() ?? 1)
    return (0..<width).map { x in
      let a = max(2, Int(Double(x) / Double(width) * nyquist / binHz))
      let b = min(limit, max(a + 1, Int(Double(x + 1) / Double(width) * nyquist / binHz)))
      guard a < b else { return -rangeDb }
      return max(-rangeDb, 20 * log10(max(1e-12, s[a..<b].max()!) / top))
    }
  }

  private func path(_ cols: [Float], size: CGSize, closed: Bool) -> Path {
    var p = Path()
    let h = size.height - 16
    for (x, db) in cols.enumerated() {
      let pt = CGPoint(x: CGFloat(x), y: h * CGFloat(-db / rangeDb))
      if x == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    if closed, !cols.isEmpty {
      p.addLine(to: CGPoint(x: CGFloat(cols.count - 1), y: h))
      p.addLine(to: CGPoint(x: 0, y: h))
      p.closeSubpath()
    }
    return p
  }

  private func draw(_ ctx: inout GraphicsContext, size: CGSize, nyquist: Double) {
    let width = Int(size.width)
    let step = [1.0, 2, 5, 10, 20, 25, 50, 100].first { nyquist / $0 <= 12 } ?? 200
    var f = step
    while f < nyquist {
      let x = CGFloat(f / nyquist) * size.width
      ctx.stroke(
        Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height - 16)) },
        with: .color(.gray.opacity(0.2)))
      ctx.draw(
        Text(String(format: "%.0f Hz", f)).font(.caption2).foregroundStyle(.secondary),
        at: CGPoint(x: x, y: size.height - 7))
      f += step
    }
    guard let a = model.analysis else {
      ctx.draw(
        Text("The motion and audio spectra appear here.").foregroundStyle(.secondary),
        at: CGPoint(x: size.width / 2, y: size.height / 2))
      return
    }
    // Selected band.
    let x0 = CGFloat(model.lo / nyquist) * size.width
    let x1 = CGFloat(model.hi / nyquist) * size.width
    ctx.fill(
      Path(CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height - 16)),
      with: .color(.accentColor.opacity(0.22)))

    let motion = columns(a.globalSpectrum, binHz: a.binHz, nyquist: nyquist, width: width)
    ctx.fill(path(motion, size: size, closed: true), with: .color(.teal.opacity(0.45)))
    ctx.stroke(path(motion, size: size, closed: false), with: .color(.teal), lineWidth: 1)
    if let s = model.audioSpectrum {
      let audio = columns(s.amplitude, binHz: s.binHz, nyquist: nyquist, width: width)
      ctx.stroke(path(audio, size: size, closed: false), with: .color(.orange), lineWidth: 1.2)
    }
    if let s = model.cellSpectrum {
      let cell = columns(s, binHz: a.binHz, nyquist: nyquist, width: width)
      ctx.stroke(path(cell, size: size, closed: false), with: .color(.purple), lineWidth: 1.2)
    }
    var legend = Text("■ Motion ").foregroundStyle(.teal)
    if model.audioSpectrum != nil { legend = legend + Text("■ Audio ").foregroundStyle(.orange) }
    if model.cellSpectrum != nil { legend = legend + Text("■ Selected point").foregroundStyle(.purple) }
    ctx.draw(legend.font(.caption), at: CGPoint(x: size.width - 8, y: 10), anchor: .trailing)
    ctx.draw(
      Text("Each curve is in dB under its own peak. Drag to select a band.")
        .font(.caption2).foregroundStyle(.secondary),
      at: CGPoint(x: 8, y: 10), anchor: .leading)
  }
}
