import AVFoundation
import Accelerate
import CoreGraphics

/// Computes amplitude spectra of real series with a shared DFT setup.
final class SpectrumPlan {
  let n: Int
  private let setup: vDSP_DFT_Setup

  /// - Parameter n: The transform length. Must be a power of two.
  init(n: Int) {
    self.n = n
    setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
  }

  deinit { vDSP_DFT_DestroySetup(setup) }

  /// Gets the squared magnitude of the first `n / 2` bins.
  ///
  /// - Parameter x: The input series. Must hold `n` values.
  func power(_ x: [Float], into out: inout [Float]) {
    let zero = [Float](repeating: 0, count: n)
    var re = [Float](repeating: 0, count: n)
    var im = re
    vDSP_DFT_Execute(setup, x, zero, &re, &im)
    for i in 0..<n / 2 { out[i] = re[i] * re[i] + im[i] * im[i] }
  }
}

func nextPowerOfTwo(_ n: Int) -> Int {
  var p = 1
  while p < n { p <<= 1 }
  return p
}

/// Holds the vibration spectrum of every cell of a grid laid over the frame.
///
/// The grid uses encoded-frame coordinates, before the display transform.
public struct MotionAnalysis: Sendable {
  public let gridWidth: Int
  public let gridHeight: Int
  public let frames: Int
  /// The frame rate measured from presentation timestamps, in Hz.
  public let fps: Double
  /// The frequency step between spectrum bins, in Hz.
  public let binHz: Double
  public let bins: Int
  /// Displacement amplitude in source pixels, in [cell, bin] order.
  ///
  /// Each value is the amplitude of a sinusoid at that bin, combined over x
  /// and y. The pixel calibration is approximate.
  public let amplitude: [Float]
  /// Per-cell confidence from 0 to 1. Cells with little texture score 0.
  public let confidence: [Float]
  /// The confidence-weighted root mean square amplitude over all cells, per bin.
  public let globalSpectrum: [Float]
  /// The median amplitude over all bins of the confident cells, in source pixels.
  public let noiseFloor: Float

  public var nyquist: Double { fps / 2 }

  func binRange(lo: Double, hi: Double) -> ClosedRange<Int> {
    let a = max(1, min(bins - 1, Int((lo / binHz).rounded(.up))))
    let b = max(a, min(bins - 1, Int((hi / binHz).rounded(.down))))
    return a...b
  }

  /// Gets the peak amplitude of each cell in a band, scaled by the cell's confidence.
  ///
  /// - Returns: `gridWidth * gridHeight` values in source pixels, row-major.
  public func heat(lo: Double, hi: Double) -> [Float] {
    let r = binRange(lo: lo, hi: hi)
    var out = [Float](repeating: 0, count: gridWidth * gridHeight)
    amplitude.withUnsafeBufferPointer { a in
      for c in 0..<out.count where confidence[c] > 0 {
        var m: Float = 0
        vDSP_maxv(a.baseAddress! + c * bins + r.lowerBound, 1, &m, vDSP_Length(r.count))
        out[c] = m * confidence[c]
      }
    }
    return out
  }

  /// Gets the amplitude spectrum of one cell.
  public func spectrum(cellX: Int, cellY: Int) -> [Float] {
    let c = cellY * gridWidth + cellX
    return Array(amplitude[c * bins..<(c + 1) * bins])
  }

  /// Gets the strongest local maxima of the global spectrum.
  ///
  /// - Returns: Up to `count` pairs of frequency in Hz and amplitude, strongest first.
  public func peaks(count: Int, minHz: Double = 1) -> [(hz: Double, amplitude: Float)] {
    let s = globalSpectrum
    let first = max(2, Int(minHz / binHz))
    guard first < bins - 2 else { return [] }
    var found: [(Double, Float)] = []
    for i in first..<bins - 2 where s[i] > s[i - 1] && s[i] >= s[i + 1] {
      found.append((Double(i) * binHz, s[i]))
    }
    return found.sorted { $0.1 > $1.1 }.prefix(count).map { (hz: $0.0, amplitude: $0.1) }
  }
}

