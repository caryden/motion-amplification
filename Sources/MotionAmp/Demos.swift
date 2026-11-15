import Foundation
import SwiftUI

/// Describes one clip in the Open Demo menu.
struct Demo: Identifiable {
  let id: String
  let title: String
  /// The file name in the app bundle or in the download cache.
  let file: String
  /// The download address. If nil, the clip ships in the app bundle.
  let remote: URL?
  /// The true capture rate, for clips that are stored at a slower rate.
  let fps: Double?
  let lo: Double
  let hi: Double

  /// The synthetic clip and the flywheel clip ship in the app bundle.
  ///
  /// The guitar and baby clips come from Wu et al., "Eulerian Video
  /// Magnification for Revealing Subtle Changes in the World" (SIGGRAPH 2012).
  /// Their page states no redistribution terms, so the app downloads them from
  /// the authors' server on request and doesn't ship them.
  static let all: [Demo] = [
    Demo(
      id: "synthetic", title: "Two Vibrating Patches, with Audio", file: "synthetic-demo.mp4",
      remote: nil, fps: nil, lo: 21.6, hi: 24.4),
    // An iPhone slow-motion clip of a robot's flywheel shooter, filmed
    // handheld. The 70 Hz to 78 Hz band holds the turret plate's vibration.
    Demo(
      id: "flywheel", title: "Robot Flywheel, iPhone 240 fps", file: "flywheel-turret-240fps.mov",
      remote: nil, fps: nil, lo: 70, hi: 78),
    Demo(
      id: "guitar", title: "Guitar Strings (downloads 1.2 MB)", file: "guitar.mp4",
      remote: URL(string: "https://people.csail.mit.edu/mrub/evm/video/guitar.mp4"),
      fps: 600, lo: 72, hi: 92),
    Demo(
      id: "baby", title: "Sleeping Baby (downloads 1.8 MB)", file: "baby.mp4",
      remote: URL(string: "https://people.csail.mit.edu/mrub/evm/video/baby.mp4"),
      fps: nil, lo: 0.4, hi: 3),
  ]
}

extension AppModel {
  private static let recentsKey = "recentPaths"
  private static let maxRecents = 10

  /// Loads the recent files that still exist.
  static func loadRecents() -> [URL] {
    (UserDefaults.standard.stringArray(forKey: recentsKey) ?? [])
      .filter { FileManager.default.fileExists(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  /// Moves a file to the top of the Open Recent menu.
  func remember(_ url: URL) {
    let path = url.standardizedFileURL.path
    recents.removeAll { $0.standardizedFileURL.path == path }
    recents.insert(url, at: 0)
    recents = Array(recents.prefix(Self.maxRecents))
    UserDefaults.standard.set(recents.map(\.path), forKey: Self.recentsKey)
  }

  func clearRecents() {
    recents = []
    UserDefaults.standard.removeObject(forKey: Self.recentsKey)
  }

  private var demoCache: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("MotionAmp/demos")
  }

  /// Gets the location of a bundled demo clip, or nil if the build omitted it.
  private func bundled(_ file: String) -> URL? {
    let name = (file as NSString).deletingPathExtension
    let ext = (file as NSString).pathExtension
    if let url = Bundle.main.url(forResource: name, withExtension: ext) { return url }
    // A binary that runs outside the app bundle reads the repository folders.
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return ["build/demo", "demo"].map { root.appendingPathComponent("\($0)/\(file)") }
      .first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Opens a demo clip with its capture rate and band, downloading it first if needed.
  func openDemo(_ demo: Demo) {
    guard !demoLoading else { return }
    Task {
      do {
        let url: URL
        if let remote = demo.remote {
          url = demoCache.appendingPathComponent(demo.file)
          if !FileManager.default.fileExists(atPath: url.path) {
            demoLoading = true
            defer { demoLoading = false }
            status = "Downloading \(demo.file) from \(remote.host ?? "the server")"
            let (temp, response) = try await URLSession.shared.download(from: remote)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
              throw DemoError.message("The server didn't return the clip.")
            }
            try FileManager.default.createDirectory(
              at: demoCache, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temp, to: url)
          }
        } else if let local = bundled(demo.file) {
          url = local
        } else {
          throw DemoError.message("This build doesn't include \(demo.file).")
        }
        launchOptions = ["--lo": demo.lo, "--hi": demo.hi]
        if let fps = demo.fps { launchOptions["--fps"] = fps }
        open(url, remember: false)
      } catch {
        status = "Demo failed: \(error)"
      }
    }
  }
}

enum DemoError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let m): return m
    }
  }
}
