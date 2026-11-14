import AVFoundation
import SwiftUI

@main
struct MotionAmpApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var model = AppModel()

  var body: some Scene {
    WindowGroup("Motion Amp") {
      ContentView()
        .environmentObject(model)
        .frame(minWidth: 960, minHeight: 680)
        .onAppear {
          // Launch arguments: [--fps RATE] [--lo HZ] [--hi HZ] [VIDEO].
          var args = Array(CommandLine.arguments.dropFirst())
          var path: String?
          while !args.isEmpty {
            let a = args.removeFirst()
            if ["--fps", "--lo", "--hi"].contains(a), !args.isEmpty {
              model.launchOptions[a] = Double(args.removeFirst())
            } else if !a.hasPrefix("-") {
              path = a
            }
          }
          if let path { model.open(URL(fileURLWithPath: path)) }
        }
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open Video…") { model.openPanel() }.keyboardShortcut("o")
      }
    }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    // Without an app bundle, the process starts as a background app.
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Shows the video of an `AVPlayer` object, scaled to fit.
struct PlayerView: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    let layer = AVPlayerLayer(player: player)
    layer.videoGravity = .resizeAspect
    view.layer = layer
    view.wantsLayer = true
    return view
  }

  func updateNSView(_ view: NSView, context: Context) {}
}
