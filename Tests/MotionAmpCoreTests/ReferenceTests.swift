import XCTest

@testable import MotionAmpCore

/// Compares the Swift engine with the arrays that `reference/make_fixtures.py` writes.
final class ReferenceTests: XCTestCase {
  struct Manifest: Decodable {
    let h, w, scales, orients, frames: Int
    let fs, lo, hi, alpha: Double
    let biquad: [Double]
  }

  static let dir = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("reference/fixtures")

  func manifest() throws -> Manifest {
    try JSONDecoder().decode(
      Manifest.self, from: Data(contentsOf: Self.dir.appendingPathComponent("manifest.json")))
  }

  func load(_ name: String) throws -> [Float] {
    let d = try Data(contentsOf: Self.dir.appendingPathComponent("\(name).bin"))
    return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
  }

  func maxError(_ a: [Float], _ b: [Float]) -> Float {
    XCTAssertEqual(a.count, b.count)
    return zip(a, b).map { abs($0 - $1) }.max() ?? 0
  }

  func testFiltersMatchReference() throws {
    let m = try manifest()
    let f = PyramidFilters(height: m.h, width: m.w, scales: m.scales, orients: m.orients)
    XCTAssertLessThan(maxError(f.residual, try load("residual")), 1e-6)
    for k in 1...m.scales {
      XCTAssertLessThan(maxError(f.bands[k - 1], try load("filter\(k)")), 1e-6)
    }
  }

  func testBiquadMatchesReference() throws {
    let m = try manifest()
    let b = Biquad(lo: m.lo, hi: m.hi, fs: m.fs)
    for (x, y) in zip([b.b0, b.b1, b.b2, b.a1, b.a2], m.biquad) {
      XCTAssertEqual(x, y, accuracy: 1e-12)
    }
  }

  func testCoefficientsMatchReference() throws {
    let m = try manifest()
    let mag = try Magnifier(
      width: m.w, height: m.h, fps: m.fs, lo: m.lo, hi: m.hi, alpha: m.alpha,
      scales: m.scales, orients: m.orients)
    let coefs = mag.coefficients(try load("image"))
    for k in 1...m.scales {
      let re = try load("coef\(k)_re")
      let scale = re.map { abs($0) }.max()!
      XCTAssertLessThan(maxError(coefs[k - 1].re, re) / scale, 1e-4)
      XCTAssertLessThan(maxError(coefs[k - 1].im, try load("coef\(k)_im")) / scale, 1e-4)
    }
  }

  func testMagnifiedVideoMatchesReference() throws {
    let m = try manifest()
    let video = try load("video")
    let expected = try load("magnified")
    let mag = try Magnifier(
      width: m.w, height: m.h, fps: m.fs, lo: m.lo, hi: m.hi, alpha: m.alpha,
      scales: m.scales, orients: m.orients)
    let n = m.h * m.w
    var out = [Float](repeating: 0, count: n)
    var worst: Float = 0
    for i in 0..<m.frames {
      video.withUnsafeBufferPointer {
        mag.process(UnsafeBufferPointer(rebasing: $0[i * n..<(i + 1) * n]), into: &out)
      }
      worst = max(worst, maxError(out, Array(expected[i * n..<(i + 1) * n])))
    }
    // Pixel values span [0, 1]. One 10-bit code is about 1e-3.
    XCTAssertLessThan(worst, 1e-3)
  }

  func testDisplacementMatchesReference() throws {
    try checkDisplacement(levels: [2], pool: 1, expected: "disp_x", components: 1)
  }

  func testPooledDisplacementMatchesReference() throws {
    try checkDisplacement(levels: [1, 2, 3], pool: 2, expected: "pooled_disp", components: 2)
  }

  /// - Parameter components: The number of displacement components that the fixture holds.
  func checkDisplacement(levels: [Int], pool: Int, expected name: String, components: Int)
    throws
  {
    let m = try manifest()
    let video = try load("video")
    let expected = try load(name)
    let an = try MotionAnalyzer(
      width: m.w, height: m.h, levels: levels, pool: pool, orients: m.orients)
    let n = m.h * m.w
    let cells = an.gridWidth * an.gridHeight
    XCTAssertEqual(expected.count, m.frames * components * cells)
    var d = [Float](repeating: 0, count: 2 * cells)
    var w = d
    var worst: Float = 0
    for i in 0..<m.frames {
      video.withUnsafeBufferPointer {
        an.process(
          UnsafeBufferPointer(rebasing: $0[i * n..<(i + 1) * n]), displacement: &d, weight: &w)
      }
      // Compare where the coefficient amplitude is large enough for a stable phase.
      let count = components * cells
      let floor = w[0..<count].max()! * 1e-3
      for j in 0..<count where w[j] > floor {
        worst = max(worst, abs(d[j] - expected[i * count + j]))
      }
    }
    XCTAssertLessThan(worst, 2e-3)
  }

  /// Checks that a zero gain returns the input at a size that isn't a power of two.
  func testIdentityAtAwkwardSize() throws {
    let (w, h) = (962, 538)
    var rng = SystemRandomNumberGenerator()
    let y = (0..<w * h).map { _ in Float.random(in: 0...1, using: &rng) }
    let mag = try Magnifier(width: w, height: h, fps: 240, lo: 10, hi: 20, alpha: 0)
    var out = [Float](repeating: 0, count: w * h)
    for _ in 0..<2 {
      y.withUnsafeBufferPointer { mag.process($0, into: &out) }
    }
    XCTAssertLessThan(maxError(out, y), 1e-3)
  }
}
