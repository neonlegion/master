// MasteringAU DSP test suite — runs on any platform (Linux CI included).
#include "../Source/DSP/dsp.h"
#include "../Source/DSP/Parameters.h"
#include "../Source/DSP/Biquad.h"
#include "../Source/DSP/Fir.h"
#include "../Source/DSP/EQ.h"
#include "../Source/DSP/Crossover.h"
#include "../Source/DSP/Compressor.h"
#include "../Source/DSP/Multiband.h"
#include "../Source/DSP/Saturator.h"
#include "../Source/DSP/Limiter.h"
#include "../Source/DSP/LoudnessMeter.h"
#include "../Source/DSP/Analyzer.h"
#include "../Source/DSP/Engine.h"

#include <cstdio>
#include <cmath>
#include <vector>
#include <random>
#include <string>
#include <chrono>
#include <algorithm>

using namespace mast;

static int g_pass = 0, g_fail = 0;
static void check(bool cond, const char* msg) {
    if (cond) { ++g_pass; }
    else { ++g_fail; printf("  FAIL: %s\n", msg); }
}
static void checkNear(double a, double b, double tol, const char* msg) {
    if (std::fabs(a - b) <= tol) { ++g_pass; }
    else { ++g_fail; printf("  FAIL: %s (got %.6f, want %.6f +/- %.6f)\n", msg, a, b, tol); }
}

static double sineAmp(double f, double fs, int n, double amp, std::vector<float>& out, double phase0 = 0.0) {
    out.resize(n);
    for (int i = 0; i < n; ++i) out[i] = (float)(amp * std::sin(2.0 * kPi * f * i / fs + phase0));
    return amp;
}

static double rmsDb(const std::vector<float>& v, int skip) {
    double s = 0;
    int n = (int)v.size() - skip;
    for (int i = skip; i < (int)v.size(); ++i) s += (double)v[i] * v[i];
    return 10.0 * std::log10(s / std::max(1, n) + 1e-30);
}

static bool allFinite(const std::vector<float>& v) {
    for (float x : v) if (!std::isfinite(x)) return false;
    return true;
}

// Measure gain (dB) of a per-sample processor at frequency f.
template <typename F>
static double measureGainDb(F&& process, double f, double fs, double amp = 0.5) {
    const int n = (int)fs; // 1 s
    std::vector<float> in, out;
    sineAmp(f, fs, n, amp, in);
    out.resize(n);
    for (int i = 0; i < n; ++i) out[i] = process(in[i]);
    double inDb = rmsDb(in, n / 2);
    double outDb = rmsDb(out, n / 2);
    return outDb - inDb;
}

// ---------------------------------------------------------------- tests ----

static void testParamTable() {
    printf("[param table]\n");
    const ParamDesc* d = paramDescs();
    check((int)P_Count == 74, "P_Count == 74");
    std::vector<std::string> ids;
    for (uint32_t i = 0; i < P_Count; ++i) {
        check(d[i].minV < d[i].maxV, "range sane");
        check(d[i].defV >= d[i].minV && d[i].defV <= d[i].maxV, "default in range");
        ids.push_back(d[i].id);
    }
    std::sort(ids.begin(), ids.end());
    check(std::adjacent_find(ids.begin(), ids.end()) == ids.end(), "param ids unique");
    ParamValues pv;
    checkNear(pv.get(P_LimCeiling), -1.0, 1e-6, "default ceiling -1 dBTP");
    checkNear(pv.get(P_LimEnable), 1.0, 1e-6, "limiter on by default");
}

static void testKWeightingCoeffs() {
    printf("[K-weighting vs published BS.1770 48k coefficients]\n");
    KWeighting k;
    k.design(48000.0);
    checkNear(k.shelf.b0, 1.53512485958697, 1e-9, "shelf b0");
    checkNear(k.shelf.b1, -2.69169618940638, 1e-9, "shelf b1");
    checkNear(k.shelf.b2, 1.19839281085285, 1e-9, "shelf b2");
    checkNear(k.shelf.a1, -1.69065929318241, 1e-9, "shelf a1");
    checkNear(k.shelf.a2, 0.73248077421585, 1e-9, "shelf a2");
    // RLB high-pass published (48k): a = {1, -1.99004745483398, 0.99007225036621}
    checkNear(k.hpf.a1, -1.99004745483398, 1e-9, "hpf a1");
    checkNear(k.hpf.a2, 0.99007225036621, 1e-9, "hpf a2");
    // Combined K-weighting magnitude at 1 kHz should be ~0 dB by design.
    double w = 2.0 * kPi * 1000.0 / 48000.0;
    double m = k.shelf.magnitudeAt(w) * k.hpf.magnitudeAt(w);
    printf("  K-weighting gain at 1 kHz: %.4f dB\n", 20.0 * std::log10(m));
    // The published BS.1770 K-weighting has ~+0.65 dB gain at 1 kHz.
    checkNear(20.0 * std::log10(m), 0.65, 0.1, "K-weighting gain at 1 kHz matches published design");
}

