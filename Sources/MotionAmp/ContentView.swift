import MotionAmpCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 0) {
        VStack(spacing: 0) {
          videoArea
          transport.padding(.horizontal, 14).padding(.vertical, 8)
          SpectrumView().frame(height: 210).padding(.horizontal, 14).padding(.bottom, 12)
        }
        Divider()
        Sidebar().frame(width: 290)
      }
      Divider()
      statusBar
    }
    .onDrop(of: [.fileURL], isTargeted: nil) { providers in
      _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
        if let url { Task { @MainActor in model.open(url) } }
      }
      return true
    }
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
        .padding(10)
      } else {
        VStack(spacing: 12) {
          Image(systemName: "waveform.path.ecg.rectangle")
            .font(.system(size: 44)).foregroundStyle(.white.opacity(0.5))
          Text("Drop a video here").font(.title3).foregroundStyle(.white.opacity(0.8))
          Button("Open Video…") { model.openPanel() }
        }
      }
    }
    .overlay(alignment: .top) {
      if model.hasAmplified {
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
        .labelsHidden()
        .frame(width: 200)
        .padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .padding(.top, 14)
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
      Text(String(format: "%.2f s", model.time)).monospacedDigit()
        .frame(width: 60, alignment: .trailing)
      Picker("Speed", selection: Binding(get: { model.rate }, set: { model.setRate($0) })) {
        Text("1×").tag(Float(1))
        Text("1/2×").tag(Float(0.5))
        Text("1/4×").tag(Float(0.25))
        Text("1/8×").tag(Float(0.125))
      }
      .labelsHidden()
      .frame(width: 76)
      .help("Playback speed")
    }
  }

  private var statusBar: some View {
    HStack(spacing: 10) {
      Text(model.status).lineLimit(1).truncationMode(.tail)
      Spacer()
      if let p = model.progress {
        ProgressView(value: p).frame(width: 160)
        Button("Cancel") { model.cancelJob() }.controlSize(.small)
      }
    }
    .font(.callout)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 14)
    .frame(height: 30)
  }
}