/// Measures the vibration spectrum of every grid cell of a video.
///
/// Decodes the whole file once. For each frame, measures displacement from
/// the first frame at one pyramid level, pools it into grid cells, and then
/// takes a Hann-windowed spectrum of each cell's displacement over time.
///
/// - Parameters:
///   - url: The movie file.
///   - maxDimension: The longer side of the frames that the analysis decodes.
///   - level: The 1-based pyramid level to measure.
///   - targetGridWidth: The approximate number of grid cells along the frame width.
///   - confidenceFloor: The fraction of the 90th-percentile texture energy
///     under which a cell's confidence is 0.
///   - progress: Called with a fraction from 0 to 1.
public func analyzeMotion(
  url: URL, maxDimension: Int = 960, level: Int = 2, targetGridWidth: Int = 160,
  confidenceFloor: Float = 0.01, progress: @Sendable (Double) -> Void = { _ in }
) async throws -> MotionAnalysis {
  let info = try await VideoInfo.load(url)
  let reader = try await FrameReader(url: url, maxDimension: maxDimension)
  let (w, h) = (reader.width, reader.height)
  let analyzer = try MotionAnalyzer(width: w, height: h, level: level)
  let (mw, mh) = (analyzer.mapWidth, analyzer.mapHeight)
  let pool = max(1, mw / targetGridWidth)
  let (gw, gh) = (mw / pool, mh / pool)
  let cells = gw * gh
  let toSource = Float(info.width) / Float(w)

  var y = [Float](repeating: 0, count: w * h)
  var disp = [Float](repeating: 0, count: 2 * mw * mh)
  var wt = disp
  var series: [[Float]] = []  // Per frame: x cells then y cells.
  var energy = [Float](repeating: 0, count: cells)
  var firstTime = CMTime.invalid
  var lastTime = CMTime.invalid

  while let sb = reader.next() {
    if Task.isCancelled {
      reader.cancel()
      throw CancellationError()
    }
    let t = CMSampleBufferGetPresentationTimeStamp(sb)
    if !firstTime.isValid { firstTime = t }
    lastTime = t
    readLuma(CMSampleBufferGetImageBuffer(sb)!, into: &y)
    y.withUnsafeBufferPointer { analyzer.process($0, displacement: &disp, weight: &wt) }

    // Pool with the squared amplitude as the weight, because the phase of a
    // weak coefficient is mostly noise.
    var frame = [Float](repeating: 0, count: 2 * cells)
    for comp in 0..<2 {
      let base = comp * mw * mh
      for gy in 0..<gh {
        for gx in 0..<gw {
          var num: Float = 0
          var den: Float = 0
          for py in 0..<pool {
            let row = base + (gy * pool + py) * mw + gx * pool
            for px in 0..<pool {
              num += disp[row + px] * wt[row + px]
              den += wt[row + px]
            }
          }
          frame[comp * cells + gy * gw + gx] = den > 0 ? toSource * num / den : 0
          energy[gy * gw + gx] += den
        }
      }
    }
    series.append(frame)
    if series.count % 16 == 0 { progress(min(0.9, 0.9 * Double(series.count) / Double(info.estimatedFrames))) }
  }

  let frames = series.count
  guard frames >= 8 else { throw EngineError.message("The video has fewer than 8 frames.") }
  let span = (lastTime - firstTime).seconds
  let fps = span > 0 ? Double(frames - 1) / span : info.fps

  // Confidence from texture energy, relative to the 90th percentile.
  let p90 = energy.sorted()[min(cells - 1, cells * 9 / 10)]
  let confidence = energy.map { e -> Float in
    guard p90 > 0 else { return 0 }
    return min(1, max(0, (e / p90 - confidenceFloor) / confidenceFloor))
  }

  let nfft = max(64, nextPowerOfTwo(frames))
  let bins = nfft / 2
  var window = [Float](repeating: 0, count: frames)
  vDSP_hann_window(&window, vDSP_Length(frames), Int32(vDSP_HANN_DENORM))
  let windowSum = window.reduce(0, +)
  let ampScale = 2 / windowSum
  let plan = SpectrumPlan(n: nfft)
  var amplitude = [Float](repeating: 0, count: cells * bins)

  amplitude.withUnsafeMutableBufferPointer { amp in
    let ampPtr = amp.baseAddress!
    DispatchQueue.concurrentPerform(iterations: gh) { gy in
      var x = [Float](repeating: 0, count: nfft)
      var p = [Float](repeating: 0, count: bins)
      var total = [Float](repeating: 0, count: bins)
      for gx in 0..<gw {
        let c = gy * gw + gx
        for i in 0..<bins { total[i] = 0 }
        for comp in 0..<2 {
          var mean: Float = 0
          for t in 0..<frames { mean += series[t][comp * cells + c] }
          mean /= Float(frames)
          for t in 0..<frames { x[t] = (series[t][comp * cells + c] - mean) * window[t] }
          plan.power(x, into: &p)
          for i in 0..<bins { total[i] += p[i] }
        }
        for i in 0..<bins { ampPtr[c * bins + i] = total[i].squareRoot() * ampScale }
      }
    }
  }

  var global = [Float](repeating: 0, count: bins)
  let confSum = max(1e-9, confidence.reduce(0, +))
  for c in 0..<cells where confidence[c] > 0 {
    for i in 0..<bins {
      let a = amplitude[c * bins + i]
      global[i] += confidence[c] * a * a
    }
  }
  global = global.map { ($0 / confSum).squareRoot() }
  // Sample up to about 200,000 amplitudes from confident cells for the median.
  var sample: [Float] = []
  let step = max(1, cells * bins / 200_000)
  for i in stride(from: 0, to: cells * bins, by: step) where confidence[i / bins] > 0.5 {
    sample.append(amplitude[i])
  }
  sample.sort()
  let noiseFloor = sample.isEmpty ? 0 : sample[sample.count / 2]
  progress(1)
  return MotionAnalysis(
    gridWidth: gw, gridHeight: gh, frames: frames, fps: fps, binHz: fps / Double(nfft),
    bins: bins, amplitude: amplitude, confidence: confidence, globalSpectrum: global, noiseFloor: noiseFloor)
}