static void testBiquadDesigns() {
    printf("[biquad designs]\n");
    const double fs = 48000.0;
    Biquad bq;
    designPeaking(bq, fs, 1000.0, 6.0, 1.0);
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 1000.0 / fs)), 6.0, 0.05, "peaking +6 dB at f0");
    checkNear(20.0 * std::log10(bq.magnitudeAt(0.0)), 0.0, 0.02, "peaking unity at DC");
    checkNear(20.0 * std::log10(bq.magnitudeAt(kPi * 0.999)), 0.0, 0.05, "peaking unity near Nyquist");

    designLowShelf(bq, fs, 100.0, 6.0, 1.0);
    checkNear(20.0 * std::log10(bq.magnitudeAt(0.0)), 6.0, 0.05, "low shelf +6 dB at DC");
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 10000.0 / fs)), 0.0, 0.05, "low shelf unity at HF");

    designHighShelf(bq, fs, 8000.0, -6.0, 1.0);
    checkNear(20.0 * std::log10(bq.magnitudeAt(kPi * 0.999)), -6.0, 0.05, "high shelf -6 dB at Nyquist");
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 100.0 / fs)), 0.0, 0.05, "high shelf unity at LF");

    designLowPass(bq, fs, 1000.0, 0.7071);
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 1000.0 / fs)), -3.0103, 0.05, "LP -3.01 dB at fc");
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 10000.0 / fs)), -40.0, 6.0, "LP 2nd-order stopband at 10x fc");

    designHighPass(bq, fs, 100.0, 0.7071);
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 100.0 / fs)), -3.0103, 0.05, "HP -3.01 dB at fc");
    checkNear(20.0 * std::log10(bq.magnitudeAt(2 * kPi * 10.0 / fs)), -40.0, 8.0, "HP stopband");
}

static void testCrossoverFlatness() {
    printf("[LR4 crossover sums flat]\n");
    const double fs = 48000.0;
    for (double fc : {100.0, 1000.0, 5000.0}) {
        LinkwitzRiley4 x;
        x.setFrequency(fs, fc);
        double maxDev = 0.0;
        for (int i = 0; i <= 200; ++i) {
            double f = 20.0 * std::pow(20000.0 / 20.0, i / 200.0);
            double w = 2.0 * kPi * f / fs;
            // sum LP+HP magnitude via complex evaluation of each path
            auto mag = [&](Biquad& b) { return b.magnitudeAt(w); };
            // compute complex sum properly:
            auto H = [&](Biquad& b) {
                double cw = std::cos(w), sw = std::sin(w), cw2 = std::cos(2 * w), sw2 = std::sin(2 * w);
                double hr = b.b0 + b.b1 * cw + b.b2 * cw2, hi = -(b.b1 * sw + b.b2 * sw2);
                double ar = 1 + b.a1 * cw + b.a2 * cw2, ai = -(b.a1 * sw + b.a2 * sw2);
                double den = ar * ar + ai * ai;
                return std::complex<double>((hr * ar + hi * ai) / den, (hi * ar - hr * ai) / den);
            };
            // two cascaded biquads per side
            LinkwitzRiley4 probe;
            probe.setFrequency(fs, fc);
            // rebuild coefficients manually: LP path = lp2*lp1 etc. Access via process on impulse is easier:
            (void)mag; (void)H; (void)probe;
            // impulse-response based sum: feed unit impulse, sum low+high impulse responses
            std::vector<float> imp(4096, 0.0f);
            imp[0] = 1.0f;
            std::vector<float> lo(4096), hi(4096);
            for (int k = 0; k < 4096; ++k) probe.process(imp[k], lo[k], hi[k]);
            // DFT of sum at w
            std::complex<double> acc(0, 0);
            for (int k = 0; k < 4096; ++k) acc += std::complex<double>(lo[k] + hi[k], 0) * std::exp(std::complex<double>(0, -w * k));
            double m = std::abs(acc);
            maxDev = std::max(maxDev, std::fabs(20.0 * std::log10(std::max(m, 1e-12))));
        }
        printf("  fc=%.0f Hz: max |sum| deviation %.4f dB\n", fc, maxDev);
        check(maxDev < 0.05, "LR4 sum flat within 0.05 dB");
    }
}

static void testResampler() {
    printf("[polyphase 4x resampler]\n");
    const double fs = 48000.0;
    Polyphase4 os;
    // Roundtrip: base signal with tones below 0.45*fs
    std::vector<float> in((int)fs);
    std::mt19937 rng(42);
    for (int i = 0; i < (int)in.size(); ++i) {
        in[i] = (float)(0.3 * std::sin(2 * kPi * 1000 * i / fs)
                      + 0.2 * std::sin(2 * kPi * 7000 * i / fs + 1.0)
                      + 0.1 * std::sin(2 * kPi * 18000 * i / fs + 2.0));
    }
    std::vector<float> up(4 * in.size()), down(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        float o[4];
        os.upsample(in[i], o);
        for (int p = 0; p < 4; ++p) up[4 * i + p] = o[p];
    }
    int oi = 0;
    for (size_t k = 0; k < up.size(); ++k) {
        float y;
        if (os.downsample(up[k], y)) down[oi++] = y;
    }
    check(oi == (int)in.size(), "downsample count matches");
    // skip transient (group delay 2*24 samples)
    int skip = 64;
    double err = 0, sig = 0;
    for (int i = skip; i < (int)in.size(); ++i) {
        double d = down[i] - in[i - 0]; // aligned: delay compensated? no — down[i] lags in[i] by 48
        (void)d;
        double dd = down[i] - in[i - 48 >= 0 ? i - 48 : 0];
        err += dd * dd;
        sig += in[i] * in[i];
    }
    double errDb = 10 * std::log10(err / sig + 1e-30);
    printf("  roundtrip error: %.1f dB (incl. 48-sample delay alignment)\n", errDb);
    check(errDb < -70.0, "upsample->downsample roundtrip error < -70 dB");

    // Alias rejection: over-rate tone at 30 kHz (aliases to 18 kHz at 48k) must be suppressed.
    Polyphase4 dn;
    std::vector<float> x4(4 * 4800);
    for (int m = 0; m < (int)x4.size(); ++m) x4[m] = (float)std::sin(2 * kPi * 30000.0 * m / 192000.0);
    std::vector<float> out;
    for (float s : x4) { float y; if (dn.downsample(s, y)) out.push_back(y); }
    double r = rmsDb(out, 100);
    printf("  30 kHz over-rate tone after 4x decimation: %.1f dBFS (alias)\n", r);
    check(r < -60.0, "decimation alias suppression > 60 dB");
}

