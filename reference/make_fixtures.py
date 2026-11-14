"""Checks the reference pyramid and writes fixtures for the Swift tests.

Run from the repository root:

  uv run --with numpy reference/make_fixtures.py

Writes raw little-endian float32 files and a manifest.json file to the
reference/fixtures directory.
"""
import json
import pathlib

import numpy as np

import steerable as sp

H, W, SCALES, ORIENTS = 48, 64, 3, 4
FS, LO, HI, ALPHA, FRAMES = 60.0, 8.0, 12.0, 8.0, 48
SIGMA = 1.5
OUT = pathlib.Path(__file__).parent / "fixtures"


def shift(image, dx, dy):
  """Shifts a periodic image by a subpixel offset with a Fourier ramp."""
  h, w = image.shape
  fy = np.fft.fftfreq(h)[:, None]
  fx = np.fft.fftfreq(w)[None, :]
  ramp = np.exp(-2j * np.pi * (fx * dx + fy * dy))
  return np.fft.ifft2(np.fft.fft2(image) * ramp).real


def texture(rng, h, w):
  """Creates a band-limited random texture with values in [0, 1]."""
  spectrum = np.fft.fft2(rng.standard_normal((h, w)))
  fy = np.fft.fftfreq(h)[:, None]
  fx = np.fft.fftfreq(w)[None, :]
  spectrum *= np.exp(-(fx**2 + fy**2) / (2 * 0.12**2))
  img = np.fft.ifft2(spectrum).real
  return (img - img.min()) / (img.max() - img.min())


def tone_amplitude(series, fs, freq):
  """Gets the amplitude of one frequency in a series by projection."""
  t = np.arange(len(series)) / fs
  ref = np.exp(-2j * np.pi * freq * t)
  return 2 * abs((series * ref).mean())


def main():
  rng = np.random.default_rng(7)
  image = texture(rng, H, W)
  bands, residual = sp.build_filters(H, W, SCALES, ORIENTS)

  # Check 1: analysis followed by synthesis returns the input.
  spectrum = np.fft.fft2(image)
  coefs = sp.analyze(spectrum, bands)
  recon = sp.synthesize(spectrum, coefs, bands, residual)
  err = np.abs(recon - image).max()
  print(f"reconstruction max error: {err:.3e}")
  assert err < 1e-10

  # Check 2: a 10 Hz, 0.05 px horizontal vibration is measured and magnified.
  freq, amp = 10.0, 0.05
  t = np.arange(FRAMES) / FS
  video = np.stack(
      [shift(image, amp * np.sin(2 * np.pi * freq * ti), 0.0) for ti in t])
  dx, dy, wt = sp.displacement(video, 2, SCALES, ORIENTS)
  w0 = wt[:, 0].mean(axis=0)
  series = (dx * w0).sum(axis=(1, 2)) / w0.sum()
  measured = tone_amplitude(series[12:], FS, freq)
  print(f"input amplitude {amp} px, measured {measured:.4f} px")
  assert abs(measured - amp) / amp < 0.25

  magnified = sp.magnify(video, FS, LO, HI, ALPHA, SCALES, ORIENTS)
  mdx, _, mwt = sp.displacement(magnified, 2, SCALES, ORIENTS)
  w1 = mwt[:, 0].mean(axis=0)
  mseries = (mdx * w1).sum(axis=(1, 2)) / w1.sum()
  gain = tone_amplitude(mseries[24:], FS, freq) / tone_amplitude(
      series[24:], FS, freq)
  print(f"measured gain {gain:.2f}, expected about {1 + ALPHA:.0f}")
  assert 0.6 * (1 + ALPHA) < gain < 1.4 * (1 + ALPHA)

  # Write fixtures.
  OUT.mkdir(exist_ok=True)
  manifest = {
      "h": H, "w": W, "scales": SCALES, "orients": ORIENTS, "fs": FS,
      "lo": LO, "hi": HI, "alpha": ALPHA, "frames": FRAMES, "sigma": SIGMA,
      "biquad": list(sp.bandpass_biquad(LO, HI, FS)), "arrays": {},
  }

  def save(name, array):
    array = np.ascontiguousarray(array, dtype="<f4")
    array.tofile(OUT / f"{name}.bin")
    manifest["arrays"][name] = list(array.shape)

  save("image", image)
  save("residual", residual)
  for k, (f, c) in enumerate(zip(bands, coefs), start=1):
    save(f"filter{k}", f)
    save(f"coef{k}_re", c.real)
    save(f"coef{k}_im", c.imag)
  save("video", video)
  save("magnified", magnified)
  save("magnified_smooth", sp.magnify(
      video, FS, LO, HI, ALPHA, SCALES, ORIENTS, sigma=SIGMA))
  save("disp_x", dx)
  pooled, pooled_wt = sp.pooled_displacement(video, [1, 2, 3], 2, ORIENTS)
  save("pooled_disp", pooled)
  save("pooled_weight", pooled_wt)
  (OUT / "manifest.json").write_text(json.dumps(manifest, indent=2))
  print(f"wrote {len(manifest['arrays'])} arrays to {OUT}")


if __name__ == "__main__":
  main()
