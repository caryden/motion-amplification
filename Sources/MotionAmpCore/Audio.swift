import AVFoundation
import Accelerate

/// Holds the decoded audio track of a movie file.
public struct AudioData: Sendable {
  public let sampleRate: Double
  /// One array of samples per channel.
  public let channels: [[Float]]
  /// The track's start time within the movie, in seconds.
  public let startTime: Double

  public var mono: [Float] {
    guard channels.count > 1 else { return channels.first ?? [] }
    var m = [Float](repeating: 0, count: channels[0].count)
    for ch in channels { vDSP.add(m, ch, result: &m) }
    return vDSP.divide(m, Float(channels.count))
  }

  /// Decodes the first audio track of a movie file.
  ///
  /// - Returns: The audio, or nil if the file has no audio track.
  public static func load(_ url: URL) async throws -> AudioData? {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return nil }
    let range = try await track.load(.timeRange)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
      ])
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? EngineError.message("The audio reader failed to start.")
    }
    var rate = 48000.0
    var nch = 1
    var interleaved: [Float] = []
    while let sb = output.copyNextSampleBuffer() {
      if let fd = CMSampleBufferGetFormatDescription(sb),
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee
      {
        rate = asbd.mSampleRate
        nch = Int(asbd.mChannelsPerFrame)
      }
      guard let block = CMSampleBufferGetDataBuffer(sb) else { continue }
      let length = CMBlockBufferGetDataLength(block)
      let start = interleaved.count
      interleaved.append(contentsOf: repeatElement(0, count: length / 4))
      interleaved.withUnsafeMutableBytes {
        _ = CMBlockBufferCopyDataBytes(
          block, atOffset: 0, dataLength: length, destination: $0.baseAddress! + start * 4)
      }
    }
    let n = interleaved.count / nch
    let channels = (0..<nch).map { c in (0..<n).map { interleaved[$0 * nch + c] } }
    return AudioData(sampleRate: rate, channels: channels, startTime: range.start.seconds)
  }

  /// Gets the averaged amplitude spectrum of the mono mix.
  ///
  /// Uses Hann-windowed segments with 50% overlap.
  ///
  /// - Parameter resolutionHz: The largest acceptable bin spacing in Hz.
  /// - Returns: The bin spacing in Hz and the amplitude of each bin.
  public func spectrum(resolutionHz: Double = 1) -> (binHz: Double, amplitude: [Float]) {
    let x = mono
    let n = nextPowerOfTwo(Int(sampleRate / resolutionHz))
    let plan = SpectrumPlan(n: n)
    var window = [Float](repeating: 0, count: n)
    vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
    let scale = 2 / window.reduce(0, +)
    var acc = [Float](repeating: 0, count: n / 2)
    var p = acc
    var seg = [Float](repeating: 0, count: n)
    var segments = 0
    var start = 0
    repeat {
      for i in 0..<n { seg[i] = start + i < x.count ? x[start + i] * window[i] : 0 }
      plan.power(seg, into: &p)
      vDSP.add(acc, p, result: &acc)
      segments += 1
      start += n / 2
    } while start + n <= x.count
    return (sampleRate / Double(n), acc.map { ($0 / Float(segments)).squareRoot() * scale })
  }

  /// Writes a band-pass filtered copy of the audio to a file.
  ///
  /// - Parameters:
  ///   - url: The destination file. The extension selects the container, for example `caf`.
  ///   - lo: The lower band edge in Hz. If nil, the audio isn't filtered.
  ///   - hi: The upper band edge in Hz.
  ///   - normalize: If true, scales the result so that the peak is 0.7 of full scale.
  public func write(to url: URL, lo: Double?, hi: Double?, normalize: Bool) throws {
    var out = channels
    if let lo, let hi, lo > 0, hi > lo, hi < sampleRate / 2 {
      let b = Biquad(lo: lo, hi: hi, fs: sampleRate)
      for c in out.indices {
        // Two cascaded sections, the same response as the video filter.
        for _ in 0..<2 {
          var z1 = 0.0
          var z2 = 0.0
          for i in out[c].indices {
            let v = Double(out[c][i])
            let y = b.b0 * v + z1
            z1 = b.b1 * v - b.a1 * y + z2
            z2 = b.b2 * v - b.a2 * y
            out[c][i] = Float(y)
          }
        }
      }
    }
    if normalize {
      let peak = out.map { vDSP.maximumMagnitude($0) }.max() ?? 0
      if peak > 0 { out = out.map { vDSP.multiply(0.7 / peak, $0) } }
    }
    try? FileManager.default.removeItem(at: url)
    let format = AVAudioFormat(
      standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(out.count))!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let n = out[0].count
    guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(n))
    else { return }
    buffer.frameLength = AVAudioFrameCount(n)
    for c in out.indices {
      out[c].withUnsafeBufferPointer {
        buffer.floatChannelData![c].update(from: $0.baseAddress!, count: n)
      }
    }
    try file.write(from: buffer)
  }
}
