#pragma once

#include "dsp.h"
#include <cmath>

namespace mast {

// Transposed direct form II biquad, double precision state for headroom.
struct Biquad {
    double b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0;
    double z1 = 0.0, z2 = 0.0;

    void set(double nb0, double nb1, double nb2, double na1, double na2) {
        b0 = nb0; b1 = nb1; b2 = nb2; a1 = na1; a2 = na2;
    }

    void setUnity() { set(1.0, 0.0, 0.0, 0.0, 0.0); z1 = z2 = 0.0; }

    void reset() { z1 = z2 = 0.0; }

    inline float process(float x) {
        double in = x;
        double y = b0 * in + z1;
        z1 = b1 * in - a1 * y + z2;
        z2 = b2 * in - a2 * y;
        return (float)flushDenormal(y);
    }

    // Magnitude response at angular frequency w (radians/sample).
    double magnitudeAt(double w) const {
        double cw = std::cos(w), sw = std::sin(w);
        double cw2 = std::cos(2.0 * w), sw2 = std::sin(2.0 * w);
        double hr = b0 + b1 * cw + b2 * cw2;
        double hi = -(b1 * sw + b2 * sw2);
        double ar = 1.0 + a1 * cw + a2 * cw2;
        double ai = -(a1 * sw + a2 * sw2);
        return std::sqrt((hr * hr + hi * hi) / (ar * ar + ai * ai));
    }
};

// ---------------- Filter designs (RBJ audio EQ cookbook + Butterworth) --------

inline void designPeaking(Biquad& bq, double fs, double f0, double gainDb, double Q) {
    double A = std::pow(10.0, gainDb / 40.0);
    double w0 = 2.0 * kPi * f0 / fs;
    double cw = std::cos(w0), sw = std::sin(w0);
    double alpha = sw / (2.0 * Q);
    double a0 = 1.0 + alpha / A;
    bq.set((1.0 + alpha * A) / a0,
           (-2.0 * cw) / a0,
           (1.0 - alpha * A) / a0,
           (-2.0 * cw) / a0,
           (1.0 - alpha / A) / a0);
}

// RBJ shelf with slope parameter S (S = 1 gives a ~6 dB/oct shelf transition).
// Verified numerically: LS has gain A^2 at DC and unity at Nyquist, HS mirrored.
inline void designShelf(Biquad& bq, double fs, double f0, double gainDb, double S, bool lowShelf) {
    double A = std::pow(10.0, gainDb / 40.0);
    double w0 = 2.0 * kPi * f0 / fs;
    double cw = std::cos(w0), sw = std::sin(w0);
    double alpha = sw / 2.0 * std::sqrt((A + 1.0 / A) * (1.0 / S - 1.0) + 2.0);
    double sqA = std::sqrt(A);
    double t = 2.0 * sqA * alpha;
    double a0, b0, b1, b2, a1, a2;
    if (lowShelf) {
        a0 = (A + 1.0) + (A - 1.0) * cw + t;
        b0 = A * ((A + 1.0) - (A - 1.0) * cw + t);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
        b2 = A * ((A + 1.0) - (A - 1.0) * cw - t);
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
        a2 = (A + 1.0) + (A - 1.0) * cw - t;
    } else {
        a0 = (A + 1.0) - (A - 1.0) * cw + t;
        b0 = A * ((A + 1.0) + (A - 1.0) * cw + t);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
        b2 = A * ((A + 1.0) + (A - 1.0) * cw - t);
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cw);
        a2 = (A + 1.0) - (A - 1.0) * cw - t;
    }
    bq.set(b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0);
}

inline void designLowShelf(Biquad& bq, double fs, double f0, double gainDb, double S) {
    designShelf(bq, fs, f0, gainDb, S, true);
}
inline void designHighShelf(Biquad& bq, double fs, double f0, double gainDb, double S) {
    designShelf(bq, fs, f0, gainDb, S, false);
}

inline void designLowPass(Biquad& bq, double fs, double f0, double Q) {
    double w0 = 2.0 * kPi * f0 / fs;
    double cw = std::cos(w0), sw = std::sin(w0);
    double alpha = sw / (2.0 * Q);
    double a0 = 1.0 + alpha;
    double half = (1.0 - cw) / 2.0;
    bq.set(half / a0, 2.0 * half / a0, half / a0,
           (-2.0 * cw) / a0, (1.0 - alpha) / a0);
}

inline void designHighPass(Biquad& bq, double fs, double f0, double Q) {
    double w0 = 2.0 * kPi * f0 / fs;
    double cw = std::cos(w0), sw = std::sin(w0);
    double alpha = sw / (2.0 * Q);
    double a0 = 1.0 + alpha;
    bq.set((1.0 + cw) / (2.0 * a0), -(1.0 + cw) / a0, (1.0 + cw) / (2.0 * a0),
           (-2.0 * cw) / a0, (1.0 - alpha) / a0);
}

// Butterworth 2nd order (Q = 1/sqrt(2)) — building block for Linkwitz-Riley.
inline void designButterworthLP2(Biquad& bq, double fs, double f0) {
    designLowPass(bq, fs, f0, 0.7071067811865476);
}
inline void designButterworthHP2(Biquad& bq, double fs, double f0) {
    designHighPass(bq, fs, f0, 0.7071067811865476);
}

} // namespace mast
