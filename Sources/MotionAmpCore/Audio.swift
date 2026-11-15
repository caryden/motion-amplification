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

/// Divides each bin of a spectrum by the median of the bins around it.
///
/// The result is about 1 for broadband noise and larger for a tone, whatever
/// the overall slope of the spectrum.
///
/// - Parameters:
///   - s: The amplitude spectrum.
///   - count: The number of leading bins to process.
///   - span: The number of bins on each side that form the median.
func whitened(_ s: [Float], count: Int, span: Int) -> [Float] {
  let n = min(count, s.count)
  var out = [Float](repeating: 1, count: n)
  out.withUnsafeMutableBufferPointer { o in
    let op = o.baseAddress!
    DispatchQueue.concurrentPerform(iterations: n) { i in
      var around = Array(s[max(0, i - span)...min(s.count - 1, i + span)])
      around.sort()
      op[i] = s[i] / max(1e-20, around[around.count / 2])
    }
  }
  return out
}

/// Gets the tones of a spectrum that stand clear of the noise around them.
///
/// - Parameters:
///   - s: The amplitude spectrum.
///   - binHz: The frequency step between bins.
///   - ratio: The smallest multiple of the local median that counts as a tone.
/// - Returns: Up to `count` pairs of frequency and amplitude, loudest first.
public func spectrumPeaks(
  _ s: [Float], binHz: Double, minHz: Double, maxHz: Double, count: Int, ratio: Float = 2.5
) -> [(hz: Double, amplitude: Float)] {
  let last = min(s.count - 1, Int(maxHz / binHz))
  let first = max(8, Int(minHz / binHz))
  guard first + 16 < last else { return [] }
  // A wide median window keeps a tone that wanders in pitch from raising its own baseline.
  let w = whitened(s, count: last + 1, span: 100)
  // Ignore tones more than 40 dB under the loudest bin in range.
  let floor = (s[first...last].max() ?? 0) / 100
  var found: [(Double, Float)] = []
  for i in first..<last - 8
  where w[i] >= ratio && s[i] >= floor && s[i] == s[i - 8...i + 8].max() {
    found.append((Double(i) * binHz, s[i]))
  }
  return found.sorted { $0.1 > $1.1 }.prefix(count).map { (hz: $0.0, amplitude: $0.1) }
}

/// Estimates the fundamental frequency of a harmonic series in a spectrum.
///
/// For each candidate, averages how far the spectrum rises over its local
/// median at the candidate's first 12 multiples. A true fundamental scores
/// high because most multiples land on tones. Half of a true fundamental
/// scores lower because its odd multiples land on noise.
///
/// - Parameters:
///   - s: The amplitude spectrum.
///   - binHz: The frequency step between bins.
///   - limitHz: The highest frequency whose multiples are scored.
/// - Returns: The best candidate in Hz and its score, or nil if the spectrum is too short.
public func estimateFundamental(
  _ s: [Float], binHz: Double, minHz: Double = 20, maxHz: Double = 200, limitHz: Double = 3000
) -> (hz: Double, score: Float)? {
  let n = min(s.count, Int(limitHz / binHz) + 2)
  guard n > 200 else { return nil }
  let w = whitened(s, count: n, span: 40).map { max(0, min(3, log($0))) }
  var best: (Double, Float)?
  var f0 = minHz
  while f0 <= maxHz {
    let multiples = min(12, Int(limitHz / f0))
    var total: Float = 0
    for k in 1...multiples {
      let center = Double(k) * f0
      // Accept a tone within 0.7% of the multiple.
      let a = max(0, Int((center * 0.993 / binHz).rounded(.down)))
      let b = min(n - 1, Int((center * 1.007 / binHz).rounded(.up)))
      if a <= b { total += w[a...b].max() ?? 0 }
    }
    let score = total / Float(multiples)
    if best == nil || score > best!.1 { best = (f0, score) }
    f0 += binHz / 2
  }
  return best.map { (hz: $0.0, score: $0.1) }
}