static void testCompressor() {
    printf("[compressor math]\n");
    const double fs = 48000.0;
    Compressor c;
    c.setSampleRate(fs);
    // sine amplitude a -> RMS level = a/sqrt(2). Choose a = 1.0 -> level -3.01 dBFS.
    double levelDb = -3.0103;
    double thresh = levelDb - 12.0; // 12 dB over threshold
    c.configure(thresh, 4.0, 10.0, 100.0, 0.0);
    std::vector<float> in, out;
    sineAmp(1000.0, fs, (int)(2 * fs), 1.0, in);
    out.resize(in.size());
    for (size_t i = 0; i < in.size(); ++i) out[i] = c.process(in[i]);
    double outDb = rmsDb(out, (int)fs); // second second
    double expected = levelDb - 0.75 * 12.0; // slope (1-1/4) * over
    printf("  steady-state: got %.3f dB, expected %.3f dB, GR %.2f dB\n", outDb, expected, c.gainReductionDb());
    checkNear(outDb, expected, 0.4, "compressor steady-state gain reduction");
    checkNear(c.gainReductionDb(), 9.0, 0.4, "GR = 9 dB for 12 dB over, ratio 4");

    // Attack timing: step from silence; GR should reach ~90% in about attack time.
    Compressor c2;
    c2.setSampleRate(fs);
    c2.configure(-20.0, 10.0, 20.0, 500.0, 0.0);
    std::vector<float> step((int)(0.2 * fs), 1.0f);
    std::vector<float> zeros((int)(0.2 * fs), 0.0f);
    std::vector<float> sig = zeros;
    sig.insert(sig.end(), step.begin(), step.end());
    std::vector<float> o(sig.size());
    for (size_t i = 0; i < sig.size(); ++i) o[i] = c2.process(sig[i]);
    int idx90 = -1;
    double finalGr = 0;
    for (size_t i = sig.size() - 1; i > sig.size() / 2; --i) { finalGr = c2.gainReductionDb(); break; }
    // re-run tracking GR
    Compressor c3;
    c3.setSampleRate(fs);
    c3.configure(-20.0, 10.0, 20.0, 500.0, 0.0);
    std::vector<double> grs(sig.size());
    for (size_t i = 0; i < sig.size(); ++i) { c3.process(sig[i]); grs[i] = c3.gainReductionDb(); }
    finalGr = grs.back();
    for (size_t i = (int)(0.2 * fs); i < sig.size(); ++i) {
        if (grs[i] >= 0.9 * finalGr) { idx90 = (int)(i - 0.2 * fs); break; }
    }
    double t90ms = idx90 / fs * 1000.0;
    printf("  attack 20 ms: 90%% GR reached at %.1f ms\n", t90ms);
    check(idx90 > 0 && t90ms < 80.0, "attack reaches 90% within 4x attack time");

    // Release timing
    Compressor c4;
    c4.setSampleRate(fs);
    c4.configure(-20.0, 10.0, 5.0, 100.0, 0.0);
    std::vector<float> sig2 = step;
    std::vector<float> zerosLong((int)(1.0 * fs), 0.0f);
    sig2.insert(sig2.end(), zerosLong.begin(), zerosLong.end());
    std::vector<double> grs2(sig2.size());
    for (size_t i = 0; i < sig2.size(); ++i) { c4.process(sig2[i]); grs2[i] = c4.gainReductionDb(); }
    double peakGr = *std::max_element(grs2.begin(), grs2.end());
    int idx10 = -1;
    for (size_t i = (int)(0.2 * fs); i < sig2.size(); ++i) {
        if (grs2[i] <= 0.1 * peakGr) { idx10 = (int)(i - 0.2 * fs); break; }
    }
    double t10ms = idx10 > 0 ? idx10 / fs * 1000.0 : 1e9;
    printf("  release 100 ms: 10%% GR at %.1f ms\n", t10ms);
    check(idx10 > 0 && t10ms < 500.0, "release decays within 5x release time");

    // Makeup and ratio=1 (no compression)
    Compressor c5;
    c5.setSampleRate(fs);
    c5.configure(-60.0, 1.0, 10.0, 100.0, 6.0);
    std::vector<float> s, so;
    sineAmp(1000.0, fs, 48000, 0.5, s);
    so.resize(s.size());
    for (size_t i = 0; i < s.size(); ++i) so[i] = c5.process(s[i]);
    checkNear(rmsDb(so, 24000) - rmsDb(s, 24000), 6.0, 0.1, "ratio 1 + makeup +6 dB = +6 dB out");
}

