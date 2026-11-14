import AVFoundation
import Accelerate
import CoreGraphics

/// Describes the video track of a movie file.
public struct VideoInfo: Sendable {
  public let url: URL
  /// The encoded frame width, before the display transform.
  public let width: Int
  /// The encoded frame height, before the display transform.
  public let height: Int
  public let transform: CGAffineTransform
  /// The nominal capture frame rate in Hz.
  public let fps: Double
  /// The duration in seconds.
  public let duration: Double
  public let hasAudio: Bool

  /// The number of clockwise quarter turns that the display transform applies.
  public var quarterTurns: Int {
    let deg = atan2(Double(transform.b), Double(transform.a)) * 180 / .pi
    return ((Int((deg / 90).rounded()) % 4) + 4) % 4
  }

  /// The frame size after the display transform.
  public var displaySize: CGSize {
    quarterTurns % 2 == 0
      ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
  }

  public var estimatedFrames: Int { max(1, Int((duration * fps).rounded())) }

  /// Loads the description of the first video track.
  public static func load(_ url: URL) async throws -> VideoInfo {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw EngineError.message("The file has no video track.")
    }
    let (size, tf, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
    let duration = try await asset.load(.duration)
    let audio = try await asset.loadTracks(withMediaType: .audio)
    return VideoInfo(
      url: url, width: Int(size.width), height: Int(size.height), transform: tf,
      fps: Double(rate), duration: duration.seconds, hasAudio: !audio.isEmpty)
  }
}

/// Decodes video frames as 10-bit 4:2:0 pixel buffers in presentation order.
public final class FrameReader {
  /// The width of the decoded frames. Always even.
  public let width: Int
  /// The height of the decoded frames. Always even.
  public let height: Int
  public let track: AVAssetTrack
  private let reader: AVAssetReader
  private let output: AVAssetReaderTrackOutput

  /// Creates a reader and starts decoding.
  ///
  /// - Parameters:
  ///   - url: The movie file.
  ///   - maxDimension: If set, frames are scaled so that the longer side is
  ///     at most this many pixels.
  public init(url: URL, maxDimension: Int? = nil) async throws {
    let asset = AVURLAsset(url: url)
    guard let t = try await asset.loadTracks(withMediaType: .video).first else {
      throw EngineError.message("The file has no video track.")
    }
    track = t
    let size = try await t.load(.naturalSize)
    let (w0, h0) = (Int(size.width), Int(size.height))
    var s = 1.0
    if let m = maxDimension, max(w0, h0) > m { s = Double(m) / Double(max(w0, h0)) }
    width = max(2, 2 * Int((Double(w0) * s / 2).rounded()))
    height = max(2, 2 * Int((Double(h0) * s / 2).rounded()))
    var settings: [String: Any] = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    ]
    if width != w0 || height != h0 {
      settings[kCVPixelBufferWidthKey as String] = width
      settings[kCVPixelBufferHeightKey as String] = height
    }
    reader = try AVAssetReader(asset: asset)
    output = AVAssetReaderTrackOutput(track: t, outputSettings: settings)
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? EngineError.message("The reader failed to start.")
    }
  }

  /// Gets the next frame, or nil at the end of the track.
  public func next() -> CMSampleBuffer? {
    while let sb = output.copyNextSampleBuffer() {
      if CMSampleBufferGetImageBuffer(sb) != nil { return sb }
    }
    return nil
  }

  public func cancel() { reader.cancelReading() }
}

// 10-bit video range: luma code 64 is black and code 940 is white. The buffer
// stores each code in the high 10 bits of a 16-bit word.
private let lumaSpan: Float = 876 * 64
private let lumaBlack: Float = 64 * 64

/// Reads the luma plane of a 10-bit biplanar buffer as floats, where 0 is black and 1 is white.
///
/// - Parameter out: Must hold `width * height` values.
public func readLuma(_ pb: CVPixelBuffer, into out: inout [Float]) {
  CVPixelBufferLockBaseAddress(pb, .readOnly)
  defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
  let w = CVPixelBufferGetWidthOfPlane(pb, 0)
  let h = CVPixelBufferGetHeightOfPlane(pb, 0)
  let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
  let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
  precondition(out.count == w * h)
  var scale = 1 / lumaSpan
  var offset = -lumaBlack / lumaSpan
  out.withUnsafeMutableBufferPointer { o in
    for r in 0..<h {
      let src = (base + r * stride).assumingMemoryBound(to: UInt16.self)
      vDSP_vfltu16(src, 1, o.baseAddress! + r * w, 1, vDSP_Length(w))
    }
    vDSP_vsmsa(o.baseAddress!, 1, &scale, &offset, o.baseAddress!, 1, vDSP_Length(w * h))
  }
}

/// Writes floats to the luma plane of a 10-bit biplanar buffer.
///
/// Clamps values to [0, 1]. Overwrites `y` with the scaled codes.
public func writeLuma(_ y: inout [Float], to pb: CVPixelBuffer) {
  CVPixelBufferLockBaseAddress(pb, [])
  defer { CVPixelBufferUnlockBaseAddress(pb, []) }
  let w = CVPixelBufferGetWidthOfPlane(pb, 0)
  let h = CVPixelBufferGetHeightOfPlane(pb, 0)
  let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
  let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
  precondition(y.count == w * h)
  var lo: Float = 0
  var hi: Float = 1
  var scale = lumaSpan
  var offset = lumaBlack
  y.withUnsafeMutableBufferPointer { p in
    vDSP_vclip(p.baseAddress!, 1, &lo, &hi, p.baseAddress!, 1, vDSP_Length(w * h))
    vDSP_vsmsa(p.baseAddress!, 1, &scale, &offset, p.baseAddress!, 1, vDSP_Length(w * h))
    for r in 0..<h {
      let dst = (base + r * stride).assumingMemoryBound(to: UInt16.self)
      vDSP_vfixru16(p.baseAddress! + r * w, 1, dst, 1, vDSP_Length(w))
    }
  }
}