/// Holds the clip, band, view, and render settings.
struct Sidebar: View {
  @EnvironmentObject var model: AppModel

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        clip
        if model.analysis != nil {
          band
          view
          amplify
        }
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(Color(nsColor: .windowBackgroundColor))
  }

  private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content)
    -> some View
  {
    VStack(alignment: .leading, spacing: 9) {
      Text(title.uppercased()).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
      content()
    }
  }

  private func row<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content)
    -> some View
  {
    HStack {
      Text(label)
      Spacer(minLength: 8)
      content()
    }
  }

  private var clip: some View {
    section("Clip") {
      if let info = model.info {
        Text(info.url.lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
        Text(
          "\(Int(info.displaySize.width))×\(Int(info.displaySize.height))"
            + (model.analysis.map { ", \($0.frames) frames" } ?? "")
        )
        .foregroundStyle(.secondary)
        if model.analysis != nil {
          row("Capture rate") {
            TextField(
              "",
              value: Binding(get: { model.captureFps }, set: { model.setCaptureFps($0) }),
              format: .number.precision(.fractionLength(0...2))
            )
            .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
            Text("fps").foregroundStyle(.secondary)
          }
          .help("Set the true capture rate for high-speed footage that is stored at a slower rate.")
        }
      } else {
        Text("No clip is open.").foregroundStyle(.secondary)
      }
      Button("Open Video…") { model.openPanel() }
    }
  }

  private var band: some View {
    section("Frequency band") {
      HStack(spacing: 6) {
        bandField(
          Binding(get: { model.lo }, set: { model.setBand(lo: $0, hi: model.hi, final: true) }))
        Text("to")
        bandField(
          Binding(get: { model.hi }, set: { model.setBand(lo: model.lo, hi: $0, final: true) }))
        Text("Hz").foregroundStyle(.secondary)
      }
      if model.peaks.isEmpty {
        Text("No distinct peaks. Drag on the plot to select a band.")
          .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      } else {
        Text("Distinct peaks").font(.callout).foregroundStyle(.secondary)
        LazyVGrid(
          columns: [GridItem(.adaptive(minimum: 78), spacing: 6)], alignment: .leading, spacing: 6
        ) {
          ForEach(model.peaks, id: \.hz) { p in
            let selected = p.hz >= model.lo && p.hz <= model.hi
            Button {
              model.selectPeak(p.hz)
            } label: {
              Text(String(format: "%.1f Hz", p.hz))
                .fontWeight(selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                  selected ? Color.accentColor : Color(nsColor: .controlColor),
                  in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.gray.opacity(0.3)))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
  }

  private var view: some View {
    section("Heat map") {
      Toggle("Show where the frame moves", isOn: $model.showOverlay)
      row("Opacity") {
        Slider(value: $model.overlayOpacity, in: 0.1...1).frame(width: 150)
      }
      .disabled(!model.showOverlay)
      VStack(alignment: .leading, spacing: 3) {
        // The same ramp that `heatImage` draws.
        LinearGradient(
          colors: [.blue.opacity(0.15), .cyan, .green, .yellow, .red], startPoint: .leading,
          endPoint: .trailing
        )
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        HStack {
          Text("0")
          Spacer()
          Text(String(format: "%.3f px or more", model.heatMax))
        }
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Text(model.cellLabel.isEmpty ? "Click the video to inspect one point." : model.cellLabel)
        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle(
        "Filter audio to the band",
        isOn: Binding(
          get: { model.filterAudio },
          set: { v in
            model.filterAudio = v
            Task { await model.rebuildItem() }
          })
      )
      .disabled(model.audioSpectrum == nil)
      if model.audioSpectrum == nil {
        Text("This clip has no audio track.").font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  private var amplify: some View {
    section("Amplify") {
      row(String(format: "Gain %.0f", model.alpha)) {
        Slider(value: $model.alpha, in: 2...200).frame(width: 150)
      }
      .monospacedDigit()
      row("Smoothing") {
        Picker("", selection: $model.smoothing) {
          Text("Off").tag(0.0)
          Text("2").tag(2.0)
          Text("4").tag(4.0)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
      }
      .help("Smooths the amplified motion across neighboring pixels to suppress noise.")
      row("Output size") {
        Picker("", selection: $model.renderMaxDimension) {
          Text("Full").tag(0)
          Text("1920").tag(1920)
          Text("1280").tag(1280)
        }
        .pickerStyle(.segmented).labelsHidden().frame(width: 150)
      }
      Button {
        model.render()
      } label: {
        Text("Render Amplified Video").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(model.busy)
      if model.hasAmplified {
        Text("Rendered: \(model.amplifiedLabel)")
          .font(.callout).foregroundStyle(.secondary)
        Button {
          model.export()
        } label: {
          Text("Export…").frame(maxWidth: .infinity)
        }
        .disabled(model.busy)
      }
    }
  }

  private func bandField(_ value: Binding<Double>) -> some View {
    TextField("", value: value, format: .number.precision(.fractionLength(1)))
      .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
  }
}

/// Plots the motion and audio spectra and lets the user drag to select a band.
struct SpectrumView: View {
  @EnvironmentObject var model: AppModel
  private let rangeDb: Float = 50
  private let axisHeight: CGFloat = 18
  private let headroom: CGFloat = 22

  var body: some View {
    GeometryReader { geo in
      let nyquist = model.analysis?.nyquist ?? 60
      Canvas { ctx, size in
        draw(&ctx, size: size, nyquist: nyquist)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25)))
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

  private func yFor(_ db: Float, _ size: CGSize) -> CGFloat {
    headroom + (size.height - axisHeight - headroom) * CGFloat(-db / rangeDb)
  }

  private func path(_ cols: [Float], size: CGSize, closed: Bool) -> Path {
    var p = Path()
    let floor = size.height - axisHeight
    for (x, db) in cols.enumerated() {
      let pt = CGPoint(x: CGFloat(x), y: yFor(db, size))
      if x == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
    }
    if closed, !cols.isEmpty {
      p.addLine(to: CGPoint(x: CGFloat(cols.count - 1), y: floor))
      p.addLine(to: CGPoint(x: 0, y: floor))
      p.closeSubpath()
    }
    return p
  }

  private func draw(_ ctx: inout GraphicsContext, size: CGSize, nyquist: Double) {
    let width = Int(size.width)
    let floor = size.height - axisHeight
    let step = [0.5, 1.0, 2, 5, 10, 20, 25, 50, 100].first { nyquist / $0 <= 12 } ?? 200
    var f = step
    while f < nyquist {
      let x = CGFloat(f / nyquist) * size.width
      ctx.stroke(
        Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: floor)) },
        with: .color(.gray.opacity(0.18)))
      ctx.draw(
        Text(String(format: step < 1 ? "%.1f Hz" : "%.0f Hz", f)).font(.caption2)
          .foregroundStyle(.secondary),
        at: CGPoint(x: x, y: size.height - axisHeight / 2))
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
    let bandRect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: floor)
    ctx.fill(Path(bandRect), with: .color(.accentColor.opacity(0.18)))
    ctx.stroke(
      Path { p in
        for x in [bandRect.minX, bandRect.maxX] {
          p.move(to: CGPoint(x: x, y: 0))
          p.addLine(to: CGPoint(x: x, y: floor))
        }
      }, with: .color(.accentColor.opacity(0.7)), lineWidth: 1)

    let motion = columns(a.globalSpectrum, binHz: a.binHz, nyquist: nyquist, width: width)
    ctx.fill(path(motion, size: size, closed: true), with: .color(.teal.opacity(0.35)))
    ctx.stroke(path(motion, size: size, closed: false), with: .color(.teal), lineWidth: 1.2)
    if let s = model.audioSpectrum {
      let audio = columns(s.amplitude, binHz: s.binHz, nyquist: nyquist, width: width)
      ctx.stroke(path(audio, size: size, closed: false), with: .color(.orange), lineWidth: 1.2)
    }
    if let s = model.cellSpectrum {
      let cell = columns(s, binHz: a.binHz, nyquist: nyquist, width: width)
      ctx.stroke(path(cell, size: size, closed: false), with: .color(.purple), lineWidth: 1.2)
    }
    // Label each distinct peak over the motion curve.
    for p in model.peaks {
      let x = Int(p.hz / nyquist * Double(width))
      guard x >= 0, x < motion.count else { continue }
      let near = motion[max(0, x - 2)...min(motion.count - 1, x + 2)].max() ?? motion[x]
      let y = yFor(near, size)
      ctx.fill(
        Path(ellipseIn: CGRect(x: CGFloat(x) - 2.5, y: y - 2.5, width: 5, height: 5)),
        with: .color(.teal))
      ctx.draw(
        Text(String(format: "%.1f", p.hz)).font(.caption2).fontWeight(.semibold)
          .foregroundStyle(.primary),
        at: CGPoint(x: min(max(18, CGFloat(x)), size.width - 18), y: max(8, y - 10)))
    }
    var legend = Text("■ Motion ").foregroundStyle(.teal)
    if model.audioSpectrum != nil { legend = legend + Text("■ Audio ").foregroundStyle(.orange) }
    if model.cellSpectrum != nil {
      legend = legend + Text("■ Selected point").foregroundStyle(.purple)
    }
    ctx.draw(
      legend.font(.caption), at: CGPoint(x: size.width - 10, y: 11), anchor: .trailing)
  }
}
