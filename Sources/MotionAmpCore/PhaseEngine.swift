import Foundation
import Metal
import MetalPerformanceShadersGraph

public enum EngineError: Error, CustomStringConvertible {
  case noMetalDevice
  case message(String)

  public var description: String {
    switch self {
    case .noMetalDevice: return "No Metal device is available."
    case .message(let m): return m
    }
  }
}

/// Wraps an `MPSGraph` object with the tensor helpers that the pyramid needs.
///
/// Complex values exist only at the FFT boundaries. Everywhere else the graph
/// carries separate real and imaginary float32 tensors.
final class GraphContext {
  typealias T = MPSGraphTensor
  let g = MPSGraph()
  let queue: MTLCommandQueue
  let device: MPSGraphDevice

  init() throws {
    guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else {
      throw EngineError.noMetalDevice
    }
    queue = q
    device = MPSGraphDevice(mtlDevice: d)
  }

  static func ns(_ shape: [Int]) -> [NSNumber] { shape.map { NSNumber(value: $0) } }

  func const(_ v: [Float], _ shape: [Int]) -> T {
    v.withUnsafeBufferPointer {
      g.constant(Data(buffer: $0), shape: Self.ns(shape), dataType: .float32)
    }
  }

  func scalar(_ v: Double) -> T { g.constant(v, dataType: .float32) }

  func placeholder(_ shape: [Int]) -> T {
    g.placeholder(shape: Self.ns(shape), dataType: .float32, name: nil)
  }

  func fft(_ re: T, _ im: T, axes: [Int], inverse: Bool) -> (T, T) {
    let d = MPSGraphFFTDescriptor()
    d.inverse = inverse
    d.scalingMode = inverse ? .size : .none
    let c = g.complexTensor(realTensor: re, imaginaryTensor: im, name: nil)
    let o = g.fastFourierTransform(c, axes: Self.ns(axes), descriptor: d, name: nil)
    return (g.realPartOfTensor(tensor: o, name: nil), g.imaginaryPartOfTensor(tensor: o, name: nil))
  }

  /// Keeps the `nc` lowest frequencies of an unshifted spectrum along `dim`.
  func crop(_ t: T, dim: Int, n: Int, nc: Int) -> T {
    if nc == n { return t }
    let a = g.sliceTensor(t, dimension: dim, start: 0, length: nc / 2, name: nil)
    let b = g.sliceTensor(t, dimension: dim, start: n - nc / 2, length: nc / 2, name: nil)
    return g.concatTensors([a, b], dimension: dim, name: nil)
  }

  /// Zero-pads a cropped [hc, wc] spectrum back to [h, w].
  func uncrop(_ t: T, hc: Int, wc: Int, h: Int, w: Int) -> T {
    var out = t
    if hc < h {
      let a = g.sliceTensor(out, dimension: 0, start: 0, length: hc / 2, name: nil)
      let b = g.sliceTensor(out, dimension: 0, start: hc / 2, length: hc / 2, name: nil)
      let z = g.constant(0, shape: Self.ns([h - hc, wc]), dataType: .float32)
      out = g.concatTensors([a, z, b], dimension: 0, name: nil)
    }
    if wc < w {
      let a = g.sliceTensor(out, dimension: 1, start: 0, length: wc / 2, name: nil)
      let b = g.sliceTensor(out, dimension: 1, start: wc / 2, length: wc / 2, name: nil)
      let z = g.constant(0, shape: Self.ns([h, w - wc]), dataType: .float32)
      out = g.concatTensors([a, z, b], dimension: 1, name: nil)
    }
    return out
  }

  func mul(_ a: T, _ b: T) -> T { g.multiplication(a, b, name: nil) }
  func add(_ a: T, _ b: T) -> T { g.addition(a, b, name: nil) }
  func sub(_ a: T, _ b: T) -> T { g.subtraction(a, b, name: nil) }

  func data(_ v: UnsafeBufferPointer<Float>, _ shape: [Int]) -> MPSGraphTensorData {
    MPSGraphTensorData(device: device, data: Data(buffer: v), shape: Self.ns(shape), dataType: .float32)
  }

