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
  /// The 99th-percentile amplitude over the confident cells, per bin.
  ///
  /// A high percentile keeps a vibration visible when it covers a small part of the frame.
  public let globalSpectrum: [Float]
  /// The median amplitude over all bins of the confident cells, in source pixels.
  public let noiseFloor: Float
  /// The camera's x displacement from the first frame, per frame, in source pixels.
  ///
  /// Empty if the analysis didn't remove camera motion.
  public let cameraX: [Float]
  /// The camera's y displacement from the first frame, per frame, in source pixels.
  public let cameraY: [Float]

  public var nyquist: Double { fps / 2 }

  /// Gets a copy that reinterprets the frames at a different capture rate.
  ///
  /// Use this method for high-speed footage that is stored at a slower
  /// playback rate, where the file's timestamps don't give the capture rate.
  public func rescaled(fps newFps: Double) -> MotionAnalysis {
    MotionAnalysis(
      gridWidth: gridWidth, gridHeight: gridHeight, frames: frames, fps: newFps,
      binHz: binHz * newFps / fps, bins: bins, amplitude: amplitude, confidence: confidence,
      globalSpectrum: globalSpectrum, noiseFloor: noiseFloor, cameraX: cameraX,
      cameraY: cameraY)
  }

  func binRange(lo: Double, hi: Double) -> ClosedRange<Int> {
    let a = max(1, min(bins - 1, Int((lo / binHz).rounded(.up))))
    let b = max(a, min(bins - 1, Int((hi / binHz).rounded(.down))))
    return a...b
  }

  /// Gets how far each cell's in-band peak rises over that cell's own noise.
  ///
  /// For each cell, takes the largest amplitude in the band and subtracts
  /// three times the median amplitude of the bins that flank the band. A cell
  /// with broadband noise and no peak in the band therefore scores 0. The
  /// result is scaled by the cell's confidence.
  ///
  /// - Returns: `gridWidth * gridHeight` values in source pixels, row-major.
  public func heat(lo: Double, hi: Double) -> [Float] {
    let r = binRange(lo: lo, hi: hi)
    let flank = max(8, r.count)
    let below = max(1, r.lowerBound - flank)..<r.lowerBound
    let above = min(bins, r.upperBound + 1)..<min(bins, r.upperBound + 1 + flank)
    var out = [Float](repeating: 0, count: gridWidth * gridHeight)
    amplitude.withUnsafeBufferPointer { a in
      out.withUnsafeMutableBufferPointer { o in
        let (ap, op) = (a.baseAddress!, o.baseAddress!)
        DispatchQueue.concurrentPerform(iterations: gridHeight) { gy in
          var side = [Float]()
          side.reserveCapacity(2 * flank)
          for c in gy * gridWidth..<(gy + 1) * gridWidth where confidence[c] > 0 {
            var peak: Float = 0
            vDSP_maxv(ap + c * bins + r.lowerBound, 1, &peak, vDSP_Length(r.count))
            side.removeAll(keepingCapacity: true)
            for i in below { side.append(ap[c * bins + i]) }
            for i in above { side.append(ap[c * bins + i]) }
            side.sort()
            let base = side.isEmpty ? 0 : side[side.count / 2]
            op[c] = max(0, peak - 3 * base) * confidence[c]
          }
        }
      }
    }
    return out
  }

  /// Gets the median, over confident cells, of each cell's largest amplitude in a band.
  ///
  /// This value describes how much a typical part of the frame moves in the
  /// band. Camera motion raises it, because camera motion moves every cell.
  public func typicalAmplitude(lo: Double, hi: Double) -> Float {
    let r = binRange(lo: lo, hi: hi)
    var peaks: [Float] = []
    for c in 0..<gridWidth * gridHeight where confidence[c] > 0.5 {
      peaks.append(amplitude[c * bins + r.lowerBound...c * bins + r.upperBound].max() ?? 0)
    }
    peaks.sort()
    return peaks.isEmpty ? 0 : peaks[peaks.count / 2]
  }

  /// Gets the amplitude spectrum of one cell.
  public func spectrum(cellX: Int, cellY: Int) -> [Float] {
    let c = cellY * gridWidth + cellX
    return Array(amplitude[c * bins..<(c + 1) * bins])
  }

  /// Gets the peaks of the global spectrum that stand clear of the noise around them.
  ///
  /// A bin qualifies if it is the largest within three bins on each side and
  /// its amplitude is at least `ratio` times the median of the surrounding bins.
  ///
  /// - Returns: Up to `count` pairs of frequency in Hz and amplitude, most distinct first.
  public func distinctPeaks(count: Int, ratio: Float = 1.3, minHz: Double = 0.3)
    -> [(hz: Double, amplitude: Float)]
  {
    let s = globalSpectrum
    // The window reaches three bins to each side, so start at bin 3 or later.
    let first = max(3, Int((minHz / binHz).rounded(.up)))
    let span = max(8, bins / 40)
    guard first + 4 < bins else { return [] }
    var found: [(Double, Float, Float)] = []
    for i in first..<bins - 3 {
      guard s[i] == s[i - 3...i + 3].max() else { continue }
      let around = (Array(s[max(1, i - span)..<i - 2]) + Array(s[i + 3..<min(bins, i + span + 1)]))
        .sorted()
      guard !around.isEmpty else { continue }
      let base = max(1e-12, around[around.count / 2])
      if s[i] / base >= ratio { found.append((Double(i) * binHz, s[i], s[i] / base)) }
    }
    return found.sorted { $0.2 > $1.2 }.prefix(count).map { (hz: $0.0, amplitude: $0.1) }
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

/// Gets the median of the values whose weight is at least a quarter of the mean weight.
///
/// - Parameter scratch: Reused storage for the sort.
func texturedMedian(
  _ values: [Float], _ weights: [Float], _ range: Range<Int>, _ scratch: inout [Float]
) -> Float {
  var mean: Float = 0
  for i in range { mean += weights[i] }
  let floor = 0.25 * mean / Float(range.count)
  scratch.removeAll(keepingCapacity: true)
  for i in range where weights[i] >= floor { scratch.append(values[i]) }
  guard !scratch.isEmpty else { return 0 }
  scratch.sort()
  return scratch[scratch.count / 2]
}

/// Fits a plane to one displacement component over the grid and subtracts it in place.
///
/// A camera that rolls or zooms moves each cell by an amount that varies
/// linearly across the frame. The exact frequency-domain shift cancels only
/// the part that all cells share, so this fit removes the linear remainder
/// from the measurement. It fits textured cells only, and it fits twice: the
/// second pass ignores cells that sit far from the first plane, so a part
/// that moves on its own doesn't tilt the fit.
func subtractPlane(
  _ values: inout [Float], _ weights: [Float], offset: Int, gridWidth gw: Int, gridHeight gh: Int
) {
  let cells = gw * gh
  var mean: Float = 0
  for i in 0..<cells { mean += weights[offset + i] }
  let floor = 0.25 * mean / Float(cells)
  var limit = Float.greatestFiniteMagnitude
  var plane: (Double, Double, Double) = (0, 0, 0)
  var residuals: [Float] = []
  for pass in 0..<2 {
    // Normal equations for v = p0 + p1 * x + p2 * y, with x and y in [-0.5, 0.5].
    var m = [Double](repeating: 0, count: 9)
    var rhs = [Double](repeating: 0, count: 3)
    var used = 0
    for gy in 0..<gh {
      let y = Double(gy) / Double(gh) - 0.5
      for gx in 0..<gw {
        let i = offset + gy * gw + gx
        guard weights[i] >= floor else { continue }
        let x = Double(gx) / Double(gw) - 0.5
        let v = Double(values[i])
        if pass == 1, abs(Float(v - (plane.0 + plane.1 * x + plane.2 * y))) > limit { continue }
        let row = [1, x, y]
        for a in 0..<3 {
          rhs[a] += row[a] * v
          for b in 0..<3 { m[a * 3 + b] += row[a] * row[b] }
        }
        used += 1
      }
    }
    guard used >= 16 else { return }
    let det =
      m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6])
      + m[2] * (m[3] * m[7] - m[4] * m[6])
    guard abs(det) > 1e-12 else { return }
    // Cramer's rule.
    func solve(_ col: Int) -> Double {
      var c = m
      for r in 0..<3 { c[r * 3 + col] = rhs[r] }
      return
        (c[0] * (c[4] * c[8] - c[5] * c[7]) - c[1] * (c[3] * c[8] - c[5] * c[6])
        + c[2] * (c[3] * c[7] - c[4] * c[6])) / det
    }
    plane = (solve(0), solve(1), solve(2))
    if pass == 0 {
      residuals.removeAll(keepingCapacity: true)
      for gy in 0..<gh {
        let y = Double(gy) / Double(gh) - 0.5
        for gx in 0..<gw {
          let i = offset + gy * gw + gx
          guard weights[i] >= floor else { continue }
          let x = Double(gx) / Double(gw) - 0.5
          residuals.append(abs(values[i] - Float(plane.0 + plane.1 * x + plane.2 * y)))
        }
      }
      residuals.sort()
      // Three times the median absolute residual.
      limit = 3 * residuals[residuals.count / 2] + 1e-6
    }
  }
  for gy in 0..<gh {
    let y = Double(gy) / Double(gh) - 0.5
    for gx in 0..<gw {
      let x = Double(gx) / Double(gw) - 0.5
      values[offset + gy * gw + gx] -= Float(plane.0 + plane.1 * x + plane.2 * y)
    }
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
///   - levels: The 1-based pyramid levels to combine.
///   - targetGridWidth: The approximate number of grid cells along the frame width.
///   - confidenceFloor: The fraction of the 90th-percentile texture energy
///     under which a cell's confidence is 0.
///   - removeCameraMotion: If true, estimates the whole-frame shift of each
///     frame and cancels it before measuring. The shift is the median
///     displacement over textured cells, so it follows whatever fills most of
///     the frame. Motion that the whole scene shares is removed with it.
///     The measurement also drops the part that varies linearly across the
///     frame, which a rolling or zooming camera produces.
///   - progress: Called with a fraction from 0 to 1.
public func analyzeMotion(
  url: URL, maxDimension: Int = 1280, levels: [Int] = [1, 2, 3], targetGridWidth: Int = 160,
  confidenceFloor: Float = 0.01, removeCameraMotion: Bool = true,
  progress: @Sendable (Double) -> Void = { _ in }
) async throws -> MotionAnalysis {
  let info = try await VideoInfo.load(url)
  let reader = try await FrameReader(url: url, maxDimension: maxDimension)
  let (w, h) = (reader.width, reader.height)
  let coarse = PyramidFilters.levelSize(w, levels.max()!)
  let pool = max(1, Int((Double(coarse) / Double(targetGridWidth)).rounded()))
  let analyzer = try MotionAnalyzer(width: w, height: h, levels: levels, pool: pool)
  let (gw, gh) = (analyzer.gridWidth, analyzer.gridHeight)
  let cells = gw * gh
  let toSource = Float(info.width) / Float(w)

  var y = [Float](repeating: 0, count: w * h)
  var disp = [Float](repeating: 0, count: 2 * cells)
  var wt = disp
  var series: [[Float]] = []  // Per frame: x cells then y cells.
  var camera: (x: Float, y: Float) = (0, 0)  // In pixels of the analysis frame.
  var cameraX: [Float] = []
  var cameraY: [Float] = []
  var scratch: [Float] = []
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
    // Measure, take the median displacement as the camera's residual shift,
    // fold it into the running estimate, and measure again. The frequency-
    // domain shift is exact, so each pass removes most of what remains even
    // though the displacement scale is approximate. The estimate carries over
    // to the next frame, which keeps the residual far from a phase wrap.
    var residual: (x: Float, y: Float) = (0, 0)
    for _ in 0..<(removeCameraMotion ? 3 : 1) {
      y.withUnsafeBufferPointer {
        analyzer.process($0, shift: camera, displacement: &disp, weight: &wt)
      }
      guard removeCameraMotion else { break }
      residual = (
        texturedMedian(disp, wt, 0..<cells, &scratch),
        texturedMedian(disp, wt, cells..<2 * cells, &scratch)
      )
      camera.x += residual.x
      camera.y += residual.y
    }
    if removeCameraMotion {
      cameraX.append(camera.x * toSource)
      cameraY.append(camera.y * toSource)
    }

    if removeCameraMotion {
      // Remove what the last pass left, plus the roll and zoom remainder.
      subtractPlane(&disp, wt, offset: 0, gridWidth: gw, gridHeight: gh)
      subtractPlane(&disp, wt, offset: cells, gridWidth: gw, gridHeight: gh)
    }
    var frame = [Float](repeating: 0, count: 2 * cells)
    for i in 0..<2 * cells {
      frame[i] = toSource * disp[i]
      energy[i % cells] += wt[i]
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
  let confident = (0..<cells).filter { confidence[$0] > 0.5 }
  if !confident.isEmpty {
    global.withUnsafeMutableBufferPointer { g in
      let gp = g.baseAddress!
      amplitude.withUnsafeBufferPointer { amp in
        let ap = amp.baseAddress!
        DispatchQueue.concurrentPerform(iterations: bins) { i in
          var column = confident.map { ap[$0 * bins + i] }
          column.sort()
          gp[i] = column[min(column.count - 1, column.count * 99 / 100)]
        }
      }
    }
  }
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
    bins: bins, amplitude: amplitude, confidence: confidence, globalSpectrum: global, noiseFloor: noiseFloor,
    cameraX: cameraX, cameraY: cameraY)
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
