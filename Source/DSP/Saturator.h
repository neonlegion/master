#pragma once

#include "dsp.h"
#include "Fir.h"
#include "Parameters.h"
#include <vector>
#include <cmath>

namespace mast {

// Harmonic saturator, 4x oversampled (polyphase FIR), three drive curves.
// Introduces a fixed latency of kLatency base samples (linear-phase FIR group
// delay of the up/downsampling round trip); the dry path is delay-matched.
class Saturator {
public:
    static constexpr int kLatency = 2 * Polyphase4::kBaseDelay; // 48 samples

    void setSampleRate(double fs) { fs_ = fs; }

    void reset() {
        os_.reset();
        dryDelay_.reset();
    }

    void configure(bool enabled, double driveDb, int mode, double mixPercent) {
        enabled_ = enabled;
        drive_ = dbToLin(driveDb);
        mode_ = mode;
        mix_ = clampd(mixPercent * 0.01, 0.0, 1.0);
        if (enabled_) {
            dryDelay_.resize(kLatency);
            os_.reset();
        }
    }

    bool enabled() const { return enabled_; }

    // In-place block processing. Call only when enabled.
    void processBlock(float* buf, int n) {
        if (!enabled_ || n <= 0) return;
        tmp4_.resize(4 * n);
        for (int i = 0; i < n; ++i) {
            float o[4];
            os_.upsample(buf[i], o);
            for (int p = 0; p < 4; ++p) tmp4_[4 * i + p] = curve(o[p]);
        }
        wet_.resize(n);
        int outIdx = 0;
        for (int k = 0; k < 4 * n; ++k) {
            float y;
            if (os_.downsample(tmp4_[k], y)) wet_[outIdx++] = y;
        }
        const float wetGain = (float)mix_;
        const float dryGain = (float)(1.0 - mix_);
        for (int i = 0; i < n; ++i) {
            float dry = dryDelay_.process(buf[i], kLatency);
            buf[i] = dry * dryGain + wet_[i] * wetGain;
        }
    }

private:
    // All curves have unity small-signal gain (dy/dx = 1 at x = 0) and softly
    // bound the output at 1/d for large |x|.
    inline float curve(float x) const {
        double d = drive_;
        double y;
        switch (mode_) {
            case SatTape: {
                // asymmetric: even-order term before the tanh
                double pre = x + 0.3 * x * x;
                y = std::tanh(d * pre) / d;
                break;
            }
            case SatTube: {
                double a = std::fabs(x);
                y = (x < 0.0 ? -1.0 : 1.0) * (1.0 - std::exp(-d * a)) / d;
                break;
            }
            case SatClean:
            default: {
                y = std::tanh(d * x) / d;
                break;
            }
        }
        return (float)clampd(y, -1.0, 1.0);
    }

    double fs_ = 48000.0;
    bool enabled_ = false;
    double drive_ = 1.0;
    int mode_ = SatClean;
    double mix_ = 1.0;
    Polyphase4 os_;
    DelayLine dryDelay_;
    std::vector<float> tmp4_, wet_;
};

} // namespace mast
