import CoreGraphics
import Foundation
import ImageIO
import MotionAmpCore
import UniformTypeIdentifiers

// Command-line front end for the engine. Used for scripted checks.
//
//   motionamp-cli analyze VIDEO [--lo HZ --hi HZ] [--heat PNG]
//   motionamp-cli render VIDEO OUTPUT --lo HZ --hi HZ [--alpha N] [--max-dim N]
//   motionamp-cli audio VIDEO OUTPUT [--lo HZ --hi HZ]

var positional: [String] = []
var options: [String: String] = [:]
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
  let a = args.removeFirst()
  if a.hasPrefix("--"), !args.isEmpty {
    options[String(a.dropFirst(2))] = args.removeFirst()
  } else {
    positional.append(a)
  }
}
func number(_ key: String) -> Double? { options[key].flatMap(Double.init) }

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data((message + "\n").utf8))
  exit(1)
}

guard positional.count >= 2 else {
  fail("usage: motionamp-cli analyze|render|audio VIDEO [OUTPUT] [--lo HZ] [--hi HZ] ...")
}
let source = URL(fileURLWithPath: positional[1])
let started = Date()

do {
  switch positional[0] {
  case "analyze":
    let info = try await VideoInfo.load(source)
    print("video: \(info.width)x\(info.height), \(info.fps) fps nominal, \(info.duration) s")
    let a = try await analyzeMotion(url: source)
    print("frames: \(a.frames), measured fps: \(a.fps), grid: \(a.gridWidth)x\(a.gridHeight)")
    print("motion peaks:")
    for p in a.peaks(count: 5) {
      print(String(format: "  %7.2f Hz  %.4f px", p.hz, p.amplitude))
    }
    if let audio = try await AudioData.load(source) {
      let s = audio.spectrum()
      let limit = min(s.amplitude.count, Int(a.nyquist / s.binHz))
      let top = (2..<limit).sorted { s.amplitude[$0] > s.amplitude[$1] }.prefix(3)
      print("audio peaks under \(a.nyquist) Hz:")
      for i in top { print(String(format: "  %7.2f Hz", Double(i) * s.binHz)) }
    }
    if let lo = number("lo"), let hi = number("hi") {
      let heat = a.heat(lo: lo, hi: hi)
      let total = heat.reduce(0, +)
      var cx: Float = 0
      var cy: Float = 0
      for (i, v) in heat.enumerated() {
        cx += v * Float(i % a.gridWidth)
        cy += v * Float(i / a.gridWidth)
      }
      print(
        String(
          format: "heat %.1f-%.1f Hz: max %.4f px, centroid x %.3f y %.3f (fraction of frame)",
          lo, hi, heat.max() ?? 0, cx / total / Float(a.gridWidth),
          cy / total / Float(a.gridHeight)))
      if let path = options["heat"],
        let image = heatImage(values: heat, width: a.gridWidth, height: a.gridHeight),
        let dest = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
      {
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
      }
    }
  case "render":
    guard positional.count >= 3, let lo = number("lo"), let hi = number("hi") else {
      fail("render needs OUTPUT, --lo, and --hi")
    }
    try await renderMagnified(
      url: source, output: URL(fileURLWithPath: positional[2]), lo: lo, hi: hi,
      alpha: number("alpha") ?? 20, maxDimension: number("max-dim").map { Int($0) })
  case "audio":
    guard positional.count >= 3 else { fail("audio needs OUTPUT") }
    guard let audio = try await AudioData.load(source) else { fail("no audio track") }
    try audio.write(
      to: URL(fileURLWithPath: positional[2]), lo: number("lo"), hi: number("hi"),
      normalize: true)
  default:
    fail("unknown command \(positional[0])")
  }
  print(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
} catch {
  fail("error: \(error)")
}
