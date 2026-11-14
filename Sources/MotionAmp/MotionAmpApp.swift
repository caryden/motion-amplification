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
          // A path argument opens that file at launch.
          if let path = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
            model.open(URL(fileURLWithPath: path))
          }
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
