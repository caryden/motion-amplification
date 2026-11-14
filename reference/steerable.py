"""Reference complex steerable pyramid and phase-based motion magnification.

This NumPy module is the ground truth for the Swift engine. The Swift code
must reproduce these arrays to float32 precision. The design follows Wadhwa
et al., "Phase-Based Video Motion Processing" (SIGGRAPH 2013).

All spectra use the unshifted FFT layout: index 0 is the zero frequency.
Frame heights and widths must be even.
"""
from math import factorial, pi, sqrt, sin, cos

import numpy as np


def level_size(n, k):
  """Gets the cropped spectrum size of level k (1-based) along an axis of n."""
  return min(n, 2 * int(np.ceil(n / 2**k)))


def crop_index(n, nc):
  """Gets the unshifted-layout indices of the nc lowest frequencies of n."""
  return np.r_[0:nc // 2, n - nc // 2:n]


def build_filters(h, w, scales, orients):
  """Creates the pyramid filters.

  Returns:
    A tuple (bands, residual). bands[k-1] is a real array of shape
    [orients, hk, wk] that holds the cropped filters of level k. residual is
    the [h, w] sum of the squared high-pass and low-pass residual filters.
  """
  fy = np.fft.fftfreq(h) * 2.0  # Nyquist is at -1.
  fx = np.fft.fftfreq(w) * 2.0
  x, y = np.meshgrid(fx, fy)
  rad = np.hypot(x, y)
  rad[0, 0] = 1e-9  # Avoids log2(0). The low-pass filter is 1 here.
  angle = np.arctan2(y, x)

  def radial(r):
    # hi is 0 at or under r/2, 1 at or over r, with a cosine ramp between.
    t = np.clip(np.log2(rad / r), -1.0, 0.0)
    hi = np.cos(t * pi / 2)
    lo = np.sqrt(np.maximum(0.0, 1.0 - hi**2))
    return hi, lo

  order = orients - 1
  const = 2**(2 * order) * factorial(order)**2 / (
      orients * factorial(2 * order))
  angular = []
  for b in range(orients):
    a = np.mod(pi + angle - pi * b / orients, 2 * pi) - pi
    # One-sided filter: only the half plane that faces orientation b.
    angular.append(
        sqrt(2 * const) * np.cos(a)**order * (np.abs(a) < pi / 2))

  hi_prev, lo_prev = radial(1.0)
  residual = hi_prev**2
  bands = []
  for k in range(1, scales + 1):
    hi_k, lo_k = radial(2.0**-k)
    rad_k = hi_k * lo_prev
    ri = crop_index(h, level_size(h, k))
    ci = crop_index(w, level_size(w, k))
    bands.append(np.stack([(rad_k * a)[np.ix_(ri, ci)] for a in angular]))
    lo_prev = lo_k
  residual = residual + lo_prev**2
  return bands, residual


def analyze(spectrum, bands):
  """Gets the complex coefficients of every level from a frame spectrum."""
  h, w = spectrum.shape
  coefs = []
  for k, f in enumerate(bands, start=1):
    ri = crop_index(h, f.shape[1])
    ci = crop_index(w, f.shape[2])
    coefs.append(np.fft.ifft2(spectrum[np.ix_(ri, ci)][None] * f))
  return coefs


def synthesize(spectrum, coefs, bands, residual):
  """Reconstructs a real frame from its spectrum and band coefficients."""
  h, w = spectrum.shape
  acc = spectrum * residual
  for c, f in zip(coefs, bands):
    ri = crop_index(h, f.shape[1])
    ci = crop_index(w, f.shape[2])
    acc[np.ix_(ri, ci)] += (np.fft.fft2(c) * f).sum(axis=0)
  return np.fft.ifft2(acc).real


def bandpass_biquad(lo, hi, fs):
  """Creates one band-pass biquad section with 0 dB peak gain.

  Uses the Audio EQ Cookbook constant-peak-gain band-pass form.

  Returns:
    A tuple (b0, b1, b2, a1, a2), normalized so that a0 is 1.
  """
  f0 = sqrt(lo * hi)
  w0 = 2 * pi * f0 / fs
  alpha = sin(w0) * (hi - lo) / (2 * f0)
  a0 = 1 + alpha
  return (alpha / a0, 0.0, -alpha / a0, -2 * cos(w0) / a0, (1 - alpha) / a0)


def magnify(frames, fs, lo, hi, alpha, scales, orients, sections=2):
  """Magnifies motion in the [lo, hi] Hz band by a factor of (1 + alpha).

  The temporal filter is a causal cascade of identical biquad sections in
  transposed direct form II, applied to the phase difference between each
  frame and the first frame.

  Args:
    frames: A real array of shape [t, h, w].
    fs: The frame rate in Hz.
  """
  t, h, w = frames.shape
  bands, residual = build_filters(h, w, scales, orients)
  b0, b1, b2, a1, a2 = bandpass_biquad(lo, hi, fs)
  ref = None
  state = [[[np.zeros(f.shape), np.zeros(f.shape)] for _ in range(sections)]
           for f in bands]
  out = np.empty_like(frames)
  for i in range(t):
    spectrum = np.fft.fft2(frames[i])
    coefs = analyze(spectrum, bands)
    if ref is None:
      ref = coefs
    new = []
    for k, c in enumerate(coefs):
      v = np.angle(c * np.conj(ref[k]))
      for z in state[k]:
        y = b0 * v + z[0]
        z[0] = b1 * v - a1 * y + z[1]
        z[1] = b2 * v - a2 * y
        v = y
      new.append(c * np.exp(1j * alpha * v))
    out[i] = synthesize(spectrum, new, bands, residual)
  return out


def displacement(frames, level, scales, orients):
  """Estimates per-pixel displacement from the first frame, in pixels.

  Uses the phase of one pyramid level at orientations 0 (x) and orients/2
  (y). The conversion assumes that local image content sits at the level's
  peak frequency, so the result is approximate.

  Returns:
    A tuple (dx, dy, weight). dx and dy have shape [t, hk, wk]. weight is the
    squared coefficient amplitude with shape [t, 2, hk, wk].
  """
  t, h, w = frames.shape
  bands, _ = build_filters(h, w, scales, orients)
  f = bands[level - 1][[0, orients // 2]]
  ri = crop_index(h, f.shape[1])
  ci = crop_index(w, f.shape[2])
  peak = 0.5 * 2.0**-level  # Cycles per pixel.
  ref = None
  d = np.empty((t, 2) + f.shape[1:])
  wt = np.empty_like(d)
  for i in range(t):
    c = np.fft.ifft2(np.fft.fft2(frames[i])[np.ix_(ri, ci)][None] * f)
    if ref is None:
      ref = c
    d[i] = -np.angle(c * np.conj(ref)) / (2 * pi * peak)
    wt[i] = np.abs(c)**2
  return d[:, 0], d[:, 1], wt


def pooled_displacement(frames, levels, pool, orients):
  """Estimates displacement on a coarse grid from several pyramid levels.

  Each level's displacement is averaged over square blocks with the squared
  coefficient amplitude as the weight, and the levels are then combined with
  the same weights. The coarsest level uses blocks of pool samples per side.
  Finer levels use proportionally larger blocks, so all levels share a grid.

  Returns:
    A tuple (d, weight) of arrays with shape [t, 2, gh, gw]. Index 0 of the
    second axis is x and index 1 is y. d is in pixels.
  """
  t, h, w = frames.shape
  top = max(levels)
  bands, _ = build_filters(h, w, top, orients)
  parts = []
  for k in levels:
    f = bands[k - 1][[0, orients // 2]]
    block = pool * 2**(top - k)
    parts.append((k, f, block, f.shape[1] // block, f.shape[2] // block))
  gh = min(p[3] for p in parts)
  gw = min(p[4] for p in parts)
  refs = {}
  d = np.empty((t, 2, gh, gw))
  wt = np.empty_like(d)
  for i in range(t):
    spectrum = np.fft.fft2(frames[i])
    num = np.zeros((2, gh, gw))
    den = np.zeros((2, gh, gw))
    for k, f, block, bh, bw in parts:
      hk, wk = f.shape[1:]
      c = np.fft.ifft2(
          spectrum[np.ix_(crop_index(h, hk), crop_index(w, wk))][None] * f)
      ref = refs.setdefault(k, c)
      disp = -np.angle(c * np.conj(ref)) / (2 * pi * 0.5 * 2.0**-k)
      # Undo the amplitude gain that the cropped inverse FFT adds.
      wgt = np.abs(c)**2 * (hk * wk / (h * w))**2

      def blocks(a):
        a = a[:, :bh * block, :bw * block]
        return a.reshape(2, bh, block, bw, block).mean(axis=(2, 4))[:, :gh, :gw]

      num += blocks(disp * wgt)
      den += blocks(wgt)
    d[i] = num / (den + 1e-30)
    wt[i] = den
  return d, wt
