import AVFoundation
import VideoToolbox

/// Writes a motion-magnified copy of a video.
///
/// Magnifies the luma plane and keeps the chroma planes, timestamps, display
/// transform, and color tags of the source. The output is a 10-bit HEVC
/// QuickTime movie with no audio track.
///
/// - Parameters:
///   - url: The source movie file.
///   - output: The destination file. An existing file is replaced.
///   - lo: The lower edge of the temporal band in Hz.
///   - hi: The upper edge of the temporal band in Hz.
///   - alpha: The phase gain. Motion in the band is scaled by about `1 + alpha`.
///   - sigma: The width of the amplitude-weighted phase smoothing, in samples
///     of each pyramid level. If 0, the phase isn't smoothed.
///   - fps: The capture frame rate in Hz. If nil, uses the track's nominal rate.
///   - maxDimension: If set, the output is scaled so that the longer side is
///     at most this many pixels.
///   - progress: Called with a fraction from 0 to 1.
public func renderMagnified(
  url: URL, output: URL, lo: Double, hi: Double, alpha: Double, sigma: Double = 2,
  fps: Double? = nil,
  maxDimension: Int? = nil, progress: @Sendable (Double) -> Void = { _ in }
) async throws {
  let info = try await VideoInfo.load(url)
  let reader = try await FrameReader(url: url, maxDimension: maxDimension)
  let (w, h) = (reader.width, reader.height)
  let rate = fps ?? info.fps
  let magnifier = try Magnifier(
    width: w, height: h, fps: rate, lo: lo, hi: hi, alpha: alpha, sigma: sigma)

  try? FileManager.default.removeItem(at: output)
  let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
  // About 0.1 bits per pixel per frame, with a floor for small frames.
  let bitRate = max(8_000_000, Int(Double(w * h) * min(rate, 240) * 0.1))
  var settings: [String: Any] = [
    AVVideoCodecKey: AVVideoCodecType.hevc,
    AVVideoWidthKey: w,
    AVVideoHeightKey: h,
    AVVideoCompressionPropertiesKey: [
      AVVideoAverageBitRateKey: bitRate,
      AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel as String,
    ],
  ]
  if let fd = try await reader.track.load(.formatDescriptions).first,
    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any],
    let primaries = ext[kCVImageBufferColorPrimariesKey as String],
    let transfer = ext[kCVImageBufferTransferFunctionKey as String],
    let matrix = ext[kCVImageBufferYCbCrMatrixKey as String]
  {
    settings[AVVideoColorPropertiesKey] = [
      AVVideoColorPrimariesKey: primaries,
      AVVideoTransferFunctionKey: transfer,
      AVVideoYCbCrMatrixKey: matrix,
    ]
  }
  let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
  input.expectsMediaDataInRealTime = false
  input.transform = info.transform
  writer.add(input)
  guard writer.startWriting() else {
    throw writer.error ?? EngineError.message("The writer failed to start.")
  }

  var y = [Float](repeating: 0, count: w * h)
  var out = y
  var count = 0
  var started = false
  while let sb = reader.next() {
    if Task.isCancelled {
      reader.cancel()
      writer.cancelWriting()
      throw CancellationError()
    }
    let pb = CMSampleBufferGetImageBuffer(sb)!
    if !started {
      writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sb))
      started = true
    }
    readLuma(pb, into: &y)
    y.withUnsafeBufferPointer { magnifier.process($0, into: &out) }
    // The reader vends copied sample data, so the buffer is safe to edit in place.
    writeLuma(&out, to: pb)
    while !input.isReadyForMoreMediaData {
      if writer.status == .failed { throw writer.error ?? EngineError.message("The writer failed.") }
      try await Task.sleep(nanoseconds: 2_000_000)
    }
    guard input.append(sb) else {
      throw writer.error ?? EngineError.message("The writer rejected a frame.")
    }
    count += 1
    if count % 8 == 0 { progress(min(0.99, Double(count) / Double(info.estimatedFrames))) }
  }
  input.markAsFinished()
  await writer.finishWriting()
  if writer.status != .completed {
    throw writer.error ?? EngineError.message("The writer didn't complete.")
  }
  progress(1)
}
