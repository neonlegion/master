#pragma once

#include "dsp.h"
#include "Parameters.h"
#include "Biquad.h"
#include "EQ.h"
#include "Crossover.h"
#include "Multiband.h"
#include "Saturator.h"
#include "Limiter.h"
#include "LoudnessMeter.h"
#include "Analyzer.h"
#include <vector>
#include <cmath>
#include <algorithm>

namespace mast {

struct Meters {
    float momentaryLUFS = -120.0f;
    float shortTermLUFS = -120.0f;
    float integratedLUFS = -120.0f;
    float loudnessRangeLU = 0.0f;
    float truePeakDbTP = -120.0f;
    float limiterGRDb = 0.0f;
    float mbGRDb[kNumMbBands] = {0, 0, 0, 0};
};

// Full mastering chain:
//   input gain -> HP filter -> mono-low -> 6-band EQ -> M/S width ->
//   4-band multiband compressor -> 4x-oversampled saturator ->
//   true-peak lookahead limiter -> output trim -> TPDF dither
// Meters: BS.1770 loudness (momentary/short-term/integrated/LRA), true peak,
// limiter + per-band gain reduction, spectrum analyzer.
class MasteringEngine {
public:
    MasteringEngine() { store_.initFromDefaults(); }

    void setSampleRate(double fs) {
        fs_ = fs;
        eq_.setSampleRate(fs);
        mb_.setSampleRate(fs);
        sat_.setSampleRate(fs);
        lim_.setSampleRate(fs);
        meter_.setSampleRate(fs);
        analyzer_.setSampleRate(fs);
        dither_.reset(0x1234567u);
    }

    void reset() {
        eq_.reset();
        mb_.reset();
        sat_.reset();
        lim_.reset();
        meter_.reset();
        analyzer_.reset();
        hpL1_.reset(); hpL2_.reset(); hpR1_.reset(); hpR2_.reset();
        monoXL_.reset(); monoXR_.reset();
        smoothIn_ = smoothOut_ = smoothWidth_ = -1.0f; // force re-init
    }

    ParamStore& store() { return store_; }

    double latencySamples() const {
        double l = 0.0;
        if (lim_.enabledFlag()) l += lim_.latencySamples();
        if (sat_.enabled()) l += Saturator::kLatency;
        return l;
    }