  func zeros(_ shape: [Int]) -> MPSGraphTensorData {
    let n = shape.reduce(1, *)
    return MPSGraphTensorData(
      device: device, data: Data(count: n * MemoryLayout<Float>.size), shape: Self.ns(shape),
      dataType: .float32)
  }

  func read(_ d: MPSGraphTensorData, into out: inout [Float]) {
    out.withUnsafeMutableBytes { d.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
  }

  func run(_ feeds: [T: MPSGraphTensorData], _ targets: [T]) -> [T: MPSGraphTensorData] {
    g.run(with: queue, feeds: feeds, targetTensors: targets, targetOperations: nil)
  }
}

/// Magnifies motion in a temporal frequency band, one luma frame at a time.
///
/// Mirrors `magnify` in the `reference/steerable.py` file. The object keeps
/// the reference-frame coefficients and the temporal filter state on the GPU
/// between calls, so frames must arrive in presentation order.
public final class Magnifier {
  public let width: Int
  public let height: Int
  public let filters: PyramidFilters

  private let ctx: GraphContext
  private let yIn: MPSGraphTensor
  private var refIn: [MPSGraphTensor] = []  // re then im, per level
  private var coefOut: [MPSGraphTensor] = []  // re then im, per level
  private var stateIn: [MPSGraphTensor] = []
  private var stateOut: [MPSGraphTensor] = []
  private let yOut: MPSGraphTensor
  private var refData: [MPSGraphTensorData]?
  private var stateData: [MPSGraphTensorData] = []

  /// Creates a magnifier.
  ///
  /// - Parameters:
  ///   - width: The frame width. Must be even.
  ///   - height: The frame height. Must be even.
  ///   - fps: The capture frame rate in Hz.
  ///   - lo: The lower edge of the temporal band in Hz.
  ///   - hi: The upper edge of the temporal band in Hz. Must be less than `fps / 2`.
  ///   - alpha: The phase gain. Motion in the band is scaled by about `1 + alpha`.
  ///   - scales: The number of pyramid levels. Default: `PyramidFilters.defaultScales`.
  ///   - orients: The number of orientations per level.
  ///   - sections: The number of cascaded biquad sections in the temporal filter.
  public init(
    width: Int, height: Int, fps: Double, lo: Double, hi: Double, alpha: Double,
    scales: Int? = nil, orients: Int = 4, sections: Int = 2
  ) throws {
    guard lo > 0, hi > lo, hi < fps / 2 else {
      throw EngineError.message("The band must satisfy 0 < lo < hi < fps / 2.")
    }
    self.width = width
    self.height = height
    let s = scales ?? PyramidFilters.defaultScales(height: height, width: width)
    filters = PyramidFilters(height: height, width: width, scales: s, orients: orients)
    ctx = try GraphContext()
    let c = ctx
    let bq = Biquad(lo: lo, hi: hi, fs: fps)
    let (b0, b1, b2, a1, a2) = (
      c.scalar(bq.b0), c.scalar(bq.b1), c.scalar(bq.b2), c.scalar(bq.a1), c.scalar(bq.a2)
    )
    let gain = c.scalar(alpha)

    yIn = c.placeholder([height, width])
    let zero = c.g.constant(0, shape: GraphContext.ns([height, width]), dataType: .float32)
    let (xRe, xIm) = c.fft(yIn, zero, axes: [0, 1], inverse: false)
    let res = c.const(filters.residual, [height, width])
    var accRe = c.mul(xRe, res)
    var accIm = c.mul(xIm, res)

    for k in 0..<s {
      let hk = filters.levelHeights[k]
      let wk = filters.levelWidths[k]
      let shape = [orients, hk, wk]
      let f = c.const(filters.bands[k], shape)
      let cropRe = c.crop(c.crop(xRe, dim: 0, n: height, nc: hk), dim: 1, n: width, nc: wk)
      let cropIm = c.crop(c.crop(xIm, dim: 0, n: height, nc: hk), dim: 1, n: width, nc: wk)
      let (cRe, cIm) = c.fft(c.mul(cropRe, f), c.mul(cropIm, f), axes: [1, 2], inverse: true)
      coefOut += [cRe, cIm]

      let rRe = c.placeholder(shape)
      let rIm = c.placeholder(shape)
      refIn += [rRe, rIm]
      // Phase of coef * conj(ref).
      let pRe = c.add(c.mul(cRe, rRe), c.mul(cIm, rIm))
      let pIm = c.sub(c.mul(cIm, rRe), c.mul(cRe, rIm))
      var v = c.g.atan2(withPrimaryTensor: pIm, secondaryTensor: pRe, name: nil)

      // Biquad cascade in transposed direct form II.
      for _ in 0..<sections {
        let z1 = c.placeholder(shape)
        let z2 = c.placeholder(shape)
        let y = c.add(c.mul(b0, v), z1)
        let z1n = c.add(c.sub(c.mul(b1, v), c.mul(a1, y)), z2)
        let z2n = c.sub(c.mul(b2, v), c.mul(a2, y))
        stateIn += [z1, z2]
        stateOut += [z1n, z2n]
        stateData += [c.zeros(shape), c.zeros(shape)]
        v = y
      }

      let phi = c.mul(gain, v)
      let cs = c.g.cos(with: phi, name: nil)
      let sn = c.g.sin(with: phi, name: nil)
      let nRe = c.sub(c.mul(cRe, cs), c.mul(cIm, sn))
      let nIm = c.add(c.mul(cRe, sn), c.mul(cIm, cs))
      let (dRe, dIm) = c.fft(nRe, nIm, axes: [1, 2], inverse: false)
      let hw = GraphContext.ns([hk, wk])
      let sRe = c.g.reshape(
        c.g.reductionSum(with: c.mul(dRe, f), axis: 0, name: nil), shape: hw, name: nil)
      let sIm = c.g.reshape(
        c.g.reductionSum(with: c.mul(dIm, f), axis: 0, name: nil), shape: hw, name: nil)
      accRe = c.add(accRe, c.uncrop(sRe, hc: hk, wc: wk, h: height, w: width))
      accIm = c.add(accIm, c.uncrop(sIm, hc: hk, wc: wk, h: height, w: width))
    }
    yOut = c.fft(accRe, accIm, axes: [0, 1], inverse: true).0
  }