static void testLimiter() {
    printf("[true-peak limiter compliance]\n");
    const double fs = 48000.0;
    const double ceilingDb = -1.0;
    TruePeakLimiter lim;
    lim.setSampleRate(fs);
    lim.configure(ceilingDb, 5.0, 50.0);
    lim.setEnabled(true);
    check(lim.latencySamples() == (int)std::lround(0.005 * fs), "latency == lookahead");

    Polyphase4 tpProbe; // independent true-peak measurement
    // skip the first 20 ms (startup transient of the resampler/gain ramp)
    auto measureTP = [&](const std::vector<float>& v, int skipSamples = 960) {
        tpProbe.reset();
        double maxA = 0.0;
        for (size_t i = 0; i < v.size(); ++i) {
            float o[4];
            tpProbe.upsample(v[i], o);
            if ((int)i < skipSamples) continue;
            for (int p = 0; p < 4; ++p) maxA = std::max(maxA, std::fabs((double)o[p]));
        }
        return 20.0 * std::log10(std::max(maxA, 1e-12));
    };

    std::mt19937 rng(7);
    std::normal_distribution<float> nd(0.0f, 0.3f);
    double worstTP = -999.0;
    // sine sweep
    for (int f = 20; f <= 19000; f += 37) {
        std::vector<float> l, r;
        int n = 24000;
        l.resize(n); r.resize(n);
        for (int i = 0; i < n; ++i) {
            l[i] = (float)std::sin(2 * kPi * f * i / fs);
            r[i] = (float)std::sin(2 * kPi * f * i / fs + 0.7);
        }
        lim.reset();
        lim.processBlock(l.data(), r.data(), n);
        check(allFinite(l) && allFinite(r), "limiter output finite");
        worstTP = std::max(worstTP, measureTP(l));
        worstTP = std::max(worstTP, measureTP(r));
    }
    printf("  worst sine-sweep TP: %.3f dBTP (ceiling %.1f)\n", worstTP, ceilingDb);
    check(worstTP <= ceilingDb + 0.15, "sine sweep TP within ceiling + 0.15 dB");

    // noise at 0 dBFS peak
    {
        int n = 48000;
        std::vector<float> l(n), r(n);
        float maxA = 0;
        for (int i = 0; i < n; ++i) { l[i] = nd(rng); r[i] = nd(rng); maxA = std::max(maxA, std::max(std::fabs(l[i]), std::fabs(r[i]))); }
        for (int i = 0; i < n; ++i) { l[i] /= maxA; r[i] /= maxA; }
        lim.reset();
        lim.processBlock(l.data(), r.data(), n);
        double tp = std::max(measureTP(l), measureTP(r));
        printf("  0 dBFS noise TP: %.3f dBTP, GR max %.2f dB\n", tp, lim.gainReductionDb());
        check(tp <= ceilingDb + 0.15, "noise TP within ceiling + 0.15 dB");
        check(allFinite(l) && allFinite(r), "noise output finite");
        check(lim.gainReductionDb() > 0.5, "limiter actually reduced gain on hot noise");
    }

    // impulses
    {
        int n = 48000;
        std::vector<float> l(n, 0.0f), r(n, 0.0f);
        for (int i = 0; i < n; i += 997) { l[i] = 1.0f; r[i] = -1.0f; }
        lim.reset();
        lim.processBlock(l.data(), r.data(), n);
        double tp = std::max(measureTP(l), measureTP(r));
        printf("  impulse train TP: %.3f dBTP\n", tp);
        check(tp <= ceilingDb + 0.15, "impulse TP within ceiling + 0.15 dB");
        check(allFinite(l) && allFinite(r), "impulse output finite");
    }

    // quiet signal must pass untouched (no gain reduction)
    {
        int n = 48000;
        std::vector<float> l, r;
        sineAmp(1000.0, fs, n, 0.1, l);
        r = l;
        std::vector<float> lc = l, rc = r;
        lim.reset();
        lim.processBlock(l.data(), r.data(), n);
        int skip = 2000;
        double err = 0, sig = 0;
        for (int i = skip; i < n - lim.latencySamples(); ++i) {
            double d = l[i] - lc[i - lim.latencySamples()];
            err += d * d; sig += (double)lc[i] * lc[i];
        }
        printf("  quiet passthrough error: %.1f dB\n", 10 * std::log10(err / sig + 1e-30));
        check(10 * std::log10(err / sig + 1e-30) < -90.0, "quiet signal passes with only latency shift");
    }
}

