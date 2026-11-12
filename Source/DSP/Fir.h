#pragma once

#include "dsp.h"
#include <vector>
#include <cmath>
#include <cstring>

namespace mast {

// Kaiser windowed-sinc prototype lowpass, length M = 8*K+1 so that the group
// delay of one up- or down-sampling stage is exactly K base-rate samples.
// 4x oversampling: passband edge at 0.45 * base Nyquist, ~90 dB stopband.
class Polyphase4 {
public:
    static constexpr int kOver = 4;
    static constexpr int kBaseDelay = 24;          // per direction, in base samples
    static constexpr int kM = 8 * kBaseDelay + 1;  // 193 taps

    Polyphase4() { design(); }

    void reset() {
        std::fill(upHist_.begin(), upHist_.end(), 0.0f);
        std::fill(dnHist_.begin(), dnHist_.end(), 0.0f);
        dnPhase_ = 0;
    }

    // Upsample one base-rate sample into out[0..3] (amplitude preserved).
    inline void upsample(float x, float* out) {
        upHist_[upIdx_ & kHistMask] = x;
        for (int p = 0; p < kOver; ++p) {
            double acc = 0.0;
            int maxJ = (kM - p + kOver - 1) / kOver;
            for (int j = 0; j < maxJ; ++j) {
                int tap = p + kOver * j;
                int idx = (upIdx_ - j) & kHistMask;
                acc += upH_[tap] * (double)upHist_[idx];
            }
            out[p] = (float)acc;
        }
        upIdx_++;
    }

    // Feed one over-rate sample; when a base-rate output is due, store it in y
    // and return true. The output for group n is aligned to over-index 4n, so
    // the up->down round trip has exactly 2*kBaseDelay base-sample delay.
    inline bool downsample(float x4, float& y) {
        dnHist_[dnIdx_ & kHistMask] = x4;
        uint32_t m = dnIdx_++;
        if (++dnPhase_ == kOver) {
            dnPhase_ = 0;
            uint32_t base = m - (kOver - 1); // over-index 4n
            double acc = 0.0;
            for (int k = 0; k < kM; ++k) {
                uint32_t idx = (base - (uint32_t)k) & kHistMask;
                acc += dnH_[k] * (double)dnHist_[idx];
            }
            y = (float)flushDenormal(acc);
            return true;
        }
        return false;
    }

    static constexpr int kHistSize = 256; // power of two >= max(kM, taps/phase)
    static constexpr int kHistMask = kHistSize - 1;

    const std::vector<double>& upCoeffs() const { return upH_; }
    const std::vector<double>& dnCoeffs() const { return dnH_; }

private:
    void design() {
        const double fc = 0.1125;   // cycles per over-rate sample
        const double beta = 9.0;    // Kaiser beta ~ 90 dB stopband
        upH_.assign(kM, 0.0);
        dnH_.assign(kM, 0.0);
        double center = (kM - 1) / 2.0;
        double i0beta = besselI0(beta);
        double sum = 0.0;
        for (int n = 0; n < kM; ++n) {
            double m = n - center;
            double h = (std::fabs(m) < 1e-12) ? 2.0 * fc
                       : std::sin(2.0 * kPi * fc * m) / (kPi * m);
            double r = 2.0 * n / (kM - 1) - 1.0;
            double w = besselI0(beta * std::sqrt(std::max(0.0, 1.0 - r * r))) / i0beta;
            h *= w;
            dnH_[n] = h;
            sum += h;
        }
        for (int n = 0; n < kM; ++n) {
            dnH_[n] /= sum;             // DC gain 1
            upH_[n] = 4.0 * dnH_[n];    // DC gain 4 compensates zero-stuffing
        }
        reset();
    }

    static double besselI0(double x) {
        double sum = 1.0, term = 1.0;
        double y = (x * x) / 4.0;
        for (int k = 1; k < 60; ++k) {
            term *= y / (double)(k * k);
            sum += term;
            if (term < 1e-18 * sum) break;
        }
        return sum;
    }

    std::vector<double> upH_, dnH_;
    std::vector<float> upHist_ = std::vector<float>(kHistSize, 0.0f);
    std::vector<float> dnHist_ = std::vector<float>(kHistSize, 0.0f);
    uint32_t upIdx_ = 0, dnIdx_ = 0;
    int dnPhase_ = 0;
};

// Simple integer-delay circular buffer.
class DelayLine {
public:
    DelayLine() { resize(4096); }
    void resize(size_t samples) {
        size_t cap = 1;
        while (cap < samples + 1) cap <<= 1;
        buf_.assign(cap, 0.0f);
        mask_ = cap - 1;
        idx_ = 0;
    }
    void reset() { std::fill(buf_.begin(), buf_.end(), 0.0f); idx_ = 0; }
    // Push x, return the sample from `delay` samples ago.
    inline float process(float x, size_t delay) {
        if (buf_.empty()) return x;
        if (delay >= buf_.size()) delay = buf_.size() - 1;
        buf_[idx_] = x;
        float y = buf_[(idx_ + buf_.size() - delay) & mask_];
        idx_ = (idx_ + 1) & mask_;
        return y;
    }
private:
    std::vector<float> buf_;
    size_t mask_ = 0, idx_ = 0;
};

} // namespace mast