  /// Gets the pyramid coefficients of a frame without changing the filter state.
  ///
  /// - Parameter y: The luma frame in row-major order, `width * height` values.
  /// - Returns: For each level, the real and imaginary parts in [orients, levelHeight, levelWidth] order.
  public func coefficients(_ y: [Float]) -> [(re: [Float], im: [Float])] {
    autoreleasepool {
      let yd = y.withUnsafeBufferPointer { ctx.data($0, [height, width]) }
      let r = ctx.run([yIn: yd], coefOut)
      return (0..<filters.scales).map { k in
        let n = filters.orients * filters.levelHeights[k] * filters.levelWidths[k]
        var re = [Float](repeating: 0, count: n)
        var im = re
        ctx.read(r[coefOut[2 * k]]!, into: &re)
        ctx.read(r[coefOut[2 * k + 1]]!, into: &im)
        return (re, im)
      }
    }
  }

  /// Magnifies the next frame.
  ///
  /// The first frame that this method receives becomes the phase reference.
  ///
  /// - Parameters:
  ///   - y: The luma frame in row-major order, `width * height` values.
  ///   - out: The magnified luma frame. Must hold `width * height` values.
  public func process(_ y: UnsafeBufferPointer<Float>, into out: inout [Float]) {
    autoreleasepool {
      let yd = ctx.data(y, [height, width])
      if refData == nil {
        let r = ctx.run([yIn: yd], coefOut)
        refData = coefOut.map { r[$0]! }
      }
      var feeds: [MPSGraphTensor: MPSGraphTensorData] = [yIn: yd]
      for (t, d) in zip(refIn, refData!) { feeds[t] = d }
      for (t, d) in zip(stateIn, stateData) { feeds[t] = d }
      let r = ctx.run(feeds, [yOut] + stateOut)
      stateData = stateOut.map { r[$0]! }
      ctx.read(r[yOut]!, into: &out)
    }
  }
}

/// Measures per-pixel displacement from the first frame at one pyramid level.
///
/// Mirrors `displacement` in the `reference/steerable.py` file.
public final class MotionAnalyzer {
  public let width: Int
  public let height: Int
  public let level: Int
  /// The height of the displacement maps.
  public let mapHeight: Int
  /// The width of the displacement maps.
  public let mapWidth: Int
  /// The level's peak spatial frequency in cycles per pixel.
  public var peakFrequency: Double { 0.5 * pow(2, -Double(level)) }

