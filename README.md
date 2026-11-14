# Motion Amp

Motion Amp is a macOS app that amplifies subtle motion in video and shows
which parts of the frame vibrate at a chosen frequency. It uses phase-based
video magnification (Wadhwa et al., SIGGRAPH 2013) on the GPU through
MPSGraph.

## Before you begin

- macOS 14 or later with Xcode installed.
- A video shot on a tripod. The method amplifies camera shake too.

A camera resolves vibrations only up to half its frame rate: 120 Hz for
240 frames per second, 30 Hz for 60 frames per second.

## Build and run

Build the app bundle:

```sh
scripts/make-app.sh
```

Open the app:

```sh
open build/MotionAmp.app
```

## Use the app

1. Click **Open Video…**. The app measures motion over the whole clip.
1. In the spectrum plot, drag across a frequency range, or click a peak
   button. The heat map shows where the frame moves in that band, and the
   audio plays filtered to the same band.
1. Click the video to plot the spectrum of one point.
1. Click **Render Amplified Video**, and then compare **Original** and
   **Amplified**.
1. To save the amplified video with the audio that is playing, click
   **Export…**.

## Layout

- `reference/`: the NumPy reference pyramid, its fixtures, and a synthetic
  test video generator.
- `Sources/MotionAmpCore/`: the engine, video and audio input, analysis, and
  rendering.
- `Sources/MotionAmp/`: the SwiftUI app.
- `Sources/motionamp-cli/`: a command-line front end for scripted checks.

## Test

Compare the Swift engine with the reference fixtures:

```sh
swift test
```

Regenerate the fixtures after a change to `reference/steerable.py`:

```sh
uv run --with numpy reference/make_fixtures.py
```
