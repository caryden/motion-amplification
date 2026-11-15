# Motion Amp

Motion Amp is a macOS app that amplifies subtle motion in video and shows
which parts of the frame vibrate at a chosen frequency. It uses phase-based
video magnification (Wadhwa et al., SIGGRAPH 2013) on the GPU through
MPSGraph.

![The Motion Amp window with the robot flywheel clip open. A heat map marks
the turret plate, and the motion spectrum has a peak at 72.9 Hz inside the
selected band.](docs/screenshot.png)

The screenshot shows the bundled robot flywheel clip with the band from 70 Hz
to 78 Hz selected. The heat map marks the turret plate, which vibrates at
72.9 Hz. The audio plot shows a tone near 75 Hz in the same band.

## Example: a robot flywheel

The example is a handheld iPhone slow-motion clip of a FIRST Tech Challenge
robot. Its flywheel shooter makes an audible vibration, and the goal is to find
which parts move at which frequency.

| Clip | Details |
| --- | --- |
| [Original](demo/flywheel-turret-240fps.mov) | 1080 by 1920 pixels, 239.9 frames per second, 1,418 frames, 38 MB |
| [Amplified, 70 Hz to 78 Hz](demo/flywheel-turret-amplified-70-78hz.mov) | 720 by 1280 pixels, gain 20, smoothing 2, camera motion removed, 16 MB |

GitHub doesn't play these files inside the README. To watch a clip, click its
link, and then download the file or use the player on the file's page.

Both files play in slow motion with the sound at its recorded pitch, because
an iPhone slow-motion file stores 240 frames per second of video beside
real-time audio. The original is the iPhone's file with the location and
device tags removed. The video and audio data are unchanged.

To reproduce the amplified clip, build the project and run the render command:

```sh
.build/release/motionamp-cli render demo/flywheel-turret-240fps.mov \
  amplified.mov --lo 70 --hi 78 --max-dim 1280
```

The command writes video only. The amplified clip in this repository also
carries the original's audio track, which `ffmpeg` copied in.

In the app, select **File > Open Demo > Robot Flywheel, iPhone 240 fps** to
open the original with the same band.

## Before you begin

- macOS 14 or later with Xcode installed.
- A video shot on a tripod. The method amplifies camera shake too.
- Optional: the `uv` and `ffmpeg` commands. The build script uses them to
  generate the bundled demo clip. Without them, the app builds and that one
  demo is unavailable.

A camera resolves vibrations only up to half its frame rate: 120 Hz for
240 frames per second, 30 Hz for 60 frames per second.

## Transfer iPhone slow-motion clips

Transfer the unmodified original file, not a shared copy. AirDrop can send a
rendered copy of a slow-motion clip in place of the original. In the case that
prompted this note, a clip recorded at 240 frames per second arrived as an
H.264 file at 30 frames per second. That file keeps every captured frame but
plays each one for eight times as long, and its audio is slowed to match. Every
frequency that the app reports from such a file is one eighth of the true
value.

To get the original onto a Mac, follow these steps:

1. Let the clip sync to the Photos app on the Mac through iCloud Photos, or
   import it over a cable.
1. In Photos, select the clip.
1. Select **File > Export > Export Unmodified Original**.

To check a file, open it in the app. The **Clip** group shows a capture rate
near 240 fps for an original and 30 fps for a rendered copy.

If you have only the rendered copy, type the true rate in the **Capture rate**
field. That step corrects the motion frequencies. It doesn't correct the audio,
so the audio plot and the motion plot no longer line up.

## Build and run

Build the app bundle:

```sh
scripts/make-app.sh
```

Open the app:

```sh
open build/MotionAmp.app
```

## See the demos

Select **File > Open Demo**, and then select a clip:

- **Two Vibrating Patches, with Audio** ships in the app. It holds a 23 Hz
  and a 41 Hz vibration, with matching audio tones.
- **Robot Flywheel, iPhone 240 fps** ships in the app. It's the handheld
  slow-motion clip from the example, and it opens with the band from 70 Hz to
  78 Hz.
- **Guitar Strings** and **Sleeping Baby** download from MIT CSAIL on first
  use, into the `~/Library/Caches/MotionAmp/demos` directory. They come from
  Wu et al., "Eulerian Video Magnification for Revealing Subtle Changes in the
  World" (SIGGRAPH 2012). The app doesn't redistribute them, because their
  page states no redistribution terms.

Each demo opens with its capture rate and frequency band already set.

## Use the app

1. Click **Open Video…**, or select a clip from **File > Open Recent**. The
   app measures motion over the whole clip.
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
- `demo/`: the robot flywheel clip and its amplified result.
- `docs/`: the screenshot in this file.

## Test

Compare the Swift engine with the reference fixtures:

```sh
swift test
```

Regenerate the fixtures after a change to `reference/steerable.py`:

```sh
uv run --with numpy reference/make_fixtures.py
```

## Acknowledgments

This project started from Steve Mould's video
[Reveal Invisible Motion With This Clever Video Trick](https://www.youtube.com/watch?v=rEoc0YoALt0),
which shows what motion amplification can reveal in ordinary footage.

The method comes from research at the MIT Computer Science and Artificial
Intelligence Laboratory (CSAIL):

- [Phase-Based Video Motion Processing](https://people.csail.mit.edu/nwadhwa/phase-video/)
  by Neal Wadhwa, Michael Rubinstein, Frédo Durand, and William T. Freeman,
  SIGGRAPH 2013. The engine in this repository implements the complex steerable
  pyramid and the phase amplification that this paper describes.
- [Eulerian Video Magnification for Revealing Subtle Changes in the World](https://people.csail.mit.edu/mrub/evm/)
  by Hao-Yu Wu, Michael Rubinstein, Eugene Shih, John Guttag, Frédo Durand, and
  William T. Freeman, SIGGRAPH 2012. The guitar and baby demo clips come from
  this project page, and the demo bands follow the bands that the authors
  published.
- [Video Magnification](https://people.csail.mit.edu/mrub/vidmag/), the
  overview page that links both papers and later work.

The temporal band-pass filter uses the constant-peak-gain form from the
[Audio EQ Cookbook](https://www.w3.org/TR/audio-eq-cookbook/) by Robert
Bristow-Johnson.

The following open-source projects informed the design. This repository
contains no code from them:

- [pyevm](https://github.com/roaldarbol/pyevm): phase-based magnification in
  PyTorch.
- [Live Video Magnification](https://github.com/tschnz/Live-Video-Magnification):
  a desktop app that uses a Riesz pyramid.
- [Angstrom](https://github.com/levi2234/Angstrom): phase-based magnification
  with a frequency range option.
- [MotionAplification](https://github.com/IvRogoz/MotionAplification): Eulerian
  and phase-based variants.
- [visual-mic](https://github.com/dsforza96/visual-mic): an implementation of
  the Visual Microphone, which recovers sound from video. The Veritasium video
  [Can You Recover Sound From Images?](https://www.youtube.com/watch?v=eUzB0L0mSCI)
  explains that technique.

## License

The code in this repository is available under the MIT License. For the terms,
see the `LICENSE` file.

The license doesn't cover the demo clips that the app downloads from MIT. Those
clips belong to their authors and aren't part of this repository.