static void testSaturator() {
    printf("[saturator]\n");
    const double fs = 48000.0;
    Saturator sat;
    sat.setSampleRate(fs);
    sat.configure(true, 12.0, SatClean, 100.0);
    int n = 48000;
    std::vector<float> in, out;
    sineAmp(1000.0, fs, n, 0.5, in);
    out = in;
    sat.processBlock(out.data(), n);
    check(allFinite(out), "saturator output finite");
    double peak = 0;
    for (float x : out) peak = std::max(peak, (double)std::fabs(x));
    check(peak <= 1.0, "saturator output bounded by 1.0");
    // small signal should stay close to linear (drive normalized)
    Saturator sat2;
    sat2.setSampleRate(fs);
    sat2.configure(true, 3.0, SatClean, 100.0);
    std::vector<float> small, smallOut;
    sineAmp(1000.0, fs, n, 0.01, small);
    smallOut = small;
    sat2.processBlock(smallOut.data(), n);
    double err = 0, sig = 0;
    for (int i = 2000; i < n; ++i) {
        double d = smallOut[i] - small[i - Saturator::kLatency];
        err += d * d; sig += (double)small[i] * small[i];
    }
    printf("  small-signal (-40 dBFS, drive 3 dB) linearity error: %.1f dB\n", 10 * std::log10(err / sig + 1e-30));
    check(10 * std::log10(err / sig + 1e-30) < -60.0, "small signal unity gain (near-linear)");
    // THD at moderate drive
    Saturator sat3;
    sat3.setSampleRate(fs);
    sat3.configure(true, 12.0, SatClean, 100.0);
    std::vector<float> s, so;
    sineAmp(1000.0, fs, 4 * 4096, 0.9, s);
    so = s;
    sat3.processBlock(so.data(), (int)so.size());
    SpectrumAnalyzer an;
    an.setSampleRate(fs);
    // feed settled output
    std::vector<float> tail(so.begin() + 2 * 4096, so.end());
    an.processBlock(tail.data(), (int)tail.size());
    check(an.ready(), "analyzer ready");
    const auto& spec = an.spectrumDb();
    int bin1k = (int)std::lround(1000.0 / fs * SpectrumAnalyzer::kFFT);
    double fund = spec[bin1k];
    double harm = -120;
    for (int h = 2; h <= 5; ++h) harm = std::max(harm, (double)spec[bin1k * h]);
    printf("  drive 12 dB @0.9 FS: fundamental %.1f dB, worst harmonic %.1f dB (THD-ish %.1f dB)\n",
           fund, harm, harm - fund);
    check(harm - fund < -8.0, "saturation adds harmonics (expected)");
    check(harm - fund > -70.0, "harmonics not absurd");
}

static void testLoudnessMeter() {
    printf("[BS.1770 loudness meter]\n");
    const double fs = 48000.0;
    // stereo 1 kHz sine, -20 dBFS per channel
    double amp = std::pow(10.0, -20.0 / 20.0);
    KWeighting k;
    k.design(fs);
    double w = 2.0 * kPi * 1000.0 / fs;
    double H = k.shelf.magnitudeAt(w) * k.hpf.magnitudeAt(w);
    double expectedStereo = -0.691 + 10.0 * std::log10(2.0 * H * H * amp * amp / 2.0);
    double expectedMono = expectedStereo - 10.0 * std::log10(2.0);
    printf("  expected: stereo %.3f LUFS, mono %.3f LUFS (K(1k)=%.4f dB)\n",
           expectedStereo, expectedMono, 20 * std::log10(H));

    LoudnessMeter m;
    m.setSampleRate(fs);
    int n = (int)(5 * fs);
    std::vector<float> l(n), r(n);
    for (int i = 0; i < n; ++i) {
        l[i] = (float)(amp * std::sin(2 * kPi * 1000 * i / fs));
        r[i] = l[i];
    }
    for (int i = 0; i < n; i += 512) {
        const float* ch[2] = {l.data() + i, r.data() + i};
        m.processBlock(ch, 2, std::min(512, n - i));
    }
    printf("  meter: integrated %.3f LUFS, momentary %.3f, short-term %.3f\n",
           m.integratedLUFS(), m.momentaryLUFS(), m.shortTermLUFS());
    checkNear(m.integratedLUFS(), expectedStereo, 0.15, "stereo integrated LUFS");
    checkNear(m.momentaryLUFS(), expectedStereo, 0.15, "stereo momentary LUFS");
    checkNear(m.shortTermLUFS(), expectedStereo, 0.15, "stereo short-term LUFS");

    LoudnessMeter m2;
    m2.setSampleRate(fs);
    for (int i = 0; i < n; i += 512) {
        const float* chm[1] = {l.data() + i};
        m2.processBlock(chm, 1, std::min(512, n - i));
    }
    printf("  mono integrated: %.3f LUFS (expected %.3f)\n", m2.integratedLUFS(), expectedMono);
    checkNear(m2.integratedLUFS(), expectedMono, 0.15, "mono integrated LUFS");

    // Gating: prepend 10 s of silence -> integrated must not move much.
    LoudnessMeter m3;
    m3.setSampleRate(fs);
    int nsil = (int)(10 * fs);
    std::vector<float> z(nsil, 0.0f);
    for (int i = 0; i < nsil; i += 512) {
        const float* zch[2] = {z.data() + i, z.data() + i};
        m3.processBlock(zch, 2, std::min(512, nsil - i));
    }
    for (int i = 0; i < n; i += 512) {
        const float* ch[2] = {l.data() + i, r.data() + i};
        m3.processBlock(ch, 2, std::min(512, n - i));
    }
    printf("  with 10 s leading silence: integrated %.3f LUFS\n", m3.integratedLUFS());
    checkNear(m3.integratedLUFS(), expectedStereo, 0.2, "absolute gate rejects silence");

    // LRA: alternate loud/quiet 3 s segments
    LoudnessMeter m4;
    m4.setSampleRate(fs);
    double ampLoud = std::pow(10.0, -14.0 / 20.0);
    double ampQuiet = ampLoud * std::pow(10.0, -16.0 / 20.0);
    std::vector<float> seg;
    for (int s = 0; s < 6; ++s) {
        double a = (s % 2 == 0) ? ampLoud : ampQuiet;
        int sn = (int)(3 * fs);
        for (int i = 0; i < sn; ++i)
            seg.push_back((float)(a * std::sin(2 * kPi * 1000 * (s * sn + i) / fs)));
    }
    for (size_t i = 0; i < seg.size(); i += 512) {
        const float* sch[2] = {seg.data() + i, seg.data() + i};
        m4.processBlock(sch, 2, (int)std::min<size_t>(512, seg.size() - i));
    }
    printf("  LRA of 16 LU alternating program: %.2f LU (ST now %.2f)\n", m4.loudnessRange(), m4.shortTermLUFS());
    check(m4.loudnessRange() > 5.0 && m4.loudnessRange() < 24.0, "LRA plausible for 16 LU swings");

    // True peak: intersample peak detection. A sine at fs/3 has base samples
    // peaking at only sqrt(3)/2 (-1.25 dBFS) while its true peak is 0 dBFS.
    {
        double fTP = fs / 3.0;
        int n = 4800;
        std::vector<float> base(n);
        for (int i = 0; i < n; ++i) base[i] = (float)std::sin(2 * kPi * fTP * i / fs);
        double basePeak = 0;
        for (float x : base) basePeak = std::max(basePeak, (double)std::fabs(x));
        LoudnessMeter m5;
        m5.setSampleRate(fs);
        for (int i = 0; i < n; i += 512) {
            const float* tch[1] = {base.data() + i};
            m5.processBlock(tch, 1, std::min(512, n - i));
        }
        printf("  fs/3 sine: sample peak %.3f dBFS, meter TP (last block) %.3f dBTP\n",
               20 * std::log10(basePeak), m5.truePeakDbTP());
        checkNear(m5.truePeakDbTP(), 0.0, 0.35, "TP meter reads true peak");
        check(20 * std::log10(basePeak) < m5.truePeakDbTP() - 1.0, "TP exceeds sample peak (intersample caught)");
    }
}

