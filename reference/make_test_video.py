"""Writes a synthetic test video with two known subpixel vibrations.

Run from the repository root. Requires the ffmpeg command.

  uv run --with numpy reference/make_test_video.py OUTPUT.mp4

The video is 1280x720 at 120 frames per second for 3 seconds:

- A patch on the left of the frame vibrates horizontally at 23 Hz, 0.20 px.
- A patch on the right of the frame vibrates vertically at 41 Hz, 0.10 px.
- The audio track holds 23 Hz, 41 Hz, and 440 Hz tones.
"""
import subprocess
import sys
import tempfile
import wave

import numpy as np

W, H, FPS, SECONDS = 1280, 720, 120, 3
PATCHES = [
    # x0, y0, size, frequency in Hz, amplitude in px, axis (0 is x, 1 is y).
    (160, 232, 256, 23.0, 0.20, 0),
    (864, 232, 256, 41.0, 0.10, 1),
]


def texture(rng, h, w, sigma):
  spectrum = np.fft.fft2(rng.standard_normal((h, w)))
  fy = np.fft.fftfreq(h)[:, None]
  fx = np.fft.fftfreq(w)[None, :]
  spectrum *= np.exp(-(fx**2 + fy**2) / (2 * sigma**2))
  img = np.fft.ifft2(spectrum).real
  return (img - img.min()) / (img.max() - img.min())


def shift(spectrum, dx, dy):
  h, w = spectrum.shape
  fy = np.fft.fftfreq(h)[:, None]
  fx = np.fft.fftfreq(w)[None, :]
  return np.fft.ifft2(spectrum * np.exp(-2j * np.pi * (fx * dx + fy * dy))).real


def main():
  out = sys.argv[1]
  rng = np.random.default_rng(3)
  background = 0.25 + 0.5 * texture(rng, H, W, 0.08)
  patches = [np.fft.fft2(0.25 + 0.5 * texture(rng, s, s, 0.08))
             for _, _, s, _, _, _ in PATCHES]

  with tempfile.NamedTemporaryFile(suffix=".wav") as wav:
    rate = 48000
    t = np.arange(rate * SECONDS) / rate
    tone = (0.3 * np.sin(2 * np.pi * 23 * t) + 0.3 * np.sin(2 * np.pi * 41 * t)
            + 0.1 * np.sin(2 * np.pi * 440 * t))
    with wave.open(wav.name, "wb") as f:
      f.setnchannels(1)
      f.setsampwidth(2)
      f.setframerate(rate)
      f.writeframes((tone * 32767).astype("<i2").tobytes())

    ffmpeg = subprocess.Popen([
        "ffmpeg", "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt",
        "gray", "-s", f"{W}x{H}", "-r", str(FPS), "-i", "-", "-i", wav.name,
        "-c:v", "libx264", "-crf", "10", "-pix_fmt", "yuv420p", "-c:a", "aac",
        "-shortest", out
    ], stdin=subprocess.PIPE)
    for i in range(FPS * SECONDS):
      ti = i / FPS
      frame = background.copy()
      for (x0, y0, s, freq, amp, axis), spec in zip(PATCHES, patches):
        d = amp * np.sin(2 * np.pi * freq * ti)
        frame[y0:y0 + s, x0:x0 + s] = shift(
            spec, d if axis == 0 else 0.0, d if axis == 1 else 0.0)
      frame += rng.normal(0, 0.004, frame.shape)  # Sensor noise.
      ffmpeg.stdin.write(
          (np.clip(frame, 0, 1) * 255 + 0.5).astype(np.uint8).tobytes())
    ffmpeg.stdin.close()
    ffmpeg.wait()


if __name__ == "__main__":
  main()
