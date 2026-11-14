import Foundation

/// Holds the frequency-domain filters of a complex steerable pyramid.
///
/// Mirrors `build_filters` in the `reference/steerable.py` file. All arrays
/// use the unshifted FFT layout, where index 0 is the zero frequency.
public struct PyramidFilters {
  public let height: Int
  public let width: Int
  public let scales: Int
  public let orients: Int
  /// The cropped spectrum height of each level.
  public let levelHeights: [Int]
  /// The cropped spectrum width of each level.
  public let levelWidths: [Int]
  /// The filters of each level, in row-major [orients, levelHeight, levelWidth] order.
  public let bands: [[Float]]
  /// The sum of the squared high-pass and low-pass residual filters, in [height, width] order.
  public let residual: [Float]

  /// Gets the cropped spectrum size of level `k` (1-based) along an axis of `n` samples.
  public static func levelSize(_ n: Int, _ k: Int) -> Int {
    min(n, 2 * Int((Double(n) / pow(2, Double(k))).rounded(.up)))
  }

  /// Gets the unshifted-layout indices of the `nc` lowest frequencies of `n`.
  public static func cropIndex(_ n: Int, _ nc: Int) -> [Int] {
    Array(0..<nc / 2) + Array(n - nc / 2..<n)
  }

  /// Gets the default number of scales for a frame size.
  ///
  /// The coarsest level keeps a spectrum of at least 16 samples on the short axis.
  public static func defaultScales(height: Int, width: Int) -> Int {
    max(1, Int(log2(Double(min(height, width)))) - 3)
  }

  /// Creates the filters.
  ///
  /// - Parameters:
  ///   - height: The frame height. Must be even.
  ///   - width: The frame width. Must be even.
  ///   - scales: The number of pyramid levels.
  ///   - orients: The number of orientations per level. Must be at least 2.
  public init(height: Int, width: Int, scales: Int, orients: Int) {
    precondition(height % 2 == 0 && width % 2 == 0, "Frame dimensions must be even.")
    precondition(orients >= 2 && scales >= 1)
    self.height = height
    self.width = width
    self.scales = scales
    self.orients = orients

    func freq(_ i: Int, _ n: Int) -> Double {
      2.0 * Double(i < n / 2 ? i : i - n) / Double(n)
    }
    // hi is 0 at or under r/2, 1 at or over r, with a cosine ramp between.
    func hiPass(_ rad: Double, _ r: Double) -> Double {
      let t = min(0, max(-1, log2(rad / r)))
      return cos(t * .pi / 2)
    }
    func loPass(_ rad: Double, _ r: Double) -> Double {
      let hi = hiPass(rad, r)
      return (max(0, 1 - hi * hi)).squareRoot()
    }
    func factorial(_ n: Int) -> Double { n < 2 ? 1 : (2...n).reduce(1.0) { $0 * Double($1) } }

    let order = orients - 1
    let const = pow(2, Double(2 * order)) * pow(factorial(order), 2)
      / (Double(orients) * factorial(2 * order))
    let gain = (2 * const).squareRoot()

    var residual = [Float](repeating: 0, count: height * width)
    let lowCut = pow(2.0, -Double(scales))
    for r in 0..<height {
      let fy = freq(r, height)
      for c in 0..<width {
        let fx = freq(c, width)
        let rad = (r == 0 && c == 0) ? 1e-9 : (fx * fx + fy * fy).squareRoot()
        let hi = hiPass(rad, 1)
        let lo = loPass(rad, lowCut)
        residual[r * width + c] = Float(hi * hi + lo * lo)
      }
    }
    self.residual = residual

    var bands: [[Float]] = []
    var heights: [Int] = []
    var widths: [Int] = []
    for k in 1...scales {
      let hk = Self.levelSize(height, k)
      let wk = Self.levelSize(width, k)
      let rows = Self.cropIndex(height, hk)
      let cols = Self.cropIndex(width, wk)
      let rk = pow(2.0, -Double(k))
      var f = [Float](repeating: 0, count: orients * hk * wk)
      for (ri, r) in rows.enumerated() {
        let fy = freq(r, height)
        for (ci, c) in cols.enumerated() {
          let fx = freq(c, width)
          let rad = (r == 0 && c == 0) ? 1e-9 : (fx * fx + fy * fy).squareRoot()
          let radial = hiPass(rad, rk) * loPass(rad, 2 * rk)
          if radial == 0 { continue }
          let angle = atan2(fy, fx)
          for b in 0..<orients {
            var a = (.pi + angle - .pi * Double(b) / Double(orients))
              .truncatingRemainder(dividingBy: 2 * .pi)
            if a < 0 { a += 2 * .pi }
            a -= .pi
            // One-sided filter: only the half plane that faces orientation b.
            if abs(a) < .pi / 2 {
              f[(b * hk + ri) * wk + ci] = Float(radial * gain * pow(cos(a), Double(order)))
            }
          }
        }
      }
      bands.append(f)
      heights.append(hk)
      widths.append(wk)
    }
    self.bands = bands
    self.levelHeights = heights
    self.levelWidths = widths
  }
}

/// Holds one band-pass biquad section, normalized so that a0 is 1.
public struct Biquad {
  public let b0, b1, b2, a1, a2: Double

  /// Creates a band-pass section with 0 dB peak gain.
  ///
  /// Uses the Audio EQ Cookbook constant-peak-gain band-pass form. Mirrors
  /// `bandpass_biquad` in the `reference/steerable.py` file.
  ///
  /// - Parameters:
  ///   - lo: The lower band edge in Hz. Must be greater than 0.
  ///   - hi: The upper band edge in Hz. Must be greater than `lo` and less than `fs / 2`.
  ///   - fs: The sample rate in Hz.
  public init(lo: Double, hi: Double, fs: Double) {
    let f0 = (lo * hi).squareRoot()
    let w0 = 2 * Double.pi * f0 / fs
    let alpha = sin(w0) * (hi - lo) / (2 * f0)
    let a0 = 1 + alpha
    b0 = alpha / a0
    b1 = 0
    b2 = -alpha / a0
    a1 = -2 * cos(w0) / a0
    a2 = (1 - alpha) / a0
  }
}