    // In-place processing of planar float buffers, 1 or 2 channels.
    void process(float* const* io, int numCh, int n) {
        ParamValues p;
        store_.loadInto(p);
        const bool bypass = p.get(P_Bypass) > 0.5f;
        const bool hpOn = p.get(P_HpEnable) > 0.5f;
        const bool monoLowOn = p.get(P_MonoLowEnable) > 0.5f;
        const bool satOn = p.get(P_SatEnable) > 0.5f;
        const bool limOn = p.get(P_LimEnable) > 0.5f;

        // Block-level reconfiguration of filter-based stages.
        if (hpOn) {
            double f = clampd(p.get(P_HpFreq), 5.0, 0.45 * fs_);
            designHighPass(hpL1_, fs_, f, 0.7071);
            designHighPass(hpL2_, fs_, f, 0.7071);
            designHighPass(hpR1_, fs_, f, 0.7071);
            designHighPass(hpR2_, fs_, f, 0.7071);
        }
        if (monoLowOn) {
            monoXL_.setFrequency(fs_, p.get(P_MonoLowFreq));
            monoXR_.setFrequency(fs_, p.get(P_MonoLowFreq));
        }
        eq_.update(p);
        mb_.update(p);
        sat_.configure(satOn, p.get(P_SatDrive), (int)p.get(P_SatMode), p.get(P_SatMix));
        lim_.configure(p.get(P_LimCeiling), p.get(P_LimLookahead), p.get(P_LimRelease));
        lim_.setEnabled(limOn);

        const int ch = std::min(numCh, 2);
        tmpL_.resize(n);
        tmpR_.resize(n);

        // Per-sample gain smoothing coefficients (5 ms).
        const float smCoef = onePoleCoef(fs_, 0.005);
        if (smoothIn_ < 0.0f) { smoothIn_ = p.get(P_InputGain); smoothOut_ = p.get(P_OutputTrim); smoothWidth_ = p.get(P_Width); }
        const float inTarget = p.get(P_InputGain);
        const float outTarget = p.get(P_OutputTrim);
        const float widthTarget = p.get(P_Width);

        if (bypass) {
            meter_.processBlock(io, ch, n);
            analyzer_.processBlock(io[0], n);
            readMeters(p);
            return;
        }

        const bool stereo = ch == 2;
        for (int i = 0; i < n; ++i) {
            smoothIn_ += (inTarget - smoothIn_) * smCoef;
            smoothOut_ += (outTarget - smoothOut_) * smCoef;
            smoothWidth_ += (widthTarget - smoothWidth_) * smCoef;
            const float inGain = dbToLin(smoothIn_);

            float l = io[0][i] * inGain;
            float r = stereo ? io[1][i] * inGain : l;

            if (hpOn) {
                l = hpL2_.process(hpL1_.process(l));
                r = stereo ? hpR2_.process(hpR1_.process(r)) : l;
            }

            if (monoLowOn && stereo) {
                float lLo, lHi, rLo, rHi;
                monoXL_.process(l, lLo, lHi);
                monoXR_.process(r, rLo, rHi);
                float mono = 0.5f * (lLo + rLo);
                l = mono + lHi;
                r = mono + rHi;
            }

            l = eq_.process(l);
            r = stereo ? eq_.process(r) : l;

            if (stereo) {
                float mid = 0.5f * (l + r);
                float side = 0.5f * (l - r) * dbToLin(smoothWidth_);
                l = mid + side;
                r = mid - side;
            }

            mb_.process(l, r);

            tmpL_[i] = l;
            tmpR_[i] = stereo ? r : l;
        }

        if (satOn) {
            sat_.processBlock(tmpL_.data(), n);
            if (stereo) sat_.processBlock(tmpR_.data(), n);
        }

        if (limOn && stereo) {
            lim_.processBlock(tmpL_.data(), tmpR_.data(), n);
        } else if (limOn) {
            lim_.processBlockMono(tmpL_.data(), n);
        }

        const bool ditherOn = p.get(P_DitherEnable) > 0.5f;
        const float lsb = 1.0f / 8388608.0f; // 24-bit TPDF
        for (int i = 0; i < n; ++i) {
            float l = tmpL_[i] * dbToLin(smoothOut_);
            float r = stereo ? tmpR_[i] * dbToLin(smoothOut_) : l;
            if (ditherOn) {
                l = dither_.process(l, lsb);
                r = stereo ? dither_.process(r, lsb) : l;
            }
            io[0][i] = l;
            if (stereo) io[1][i] = r;
        }

        meter_.processBlock(io, ch, n);
        analyzer_.processBlock(io[0], n);
        readMeters(p);
    }

    const Meters& meters() const { return meters_; }
    const SpectrumAnalyzer& analyzer() const { return analyzer_; }

private:
    void readMeters(const ParamValues&) {
        meters_.momentaryLUFS = meter_.momentaryLUFS();
        meters_.shortTermLUFS = meter_.shortTermLUFS();
        meters_.integratedLUFS = meter_.integratedLUFS();
        meters_.loudnessRangeLU = meter_.loudnessRange();
        meters_.truePeakDbTP = meter_.truePeakDbTP();
        meters_.limiterGRDb = lim_.gainReductionDb();
        for (int b = 0; b < kNumMbBands; ++b) meters_.mbGRDb[b] = mb_.bandGR(b);
    }

    double fs_ = 48000.0;
    ParamStore store_;
    ParametricEQ eq_;
    MultibandComp mb_;
    Saturator sat_;
    TruePeakLimiter lim_;
    LoudnessMeter meter_;
    SpectrumAnalyzer analyzer_;
    TpdfDither dither_;
    Biquad hpL1_, hpL2_, hpR1_, hpR2_;
    LinkwitzRiley4 monoXL_, monoXR_;
    std::vector<float> tmpL_, tmpR_;
    float smoothIn_ = -1.0f, smoothOut_ = -1.0f, smoothWidth_ = -1.0f;
    Meters meters_;
};

} // namespace mast
