// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "MotionAmp",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "MotionAmpCore"),
    .executableTarget(name: "motionamp-cli", dependencies: ["MotionAmpCore"]),
    .executableTarget(name: "MotionAmp", dependencies: ["MotionAmpCore"]),
    .testTarget(name: "MotionAmpCoreTests", dependencies: ["MotionAmpCore"]),
  ]
)
