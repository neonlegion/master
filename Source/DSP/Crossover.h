#pragma once

#include "Biquad.h"

namespace mast {

// Linkwitz-Riley 4th order crossover (two cascaded Butterworth 2nd orders per
// side). Low + high sum to unity (phase aligned), -6 dB at the crossover.
class LinkwitzRiley4 {
public:
    void reset() {
        lp1_.reset(); lp2_.reset();
        hp1_.reset(); hp2_.reset();
    }

    void setFrequency(double fs, double f0) {
        f0 = clampd(f0, 10.0, 0.45 * fs);
        designButterworthLP2(lp1_, fs, f0);
        designButterworthLP2(lp2_, fs, f0);
        designButterworthHP2(hp1_, fs, f0);
        designButterworthHP2(hp2_, fs, f0);
    }

    inline void process(float x, float& low, float& high) {
        float l = lp2_.process(lp1_.process(x));
        float h = hp2_.process(hp1_.process(x));
        low = l;
        high = h;
    }

private:
    Biquad lp1_, lp2_, hp1_, hp2_;
};

} // namespace mast
