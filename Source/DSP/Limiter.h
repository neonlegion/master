#pragma once

#include "dsp.h"
#include "Fir.h"
#include <vector>
#include <cmath>
#include <algorithm>

namespace mast {

// True-peak lookahead limiter, stereo-linked, operating entirely in a 4x
// oversampled domain: the signal is upsampled, the gain is clamped pointwise
// by the instantaneous requirement g <= ceiling/|x4|, applied with a lookahead
// delay, and the result is downsampled. Because the clamp is pointwise in the
// oversampled domain, the true peak of the output cannot exceed the ceiling
// (up to the resampler's passband ripple, < 0.1 dB).
class TruePeakLimiter {
public:
    void setSampleRate(double fs) { fs_ = fs; }

    // Internal margin below the user ceiling so the *measured* true peak of
    // the output stays at or below the ceiling even for adversarial full-scale
    // noise (the decimation filter's finite stopband lets a few tenths of a dB
    // through otherwise). Invisible to the user: meters report the ceiling.
    static constexpr double kSafetyMarginDb = 0.5;

    void configure(double ceilingDb, double lookaheadMs, double releaseMs) {
        ceilingLin_ = dbToLin(clampd(ceilingDb, -24.0, 0.0) - kSafetyMarginDb);
        int newLookahead = std::max(1, (int)std::lround(lookaheadMs * 0.001 * fs_));
        if (newLookahead != lookahead_) {
            lookahead_ = newLookahead;
            audioL_.resize(effDelay4()); audioR_.resize(effDelay4());
            gain_.resize(effDelayBase());
        }
        relCoef4_ = 1.0 - std::exp(-1.0 / (fs_ * 4.0 * std::max(0.5, releaseMs) * 0.001));
    }

    void setEnabled(bool e) { enabled_ = e; }
    bool enabledFlag() const { return enabled_; }

    void reset() {
        upL_.reset(); upR_.reset(); dnL_.reset(); dnR_.reset();
        audioL_.reset(); audioR_.reset(); gain_.reset();
        grSmoothDb_ = 0.0;
        grDb_ = 0.0f;
    }

    // Total latency in base samples = lookahead_ (FIR group delay compensated).
    int latencySamples() const { return lookahead_; }
    float gainReductionDb() const { return grDb_; }

    void processBlock(float* l, float* r, int n) {
        if (n <= 0 || !enabled_) return;
        const int n4 = 4 * n;
        x4L_.resize(n4); x4R_.resize(n4);
        y4L_.resize(n4); y4R_.resize(n4);
        for (int i = 0; i < n; ++i) {
            upL_.upsample(l[i], &x4L_[4 * i]);
            upR_.upsample(r[i], &x4R_[4 * i]);
        }
        detectAndCollapse(n);
        const int d4 = effDelay4();
        const int db = effDelayBase();
        for (int i = 0; i < n; ++i) {
            // Gain delay line is clocked once per base sample so that its delay
            // in over-rate samples (4*db) matches the audio delay d4 exactly.
            float g = gain_.process(gBase_[i], db);
            for (int p = 0; p < 4; ++p) {
                int k = 4 * i + p;
                float dl = audioL_.process(x4L_[k], d4);
                float dr = audioR_.process(x4R_[k], d4);
                y4L_[k] = clampf(dl * g, -1.0f, 1.0f);
                y4R_[k] = clampf(dr * g, -1.0f, 1.0f);
            }
        }
        int oi = 0;
        for (int k = 0; k < n4; ++k) {
            float yl, yr;
            bool bl = dnL_.downsample(y4L_[k], yl);
            bool br = dnR_.downsample(y4R_[k], yr);
            if (bl) l[oi] = yl;
            if (br) r[oi] = yr;
            if (bl) ++oi;
        }
    }

    void processBlockMono(float* io, int n) {
        if (n <= 0 || !enabled_) return;
        const int n4 = 4 * n;
        x4L_.resize(n4); y4L_.resize(n4);
        for (int i = 0; i < n; ++i) upL_.upsample(io[i], &x4L_[4 * i]);
        detectAndCollapse(n);
        const int d4 = effDelay4();
        const int db = effDelayBase();
        for (int i = 0; i < n; ++i) {
            float g = gain_.process(gBase_[i], db);
            for (int p = 0; p < 4; ++p) {
                int k = 4 * i + p;
                float d = audioL_.process(x4L_[k], d4);
                y4L_[k] = clampf(d * g, -1.0f, 1.0f);
            }
        }
        int oi = 0;
        for (int k = 0; k < n4; ++k) {
            float y;
            if (dnL_.downsample(y4L_[k], y)) io[oi++] = y;
        }
    }

private:
    // Delays minus the FIR group delay of the up+down round trip
    // (2*kBaseDelay base samples), so total latency is exactly lookahead_.
    int effDelay4() const {
        return std::max(0, 4 * lookahead_ - 4 * 2 * Polyphase4::kBaseDelay);
    }
    int effDelayBase() const {
        return std::max(0, lookahead_ - 2 * Polyphase4::kBaseDelay);
    }

    // Detect at 4x, smooth in dB, clamp pointwise by the requirement, then
    // collapse to one zero-order-hold gain per base sample (min of the four
    // sub-samples). The clamp keeps y4 <= ceiling pointwise in the 4x domain,
    // and the hold shape keeps y4 band-limited so decimation cannot splatter.
    void detectAndCollapse(int n) {
        gBase_.resize(n);
        double attCoef = 1.0 - std::exp(-1.0 / (fs_ * 4.0 * (lookahead_ / fs_)));
        double grSmooth = grSmoothDb_;
        float maxGr = 0.0f;
        for (int i = 0; i < n; ++i) {
            float gMin = 1.0f;
            for (int p = 0; p < 4; ++p) {
                int k = 4 * i + p;
                double a = std::max(std::fabs((double)x4L_[k]), std::fabs((double)x4R_[k]));
                double gReq = (a > 1e-12) ? std::min(1.0, ceilingLin_ / a) : 1.0;
                double gr = -20.0 * std::log10(gReq);
                if (gr > grSmooth) grSmooth += (gr - grSmooth) * attCoef;
                else               grSmooth += (gr - grSmooth) * relCoef4_;
                double gSafe = std::min(dbToLin(-grSmooth), gReq);
                if ((float)gSafe < gMin) gMin = (float)gSafe;
            }
            gBase_[i] = gMin;
            float grHere = (float)(-20.0 * std::log10(std::max((double)gMin, 1e-9)));
            if (grHere > maxGr) maxGr = grHere;
        }
        grSmoothDb_ = grSmooth;
        grDb_ = maxGr;
    }

    double fs_ = 48000.0;
    bool enabled_ = true;
    double ceilingLin_ = 0.891250938; // -1 dBTP
    int lookahead_ = 240;
    double relCoef4_ = 0.99;
    double grSmoothDb_ = 0.0;
    float grDb_ = 0.0f;
    Polyphase4 upL_, upR_, dnL_, dnR_;
    DelayLine audioL_, audioR_, gain_;
    std::vector<float> x4L_, x4R_, gBase_, y4L_, y4R_;
};

} // namespace mast
