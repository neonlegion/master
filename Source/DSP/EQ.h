#pragma once

#include "Biquad.h"
#include "Parameters.h"

namespace mast {

class EqBand {
public:
    void reset() { bq_.reset(); enabled_ = false; type_ = EqPeak; }

    void configure(double fs, bool enabled, int type, double freq, double gainDb, double q) {
        enabled_ = enabled;
        type_ = type;
        if (!enabled) { bq_.setUnity(); return; }
        freq = clampd(freq, 20.0, 0.49 * fs);
        switch (type) {
            case EqPeak:      designPeaking(bq_, fs, freq, gainDb, q); break;
            case EqLowShelf:  designLowShelf(bq_, fs, freq, gainDb, shelfSlope(q)); break;
            case EqHighShelf: designHighShelf(bq_, fs, freq, gainDb, shelfSlope(q)); break;
            case EqLowPass:   designLowPass(bq_, fs, freq, q); break;
            case EqHighPass:  designHighPass(bq_, fs, freq, q); break;
            default: bq_.setUnity(); break;
        }
    }

    inline float process(float x) {
        return enabled_ ? bq_.process(x) : x;
    }

    const Biquad& biquad() const { return bq_; }
    bool enabled() const { return enabled_; }

private:
    // Map the UI Q knob onto the RBJ shelf slope S (steeper shelf = larger S).
    static double shelfSlope(double q) { return clampd(1.0 / q, 0.25, 4.0); }

    Biquad bq_;
    bool enabled_ = false;
    int type_ = EqPeak;
};

// 6-band parametric EQ, minimum phase, cascade of biquads.
class ParametricEQ {
public:
    void setSampleRate(double fs) { fs_ = fs; dirty_ = true; }
    void reset() { for (auto& b : bands_) b.reset(); }

    void update(const ParamValues& p) {
        for (int i = 0; i < kNumEqBands; ++i) {
            bands_[i].configure(fs_,
                                p.get(eqParam(i, EqEnable)) > 0.5f,
                                (int)p.get(eqParam(i, EqType)),
                                p.get(eqParam(i, EqFreq)),
                                p.get(eqParam(i, EqGain)),
                                p.get(eqParam(i, EqQ)));
        }
    }

    inline float process(float x) {
        for (auto& b : bands_) x = b.process(x);
        return x;
    }

    const EqBand& band(int i) const { return bands_[i]; }

private:
    double fs_ = 48000.0;
    bool dirty_ = true;
    EqBand bands_[kNumEqBands];
};

} // namespace mast