static void testAnalyzer() {
    printf("[spectrum analyzer]\n");
    const double fs = 48000.0;
    SpectrumAnalyzer an;
    an.setSampleRate(fs);
    std::vector<float> s;
    sineAmp(1000.0, fs, SpectrumAnalyzer::kFFT * 3, std::pow(10.0, -6.0 / 20.0), s);
    an.processBlock(s.data(), (int)s.size());
    check(an.ready(), "analyzer produced a frame");
    const auto& spec = an.spectrumDb();
    int peakBin = (int)(std::max_element(spec.begin(), spec.end()) - spec.begin());
    int expectBin = (int)std::lround(1000.0 / fs * SpectrumAnalyzer::kFFT);
    printf("  1 kHz sine peak bin %d (expect %d), level %.2f dB\n", peakBin, expectBin, spec[peakBin]);
    check(std::abs(peakBin - expectBin) <= 1, "analyzer peak at 1 kHz bin");
    checkNear(spec[peakBin], -6.0, 1.0, "analyzer level ~ -6 dBFS");
}

static void testEngineBypassAndStages() {
    printf("[engine: bypass, EQ, width, mono-low]\n");
    const double fs = 48000.0;

    // Bypass bit-exact
    {
        MasteringEngine e;
        e.setSampleRate(fs);
        e.store().set(P_Bypass, 1.0f);
        e.store().set(P_LimEnable, 0.0f);
        e.store().set(P_DitherEnable, 0.0f);
        int n = 4096;
        std::vector<float> l(n), r(n), l0, r0;
        std::mt19937 rng(3);
        std::uniform_real_distribution<float> u(-0.8f, 0.8f);
        for (int i = 0; i < n; ++i) { l[i] = u(rng); r[i] = u(rng); }
        l0 = l; r0 = r;
        float* io[2] = {l.data(), r.data()};
        e.process(io, 2, n);
        bool exact = true;
        for (int i = 0; i < n; ++i) if (l[i] != l0[i] || r[i] != r0[i]) exact = false;
        check(exact, "bypass is bit-exact");
    }

    // EQ band: +6 dB peak at 1 kHz on band index 1 (second band)
    {
        MasteringEngine e;
        e.setSampleRate(fs);
        e.store().set(P_LimEnable, 0.0f);
        e.store().set(P_DitherEnable, 0.0f);
        e.store().set(eqParam(1, EqEnable), 1.0f);
        e.store().set(eqParam(1, EqType), (float)EqPeak);
        e.store().set(eqParam(1, EqFreq), 1000.0f);
        e.store().set(eqParam(1, EqGain), 6.0f);
        e.store().set(eqParam(1, EqQ), 2.0f);
        auto gainAt = [&](double f) {
            int n = (int)fs;
            std::vector<float> in, out, ref;
            sineAmp(f, fs, n, 0.4, in);
            sineAmp(f, fs, n, 0.4, ref);
            out = in;
            float* io1[1] = {out.data()};
            e.process(io1, 1, n);
            return rmsDb(out, n / 2) - rmsDb(ref, n / 2);
        };
        double g1k = gainAt(1000.0);
        double g100 = gainAt(100.0);
        double g10k = gainAt(10000.0);
        printf("  EQ +6 dB @1k Q2: gain@1k=%.2f dB, @100Hz=%.2f dB, @10k=%.2f dB\n", g1k, g100, g10k);
        checkNear(g1k, 6.0, 0.5, "engine EQ +6 dB at 1 kHz");
        checkNear(g100, 0.0, 0.4, "engine EQ ~0 dB at 100 Hz");
        checkNear(g10k, 0.0, 0.4, "engine EQ ~0 dB at 10 kHz");
    }

    // Width: pure side signal, +6 dB width doubles side
    {
        MasteringEngine e;
        e.setSampleRate(fs);
        e.store().set(P_LimEnable, 0.0f);
        e.store().set(P_DitherEnable, 0.0f);
        e.store().set(P_Width, 6.0f);
        int n = 48000;
        std::vector<float> l(n), r(n);
        for (int i = 0; i < n; ++i) {
            float s = (float)(0.4 * std::sin(2 * kPi * 1000 * i / fs));
            l[i] = s; r[i] = -s; // pure side
        }
        float* io[2] = {l.data(), r.data()};
        e.process(io, 2, n);
        // pure side s; side' = s * 10^(6/20) = 2s; L = mid + side' = 2s
        std::vector<float> sideRef;
        sineAmp(1000.0, fs, n, 0.4, sideRef);
        double sideDb = rmsDb(sideRef, n / 2);
        printf("  width +6 dB on pure side: out RMS %.2f dB, side ref %.2f dB (+6.02 expected)\n",
               rmsDb(l, n / 2), sideDb);
        checkNear(rmsDb(l, n / 2), sideDb + 6.0206, 0.5, "width +6 dB doubles side signal");
    }

    // Mono-low: out-of-phase 50 Hz becomes mono
    {
        auto run = [&](bool monoOn) {
            MasteringEngine e;
            e.setSampleRate(fs);
            e.store().set(P_LimEnable, 0.0f);
            e.store().set(P_DitherEnable, 0.0f);
            e.store().set(P_MonoLowEnable, monoOn ? 1.0f : 0.0f);
            e.store().set(P_MonoLowFreq, 100.0f);
            int n = 48000;
            std::vector<float> l(n), r(n);
            for (int i = 0; i < n; ++i) {
                l[i] = (float)(0.3 * std::sin(2 * kPi * 50 * i / fs) + 0.3 * std::sin(2 * kPi * 1000 * i / fs));
                r[i] = (float)(-0.3 * std::sin(2 * kPi * 50 * i / fs) + 0.3 * std::sin(2 * kPi * 1000 * i / fs));
            }
            float* io[2] = {l.data(), r.data()};
            e.process(io, 2, n);
            // lowpass the difference signal at 150 Hz with a test biquad
            Biquad lp;
            designLowPass(lp, fs, 150.0, 0.7071);
            double e2 = 0;
            int cnt = 0;
            for (int i = 24000; i < n; ++i) {
                float d = lp.process(l[i] - r[i]);
                e2 += (double)d * d; ++cnt;
            }
            return 10.0 * std::log10(e2 / cnt + 1e-30);
        };
        double without = run(false);
        double with = run(true);
        printf("  L-R below 150 Hz: without mono-low %.1f dB, with %.1f dB\n", without, with);
        check(with < without - 20.0, "mono-low kills out-of-phase bass");
    }
}