/// Creates a color overlay image from a grid of values.
///
/// Maps values from blue through green and yellow to red. Opacity rises with
/// the value, so cells near 0 are transparent.
///
/// - Parameters:
///   - values: The grid in row-major order.
///   - maxValue: The value that maps to full red. If nil, uses the grid maximum.
///   - quarterTurns: The number of clockwise quarter turns to apply.
public func heatImage(
  values: [Float], width: Int, height: Int, maxValue: Float? = nil, quarterTurns: Int = 0
) -> CGImage? {
  let top = max(1e-12, maxValue ?? (values.max() ?? 1))
  let turns = ((quarterTurns % 4) + 4) % 4
  let (ow, oh) = turns % 2 == 0 ? (width, height) : (height, width)
  var px = [UInt8](repeating: 0, count: ow * oh * 4)
  for yy in 0..<height {
    for xx in 0..<width {
      let (ox, oy): (Int, Int)
      switch turns {
      case 1: (ox, oy) = (height - 1 - yy, xx)
      case 2: (ox, oy) = (width - 1 - xx, height - 1 - yy)
      case 3: (ox, oy) = (yy, width - 1 - xx)
      default: (ox, oy) = (xx, yy)
      }
      let v = min(1, max(0, values[yy * width + xx] / top))
      let a = min(1, v * 2.5)
      // Piecewise-linear blue, cyan, green, yellow, red ramp.
      let r = min(1, max(0, 4 * v - 2))
      let g = min(1, max(0, v < 0.5 ? 4 * v : 4 - 4 * v))
      let b = min(1, max(0, 2 - 4 * v))
      let i = (oy * ow + ox) * 4
      // Premultiplied alpha.
      px[i] = UInt8(255 * r * a)
      px[i + 1] = UInt8(255 * g * a)
      px[i + 2] = UInt8(255 * b * a)
      px[i + 3] = UInt8(255 * a)
    }
  }
  let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
  guard let provider = CGDataProvider(data: Data(px) as CFData) else { return nil }
  return CGImage(
    width: ow, height: oh, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: ow * 4,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
    shouldInterpolate: true, intent: .defaultIntent)
}
