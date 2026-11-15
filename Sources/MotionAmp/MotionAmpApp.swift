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
        .frame(minWidth: 1100, minHeight: 720)
        .onAppear {
          // Launch arguments: [--fps RATE] [--lo HZ] [--hi HZ] [VIDEO], or --demo ID.
          var args = Array(CommandLine.arguments.dropFirst())
          var path: String?
          var demo: Demo?
          while !args.isEmpty {
            let a = args.removeFirst()
            if ["--fps", "--lo", "--hi"].contains(a), !args.isEmpty {
              model.launchOptions[a] = Double(args.removeFirst())
            } else if a == "--demo", !args.isEmpty {
              let id = args.removeFirst()
              demo = Demo.all.first { $0.id == id }
            } else if !a.hasPrefix("-") {
              path = a
            }
          }
          if let demo {
            model.openDemo(demo)
          } else if let path {
            model.open(URL(fileURLWithPath: path))
          }
        }
    }
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("Open Video…") { model.openPanel() }.keyboardShortcut("o")
        Menu("Open Recent") {
          ForEach(model.recents, id: \.path) { url in
            Button(url.lastPathComponent) { model.open(url) }
          }
          if !model.recents.isEmpty { Divider() }
          Button("Clear Menu") { model.clearRecents() }.disabled(model.recents.isEmpty)
        }
        Menu("Open Demo") {
          ForEach(Demo.all) { demo in
            Button(demo.title) { model.openDemo(demo) }
          }
          Divider()
          // A disabled item that credits the source of the downloaded clips.
          Button("Downloaded clips: Wu et al., SIGGRAPH 2012, MIT CSAIL") {}.disabled(true)
        }
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