static void testEngineFullChain() {
    printf("[engine: full chain smoke + stability + perf]\n");
    const double fs = 48000.0;
    MasteringEngine e;
    e.setSampleRate(fs);
    e.store().set(P_LimCeiling, -1.0f);
    e.store().set(P_SatEnable, 1.0f);
    e.store().set(P_SatDrive, 6.0f);
    e.store().set(eqParam(0, EqEnable), 1.0f);
    e.store().set(eqParam(0, EqType), (float)EqLowShelf);
    e.store().set(eqParam(0, EqFreq), 80.0f);
    e.store().set(eqParam(0, EqGain), 2.0f);
    e.store().set(mbParam(1, MbEnable), 1.0f);
    e.store().set(mbParam(1, MbThresh), -18.0f);
    e.store().set(mbParam(1, MbRatio), 4.0f);

    int n = (int)(5 * fs);
    std::vector<float> l(n), r(n);
    std::mt19937 rng(11);
    std::uniform_real_distribution<float> u(-1.0f, 1.0f);
    for (int i = 0; i < n; ++i) {
        double t = i / fs;
        double am = 0.55 + 0.35 * std::sin(2 * kPi * 0.25 * t);
        l[i] = (float)(am * (0.5 * std::sin(2 * kPi * 60 * t) + 0.3 * std::sin(2 * kPi * 220 * t + 1)
                            + 0.2 * std::sin(2 * kPi * 1000 * t + 2) + 0.1 * u(rng)));
        r[i] = (float)(am * (0.5 * std::sin(2 * kPi * 60 * t + 0.3) + 0.3 * std::sin(2 * kPi * 220 * t + 1.3)
                            + 0.2 * std::sin(2 * kPi * 1000 * t + 2.2) + 0.1 * u(rng)));
    }
    double inPeak = 0;
    for (int i = 0; i < n; ++i) inPeak = std::max(inPeak, (double)std::max(std::fabs(l[i]), std::fabs(r[i])));

    auto t0 = std::chrono::steady_clock::now();
    const int block = 512;
    for (int i = 0; i < n; i += block) {
        float* io[2] = {l.data() + i, r.data() + i};
        e.process(io, 2, std::min(block, n - i));
    }
    auto t1 = std::chrono::steady_clock::now();
    double secs = std::chrono::duration<double>(t1 - t0).count();
    printf("  processed 5 s stereo @48k in %.1f ms (%.1fx realtime)\n", secs * 1e3, 5.0 / secs);

    check(allFinite(l) && allFinite(r), "full chain output finite");
    Polyphase4 probe;
    double tp = 0;
    int si = 0;
    for (float x : l) { float o[4]; probe.upsample(x, o); if (++si > 960) for (int p = 0; p < 4; ++p) tp = std::max(tp, (double)std::fabs(o[p])); }
    for (float x : r) { float o[4]; probe.upsample(x, o); for (int p = 0; p < 4; ++p) tp = std::max(tp, (double)std::fabs(o[p])); }
    double tpDb = 20 * std::log10(tp);
    printf("  output true peak: %.3f dBTP, limiter GR %.2f dB, integrated %.2f LUFS, LRA %.2f LU\n",
           tpDb, e.meters().limiterGRDb, e.meters().integratedLUFS, e.meters().loudnessRangeLU);
    check(tpDb <= -1.0 + 0.15, "full chain TP within ceiling");
    check(e.meters().integratedLUFS > -60.0f && e.meters().integratedLUFS < 0.0f, "integrated LUFS plausible");
    check(secs < 2.0, "performance: 5 s rendered in < 2 s (>2.5x realtime)");
    printf("  engine latency: %.0f samples\n", e.latencySamples());
    check(e.latencySamples() > 0.0, "latency reported (lookahead + sat)");
}

