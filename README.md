# MasteringAU — mastering Audio Unit (AUv3) for Logic Pro

A complete stereo mastering chain as an AUv3 audio unit, plus a portable,
heavily unit-tested C++ DSP core and an offline renderer.

```
input gain → HP filter → mono-low → 6-band parametric EQ → M/S width →
4-band multiband compressor (LR4 crossovers, stereo-linked) →
4x-oversampled saturator (Clean / Tape / Tube) →
true-peak lookahead limiter (4x oversampled detection, stereo-linked) →
output trim → TPDF dither (24-bit)
```

Meters (render-thread, BS.1770-4 / EBU R128): integrated / short-term /
momentary LUFS, loudness range (LRA), 4x-oversampled true peak, limiter gain
reduction, per-band gain reduction, and a 4096-point FFT spectrum analyzer.

## Layout

```
Source/DSP/       portable DSP core (no Apple deps) — builds/tests anywhere
  Parameters.h    all 74 parameters: ids, ranges, defaults, groups (shared with the AU)
  Biquad.h        RBJ peaking/shelves/LP/HP designs (double-precision state)
  Fir.h           4x polyphase Kaiser FIR resampler (193 taps, ~90 dB stopband)
  EQ.h            6-band parametric EQ
  Crossover.h     Linkwitz-Riley-4 (sums flat to 0.000 dB, tested)
  Compressor.h    feed-forward RMS detector, soft knee, attack/release, makeup
  Multiband.h     4-band compressor over 3 LR4 crossovers, per-channel filters
  Saturator.h     4x-oversampled waveshapers, unity small-signal gain
  Limiter.h       true-peak limiter, gain applied in the 4x domain with a
                  pointwise clamp + 0.5 dB internal margin (see below)
  LoudnessMeter.h BS.1770 K-weighting from the standard's design equations,
                  400 ms blocks / 75% overlap, absolute + relative gating, LRA
  Analyzer.h      FFT spectrum meter + TPDF dither
  Engine.h        the chain, parameter smoothing (5 ms), latency reporting
  Presets.h       factory presets (shared with AU + offline renderer)
Source/Plugin/    AUv3 wrapper for Logic (macOS-only, needs Xcode)
  MasteringAU.mm  AUAudioUnit subclass: buses, parameter tree (incl. read-only
                  "Meters" parameters), factory presets, internalRenderBlock
                  with pullInputBlock driving the engine, latency
  Info.plist      AUv3 component registration (aufx / MstA / Vibe)
project.yml       XcodeGen spec for the .appex target
Tests/test_main.cpp  738-check DSP test suite (runs on Linux)
Tools/            offline_render: master a WAV with a factory preset
CMakeLists.txt    builds dsp_tests + offline_render on any platform
```

## Build & test the DSP core (any platform, incl. Linux CI)

```
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build        # or ./build/dsp_tests
```

Latest run: **738 passed, 0 failed**, clean under ASan/UBSan. Highlights:

- K-weighting coefficients match the published BS.1770 48 kHz values to 1e-9;
  stereo −20 dBFS 1 kHz sine reads −20.04 LUFS integrated (formula-exact).
- LR4 crossovers sum flat within 0.000 dB; resampler round-trip −94.9 dB,
  alias suppression > 100 dB.
- Compressor steady state matches the gain computer (12 dB over, ratio 4 →
  9.0 dB GR within 0.4 dB); attack/release timing verified.
- True-peak limiter: worst oversampled peak over full sine sweep 20 Hz–19 kHz,
  0 dBFS noise and impulse trains stays ≤ ceiling (sweep −0.98 dBTP at a
  −1.0 dBTP ceiling; noise −1.29 dBTP), quiet signals pass at −142 dB.
- Full-chain: bit-exact bypass, EQ/width/mono-low verified, no zipper noise on
  +24 dB gain jumps, fuzz (random params × random input at 44.1/48/96 kHz)
  finite and ceiling-compliant, ~18× realtime on a 5-core Linux VM.

## Offline renderer

```
./build/offline_render in.wav out.wav [presetIndex] [--float]
```

Prints integrated/short-term LUFS, LRA, true peak and max gain reduction.
Useful for A/B renders and CI regression.

## Build the Audio Unit for Logic (macOS)

The AU shell targets Apple's AUv3 APIs and must be compiled with Xcode on a
Mac (this sandbox is Linux, so the DSP it wraps is what is test-verified
here — 738 checks; the thin AU adapter follows Apple's documented AUv3
patterns and should be compile-checked on first Xcode build):

```
xcodegen generate            # Ventura: download the XcodeGen 2.42.0 release
                             # zip, `sudo mv` the bin/ + share/ folders into
                             # /usr/local (Homebrew no longer supports 13.x)
open MasteringAU.xcodeproj
# Product ▸ Build (target MasteringAU, scheme MasteringAU), then Product ▸
# Archive-free install: copy the built .appex (see below)
```

Logic renders the parameter tree in its generic AU view; the read-only
**Meters** parameter group (momentary/short-term/integrated LUFS, LRA,
true peak, limiter and per-band GR) shows live levels.

Install and rescan:

```
cp -R build/Release/MasteringAU.appex ~/Library/Audio/AudioUnits/Components/
killall -9 AudioComponentRegistrar   # or just restart Logic
```

Open Logic Pro → Audio FX slot on a stereo bus/track →
**Audio FX ▸ Vibe ▸ MasteringAU**. Factory presets: Init, Streaming −14 LUFS,
Loud −9 LUFS, Air & Warmth, Vinyl Prep. The plugin reports its latency
(limiter lookahead + saturator FIR delay) to the host for compensation.

Component: type `aufx` (effect), subtype `MstA`, manufacturer `Vibe`,
stereo or mono in/out, float32, any sample rate, processes in place.

## Notes / design decisions

- **True-peak limiter**: detection and gain application happen in a 4x
  oversampled domain with a pointwise clamp `g ≤ ceiling/|x|`, so the
  oversampled output cannot exceed the ceiling; a 0.5 dB internal margin
  keeps the *measured* true peak of the base-rate output at or below the
  user ceiling even on adversarial full-scale noise (decimation filter
  stopband is finite). Latency = lookahead (default 5 ms), reported to host.
- **Multiband**: per-channel crossover instances (shared filter state between
  L/R would contaminate channels — caught by tests); LR4 bands sum flat.
- **Loudness meter**: K-weighting computed from BS.1770 design equations for
  any sample rate; 400 ms blocks with 75% overlap; absolute gate −70 LUFS and
  relative gate −10 LU; LRA = P95−P10 of 3 s short-term values.
- **Parameter changes** are smoothed (5 ms one-pole) for gain-type params;
  filter coefficients update at block boundaries.
- **Dither**: TPDF at 24-bit LSB, on by default (harmless in float32 hosts,
  correct when bouncing to integer).
