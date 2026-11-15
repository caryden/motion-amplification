import MotionAmpCore
import SwiftUI

/// Plots the audio spectrum over its full range on a logarithmic frequency axis.
///
/// The camera resolves motion only up to half its frame rate, so the motion
/// plot can't show most audible tones. This plot shows them all, shades the
/// range that the camera covers, and marks the multiples of the rotation
/// frequency. A click sets the rotation frequency to the tone under the pointer.
struct AudioSpectrumView: View {
  @EnvironmentObject var model: AppModel
  private let rangeDb: Float = 60
  private let axisHeight: CGFloat = 18
  private let headroom: CGFloat = 20
  private let minHz = 20.0

  private var maxHz: Double { min(10000, (model.audioSpectrum.map { Double($0.amplitude.count) * $0.binHz } ?? 10000)) }

  var body: some View {
    GeometryReader { geo in
      Canvas { ctx, size in
        draw(&ctx, size: size)
      }
      .background(Color(nsColor: .textBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).stroke(.gray.opacity(0.25)))
      .onTapGesture { point in
        model.setFundamental(near: hz(at: point.x, width: geo.size.width))
      }
    }
  }

  private func x(for hz: Double, width: CGFloat) -> CGFloat {
    CGFloat(log(max(hz, minHz) / minHz) / log(maxHz / minHz)) * width
  }

  private func hz(at x: CGFloat, width: CGFloat) -> Double {
    minHz * pow(maxHz / minHz, Double(x / width))
  }

  private func draw(_ ctx: inout GraphicsContext, size: CGSize) {
    guard let sp = model.audioSpectrum else { return }
    let floor = size.height - axisHeight
    let width = Int(size.width)

    // Shade the range that the camera resolves.
    if let nyquist = model.analysis?.nyquist {
      let edge = x(for: nyquist, width: size.width)
      ctx.fill(
        Path(CGRect(x: 0, y: 0, width: edge, height: floor)), with: .color(.teal.opacity(0.10)))
      ctx.draw(
        Text("Camera range").font(.caption2).foregroundStyle(.teal),
        at: CGPoint(x: 8, y: floor - 9), anchor: .leading)
    }
    // Selected band, which is also the audio filter band.
    let b0 = x(for: model.lo, width: size.width)
    let b1 = x(for: model.hi, width: size.width)
    ctx.fill(
      Path(CGRect(x: b0, y: 0, width: max(2, b1 - b0), height: floor)),
      with: .color(.accentColor.opacity(0.18)))

    for tick in [50.0, 100, 200, 500, 1000, 2000, 5000] where tick < maxHz {
      let tx = x(for: tick, width: size.width)
      ctx.stroke(
        Path { $0.move(to: CGPoint(x: tx, y: 0)); $0.addLine(to: CGPoint(x: tx, y: floor)) },
        with: .color(.gray.opacity(0.18)))
      ctx.draw(
        Text(tick >= 1000 ? String(format: "%.0f kHz", tick / 1000) : String(format: "%.0f Hz", tick))
          .font(.caption2).foregroundStyle(.secondary),
        at: CGPoint(x: tx, y: size.height - axisHeight / 2))
    }

    // One value per horizontal point: the loudest bin under that point.
    let limit = sp.amplitude.count
    var cols = [Float](repeating: 0, count: width)
    for px in 0..<width {
      let a = max(1, Int(hz(at: CGFloat(px), width: size.width) / sp.binHz))
      let b = min(limit, max(a + 1, Int(hz(at: CGFloat(px + 1), width: size.width) / sp.binHz)))
      if a < b { cols[px] = sp.amplitude[a..<b].max() ?? 0 }
    }
    let top = max(1e-12, cols.max() ?? 1)
    func y(_ amplitude: Float) -> CGFloat {
      let db = max(-rangeDb, 20 * log10(max(1e-12, amplitude) / top))
      return headroom + (floor - headroom) * CGFloat(-db / rangeDb)
    }
    var line = Path()
    for (px, v) in cols.enumerated() {
      let pt = CGPoint(x: CGFloat(px), y: y(v))
      if px == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
    }
    var fill = line
    fill.addLine(to: CGPoint(x: CGFloat(width - 1), y: floor))
    fill.addLine(to: CGPoint(x: 0, y: floor))
    fill.closeSubpath()
    ctx.fill(fill, with: .color(.orange.opacity(0.22)))
    ctx.stroke(line, with: .color(.orange), lineWidth: 1.2)

    // Multiples of the rotation frequency.
    if model.fundamental > 0 {
      var lastX: CGFloat = -100
      var k = 1
      // Past 24 multiples the lines merge into a block on a logarithmic axis.
      while Double(k) * model.fundamental < maxHz, k <= 24 {
        let hx = x(for: Double(k) * model.fundamental, width: size.width)
        ctx.stroke(
          Path { $0.move(to: CGPoint(x: hx, y: 14)); $0.addLine(to: CGPoint(x: hx, y: floor)) },
          with: .color(.purple.opacity(k == 1 ? 0.9 : 0.45)), lineWidth: k == 1 ? 1.5 : 1)
        if hx - lastX > 16 {
          ctx.draw(
            Text("\(k)×").font(.caption2).foregroundStyle(.purple), at: CGPoint(x: hx, y: 7))
          lastX = hx
        }
        k += 1
      }
    } else {
      // Label the distinct tones.
      for p in model.audioPeaks {
        let px = x(for: p.hz, width: size.width)
        ctx.draw(
          Text(String(format: p.hz < 1000 ? "%.0f" : "%.0f", p.hz)).font(.caption2)
            .fontWeight(.semibold).foregroundStyle(.primary),
          at: CGPoint(x: min(max(16, px), size.width - 16), y: max(8, y(p.amplitude) - 9)))
      }
    }
    ctx.draw(
      Text("■ Audio, full range").font(.caption).foregroundStyle(.orange),
      at: CGPoint(x: size.width - 10, y: floor - 9), anchor: .trailing)
  }
}