static void testFuzz() {
    printf("[fuzz: random params, random input, multiple sample rates]\n");
    for (double fs : {44100.0, 48000.0, 96000.0}) {
        std::mt19937 rng(123);
        MasteringEngine e;
        e.setSampleRate(fs);
        std::uniform_real_distribution<float> u(-1.0f, 1.0f);
        const ParamDesc* d = paramDescs();
        for (uint32_t i = 0; i < P_Count; ++i) {
            float v = u(rng) * (d[i].maxV - d[i].minV) + d[i].minV;
            e.store().set(i, v);
        }
        e.store().set(P_LimEnable, 1.0f);
        e.store().set(P_LimCeiling, -0.5f);
        e.store().set(P_Bypass, 0.0f);
        int n = (int)(2 * fs);
        std::vector<float> l(n), r(n);
        for (int i = 0; i < n; ++i) {
            l[i] = u(rng) * (i % 977 == 0 ? 1.0f : 0.9f);
            r[i] = u(rng) * (i % 1301 == 0 ? 1.0f : 0.9f);
        }
        for (int i = 0; i < n; i += 256) {
            float* io[2] = {l.data() + i, r.data() + i};
            e.process(io, 2, std::min(256, n - i));
        }
        bool ok = allFinite(l) && allFinite(r);
        Polyphase4 probe;
        double tp = 0;
        int si = 0;
        for (float x : l) { float o[4]; probe.upsample(x, o); if (++si > 960) for (int p = 0; p < 4; ++p) tp = std::max(tp, (double)std::fabs(o[p])); }
        for (float x : r) { float o[4]; probe.upsample(x, o); for (int p = 0; p < 4; ++p) tp = std::max(tp, (double)std::fabs(o[p])); }
        double tpDb = 20 * std::log10(tp);
        printf("  fs=%.0f: finite=%d TP=%.3f dBTP GR=%.2f\n", fs, (int)ok, tpDb, e.meters().limiterGRDb);
        check(ok, "fuzz output finite");
        check(tpDb <= -0.5 + 0.2, "fuzz TP within ceiling");
    }
}

static void testSmoothing() {
    printf("[param smoothing: no zipper noise]\n");
    const double fs = 48000.0;
    MasteringEngine e;
    e.setSampleRate(fs);
    e.store().set(P_LimEnable, 0.0f);
    e.store().set(P_DitherEnable, 0.0f);
    int n = 48000;
    std::vector<float> l(n, 0.5f), r(n, 0.5f);
    // jump input gain 0 -> +24 dB at halfway
    for (int i = 0; i < n / 2; i += 256) {
        float* io[2] = {l.data() + i, r.data() + i};
        e.process(io, 2, 256);
    }
    e.store().set(P_InputGain, 24.0f);
    double maxStep = 0;
    for (int i = n / 2; i < n; i += 256) {
        float* io[2] = {l.data() + i, r.data() + i};
        e.process(io, 2, std::min(256, n - i));
    }
    // measure max per-sample step in output after the change
    for (int i = n / 2 + 1; i < n; ++i) maxStep = std::max(maxStep, (double)std::fabs(l[i] - l[i - 1]));
    printf("  max per-sample output step after +24 dB gain jump: %.4f (input step would be 0.5)\n", maxStep);
    check(maxStep < 0.1, "no instantaneous jump (smoothed)");
}

int main() {
    printf("=== MasteringAU DSP test suite ===\n");
    testParamTable();
    testKWeightingCoeffs();
    testBiquadDesigns();
    testCrossoverFlatness();
    testResampler();
    testCompressor();
    testLimiter();
    testSaturator();
    testLoudnessMeter();
    testAnalyzer();
    testEngineBypassAndStages();
    testEngineFullChain();
    testFuzz();
    testSmoothing();
    printf("=== %d passed, %d failed ===\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
