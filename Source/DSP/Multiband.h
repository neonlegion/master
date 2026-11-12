#pragma once

#include "Crossover.h"
#include "Compressor.h"
#include "Parameters.h"

namespace mast {

// 4-band multiband compressor with Linkwitz-Riley-4 crossovers (bands sum flat).
// Stereo-linked gain per band.
class MultibandComp {
public:
    void setSampleRate(double fs) {
        fs_ = fs;
        for (auto& c : comps_) c.setSampleRate(fs);
    }

    void reset() {
        for (auto& ch : xovers_) for (auto& x : ch) x.reset();
        for (auto& c : comps_) c.reset();
    }

    void update(const ParamValues& p) {
        double x1 = p.get(P_MbXover1);
        double x2 = p.get(P_MbXover2);
        double x3 = p.get(P_MbXover3);
        if (!(x1 < x2 && x2 < x3)) { // enforce ordering
            double a = std::min({x1, x2, x3});
            double c = std::max({x1, x2, x3});
            double b = x1 + x2 + x3 - a - c;
            x1 = a; x2 = b; x3 = c;
        }
        for (int c = 0; c < 2; ++c) {
            xovers_[c][0].setFrequency(fs_, x1);
            xovers_[c][1].setFrequency(fs_, x2);
            xovers_[c][2].setFrequency(fs_, x3);
        }
        anyEnabled_ = false;
        for (int b = 0; b < kNumMbBands; ++b) {
            bool en = p.get(mbParam(b, MbEnable)) > 0.5f;
            comps_[b].configure(p.get(mbParam(b, MbThresh)),
                                p.get(mbParam(b, MbRatio)),
                                p.get(mbParam(b, MbAttack)),
                                p.get(mbParam(b, MbRelease)),
                                p.get(mbParam(b, MbMakeup)));
            bandEnabled_[b] = en;
            anyEnabled_ = anyEnabled_ || en;
        }
    }

    inline void process(float& l, float& r) {
        if (!anyEnabled_) return;
        float lLo, lHi, rLo, rHi;
        xovers_[0][0].process(l, lLo, lHi);
        xovers_[1][0].process(r, rLo, rHi);
        float lB2, lHi2, rB2, rHi2;
        xovers_[0][1].process(lHi, lB2, lHi2);
        xovers_[1][1].process(rHi, rB2, rHi2);
        float lB3, lB4, rB3, rB4;
        xovers_[0][2].process(lHi2, lB3, lB4);
        xovers_[1][2].process(rHi2, rB3, rB4);

        float bl[4] = {lLo, lB2, lB3, lB4};
        float br[4] = {rLo, rB2, rB3, rB4};
        float sl = 0.0f, sr = 0.0f;
        for (int b = 0; b < kNumMbBands; ++b) {
            if (bandEnabled_[b]) {
                float ol, orr;
                comps_[b].processLinked(bl[b], br[b], ol, orr);
                sl += ol; sr += orr;
            } else {
                sl += bl[b]; sr += br[b];
            }
        }
        l = sl;
        r = sr;
    }

    float bandGR(int b) const { return comps_[b].gainReductionDb(); }

private:
    double fs_ = 48000.0;
    LinkwitzRiley4 xovers_[2][3]; // [channel][crossover] — per-channel filter state
    Compressor comps_[kNumMbBands];
    bool bandEnabled_[kNumMbBands] = {};
    bool anyEnabled_ = false;
};

} // namespace mast