  private let ctx: GraphContext
  private let yIn: MPSGraphTensor
  private let refRe: MPSGraphTensor
  private let refIm: MPSGraphTensor
  private let cRe: MPSGraphTensor
  private let cIm: MPSGraphTensor
  private let disp: MPSGraphTensor
  private let weight: MPSGraphTensor
  private var refData: (MPSGraphTensorData, MPSGraphTensorData)?

  /// Creates an analyzer.
  ///
  /// - Parameters:
  ///   - width: The frame width. Must be even.
  ///   - height: The frame height. Must be even.
  ///   - level: The 1-based pyramid level to measure.
  ///   - orients: The number of orientations in the pyramid. Must be even.
  public init(width: Int, height: Int, level: Int, orients: Int = 4) throws {
    self.width = width
    self.height = height
    self.level = level
    let filters = PyramidFilters(height: height, width: width, scales: level, orients: orients)
    let hk = filters.levelHeights[level - 1]
    let wk = filters.levelWidths[level - 1]
    mapHeight = hk
    mapWidth = wk
    // Keep orientation 0 (x) and orientation orients / 2 (y).
    let all = filters.bands[level - 1]
    let n = hk * wk
    let two = Array(all[0..<n]) + Array(all[(orients / 2) * n..<(orients / 2 + 1) * n])

    ctx = try GraphContext()
    let c = ctx
    let shape = [2, hk, wk]
    yIn = c.placeholder([height, width])
    let zero = c.g.constant(0, shape: GraphContext.ns([height, width]), dataType: .float32)
    let (xRe, xIm) = c.fft(yIn, zero, axes: [0, 1], inverse: false)
    let f = c.const(two, shape)
    let cropRe = c.crop(c.crop(xRe, dim: 0, n: height, nc: hk), dim: 1, n: width, nc: wk)
    let cropIm = c.crop(c.crop(xIm, dim: 0, n: height, nc: hk), dim: 1, n: width, nc: wk)
    (cRe, cIm) = c.fft(c.mul(cropRe, f), c.mul(cropIm, f), axes: [1, 2], inverse: true)
    refRe = c.placeholder(shape)
    refIm = c.placeholder(shape)
    let pRe = c.add(c.mul(cRe, refRe), c.mul(cIm, refIm))
    let pIm = c.sub(c.mul(cIm, refRe), c.mul(cRe, refIm))
    let delta = c.g.atan2(withPrimaryTensor: pIm, secondaryTensor: pRe, name: nil)
    let peak = 0.5 * pow(2, -Double(level))
    disp = c.mul(delta, c.scalar(-1 / (2 * Double.pi * peak)))
    weight = c.add(c.mul(cRe, cRe), c.mul(cIm, cIm))
  }

  /// Measures the next frame.
  ///
  /// The first frame that this method receives becomes the phase reference.
  ///
  /// - Parameters:
  ///   - y: The luma frame in row-major order, `width * height` values.
  ///   - displacement: The x map then the y map, in pixels of the input frame.
  ///     Must hold `2 * mapHeight * mapWidth` values.
  ///   - weight: The squared coefficient amplitude, in the same layout.
  public func process(
    _ y: UnsafeBufferPointer<Float>, displacement: inout [Float], weight w: inout [Float]
  ) {
    autoreleasepool {
      let yd = ctx.data(y, [height, width])
      if refData == nil {
        let r = ctx.run([yIn: yd], [cRe, cIm])
        refData = (r[cRe]!, r[cIm]!)
      }
      let r = ctx.run([yIn: yd, refRe: refData!.0, refIm: refData!.1], [disp, weight])
      ctx.read(r[disp]!, into: &displacement)
      ctx.read(r[weight]!, into: &w)
    }
  }
}
