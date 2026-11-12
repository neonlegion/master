#pragma once

#include "dsp.h"
#include <cmath>

namespace mast {

// Feed-forward compressor: RMS-ish detector, dB-domain gain computer with soft
// knee, attack/release smoothing of gain reduction, optional makeup gain.
class Compressor {
public:
    void setSampleRate(double fs) {
        fs_ = fs;
        // ~10 ms RMS pre-averaging window
        rmsCoef_ = 1.0 - std::exp(-1.0 / (fs * 0.010));
    }

    void configure(double threshDb, double ratio, double attackMs, double releaseMs,
                   double makeupDb, double kneeDb = 6.0) {
        thrDb_ = threshDb;
        ratio_ = std::max(1.0, ratio);
        kneeDb_ = kneeDb;
        makeupLin_ = dbToLin(makeupDb);
        attCoef_ = 1.0f - std::exp(-1.0 / (fs_ * std::max(0.05, attackMs) * 0.001));
        relCoef_ = 1.0f - std::exp(-1.0 / (fs_ * std::max(1.0, releaseMs) * 0.001));
    }

    void reset() { rmsState_ = 0.0; grSmoothDb_ = 0.0; }

    inline float process(float x) {
        double x2 = (double)x * x;
        rmsState_ += rmsCoef_ * (x2 - rmsState_);
        double levelDb = 10.0 * std::log10(rmsState_ + 1e-15);
        double gr = gainReductionFor(levelDb);
        if (gr > grSmoothDb_) grSmoothDb_ += (gr - grSmoothDb_) * attCoef_;
        else                   grSmoothDb_ += (gr - grSmoothDb_) * relCoef_;
        grSmoothDb_ = flushDenormal(grSmoothDb_);
        return (float)(x * dbToLin(-grSmoothDb_) * makeupLin_);
    }

    // Stereo-linked: detector driven by the louder channel, one gain for both.
    inline void processLinked(float l, float r, float& outL, float& outR) {
        double peak = std::max(std::fabs((double)l), std::fabs((double)r));
        double x2 = peak * peak;
        rmsState_ += rmsCoef_ * (x2 - rmsState_);
        double levelDb = 10.0 * std::log10(rmsState_ + 1e-15);
        double gr = gainReductionFor(levelDb);
        if (gr > grSmoothDb_) grSmoothDb_ += (gr - grSmoothDb_) * attCoef_;
        else                   grSmoothDb_ += (gr - grSmoothDb_) * relCoef_;
        grSmoothDb_ = flushDenormal(grSmoothDb_);
        double g = dbToLin(-grSmoothDb_) * makeupLin_;
        outL = (float)(l * g);
        outR = (float)(r * g);
    }

    float gainReductionDb() const { return (float)grSmoothDb_; }

private:
    double gainReductionFor(double levelDb) const {
        double over = levelDb - thrDb_;
        double knee = kneeDb_;
        double slope = 1.0 - 1.0 / ratio_;
        if (over <= -knee * 0.5) return 0.0;
        if (over < knee * 0.5) {
            double t = over + knee * 0.5;
            return slope * t * t / (2.0 * knee);
        }
        return slope * over;
    }

    double fs_ = 48000.0;
    double thrDb_ = -24.0, ratio_ = 2.0, kneeDb_ = 6.0, makeupLin_ = 1.0;
    double rmsCoef_ = 0.001, rmsState_ = 0.0;
    float attCoef_ = 0.5f, relCoef_ = 0.01f;
    double grSmoothDb_ = 0.0;
};

} // namespace mast
