#pragma once

#include "dsp.h"
#include "Biquad.h"
#include "Fir.h"
#include <vector>
#include <deque>
#include <cmath>
#include <algorithm>

namespace mast {

// ITU-R BS.1770-4 K-weighting (stage-1 high shelf + stage-2 RLB high-pass),
// coefficients computed from the standard's design equations for any sample
// rate (verified against the published 48 kHz coefficients in the tests).
struct KWeighting {
    Biquad shelf, hpf;
    void design(double fs) {
        const double f0 = 1681.9744509555319;
        const double G  = 3.999843853973347;
        const double Q  = 0.7071752369554196;
        double K = std::tan(kPi * f0 / fs);
        double Vh = std::pow(10.0, G / 20.0);
        double Vb = std::pow(Vh, 0.499666774155);
        double a0 = 1.0 + K / Q + K * K;
        shelf.set((Vh + Vb * K / Q + K * K) / a0,
                  2.0 * (K * K - Vh) / a0,
                  (Vh - Vb * K / Q + K * K) / a0,
                  2.0 * (K * K - 1.0) / a0,
                  (1.0 - K / Q + K * K) / a0);

        const double f0b = 38.13547087602444;
        const double Qb  = 0.5003270373238773;
        double Kb = std::tan(kPi * f0b / fs);
        double a0b = 1.0 + Kb / Qb + Kb * Kb;
        hpf.set(1.0 / a0b, -2.0 / a0b, 1.0 / a0b,
                2.0 * (Kb * Kb - 1.0) / a0b,
                (1.0 - Kb / Qb + Kb * Kb) / a0b);
    }
    inline float process(float x) { return hpf.process(shelf.process(x)); }
    void reset() { shelf.reset(); hpf.reset(); }
};

// BS.1770-4 / EBU R128 loudness meter: momentary (400 ms), short-term (3 s),
// gated integrated loudness, loudness range (LRA: 10th-95th percentile of
// short-term values) and 4x-oversampled true peak.
// 400 ms measurement blocks with 75% overlap (100 ms hop) are built from a
// ring of the last four 100 ms hop energies per channel.
class LoudnessMeter {
public:
    static constexpr double kBlockSec = 0.400;
    static constexpr double kHopSec = 0.100;
    static constexpr double kShortTermSec = 3.0;
    static constexpr double kAbsGateLUFS = -70.0;
    static constexpr double kRelGateOffset = -10.0;
    static constexpr size_t kMaxBlocks = 36000; // 1 hour of 100 ms hops

    void setSampleRate(double fs) {
        fs_ = fs;
        for (auto& k : k_) k.design(fs);
        hopSamples_ = std::max(1, (int)std::lround(kHopSec * fs));
        stBlocks_ = (int)std::lround(kShortTermSec / kHopSec); // 30 hops
        reset();
    }

    void reset() {
        for (int c = 0; c < 2; ++c) {
            k_[c].reset();
            tpOs_[c].reset();
            hopSumSq_[c] = 0.0;
            for (int j = 0; j < 4; ++j) hopRing_[c][j] = 0.0;
            ringIdx_[c] = 0;
        }
        sinceHop_ = 0;
        blockPowers_.clear();
        stValues_.clear();
        momentary_ = shortTerm_ = integrated_ = -120.0f;
        lra_ = 0.0f;
        tpBlockMax_ = tpMax_ = 0.0;
        tpDbTP_ = tpMaxDb_ = -120.0f;
    }

    void processBlock(const float* const* ch, int numCh, int n) {
        int channels = std::min(numCh, 2);
        for (int i = 0; i < n; ++i) {
            for (int c = 0; c < channels; ++c) {
                float y = k_[c].process(ch[c][i]);
                hopSumSq_[c] += (double)y * y;
                float o[4];
                tpOs_[c].upsample(ch[c][i], o);
                for (int p = 0; p < 4; ++p) {
                    double a = std::fabs((double)o[p]);
                    if (a > tpBlockMax_) tpBlockMax_ = a;
                }
            }
            if (++sinceHop_ >= hopSamples_) {
                sinceHop_ = 0;
                // 400 ms block (75% overlap): sum of last four 100 ms hop energies.
                double blockPow = 0.0;
                for (int c = 0; c < channels; ++c) {
                    hopRing_[c][ringIdx_[c]] = hopSumSq_[c];
                    ringIdx_[c] = (ringIdx_[c] + 1) & 3;
                    double e = 0.0;
                    for (int j = 0; j < 4; ++j) e += hopRing_[c][j];
                    blockPow += e / (kBlockSec * fs_);
                    hopSumSq_[c] = 0.0;
                }
                double blockLUFS = -0.691 + 10.0 * std::log10(blockPow + 1e-15);
                blockPowers_.push_back(blockPow);
                if (blockPowers_.size() > kMaxBlocks) blockPowers_.pop_front();
                momentary_ = (float)blockLUFS;
                recomputeShortTermAndIntegrated();
            }
        }
        if (tpBlockMax_ > tpMax_) tpMax_ = tpBlockMax_;
        tpDbTP_ = (float)linToDb(std::max(tpBlockMax_, 1e-9));
        tpMaxDb_ = (float)linToDb(std::max(tpMax_, 1e-9));
        tpBlockMax_ = 0.0;
    }

    float momentaryLUFS() const { return momentary_; }
    float shortTermLUFS() const { return shortTerm_; }
    float integratedLUFS() const { return integrated_; }
    float loudnessRange() const { return lra_; }
    float truePeakDbTP() const { return tpDbTP_; }
    float truePeakMaxDbTP() const { return tpMaxDb_; }

private:
    void recomputeShortTermAndIntegrated() {
        if (blockPowers_.empty()) return;
        size_t from = blockPowers_.size() > (size_t)stBlocks_ ? blockPowers_.size() - stBlocks_ : 0;
        double sum = 0.0;
        for (size_t i = from; i < blockPowers_.size(); ++i) sum += blockPowers_[i];
        double stPow = sum / (double)(blockPowers_.size() - from);
        shortTerm_ = (float)(-0.691 + 10.0 * std::log10(stPow + 1e-15));
        stValues_.push_back(shortTerm_);
        if (stValues_.size() > kMaxBlocks) stValues_.pop_front();

        double sumAll = 0.0;
        int nAll = 0;
        for (double p : blockPowers_) {
            double l = -0.691 + 10.0 * std::log10(p + 1e-15);
            if (l >= kAbsGateLUFS) { sumAll += p; ++nAll; }
        }
        if (nAll == 0) { integrated_ = -120.0f; return; }
        double ungated = sumAll / nAll;
        double relGatePow = ungated * std::pow(10.0, kRelGateOffset / 10.0);
        double sumG = 0.0;
        int nG = 0;
        for (double p : blockPowers_) {
            double l = -0.691 + 10.0 * std::log10(p + 1e-15);
            if (l >= kAbsGateLUFS && p >= relGatePow) { sumG += p; ++nG; }
        }
        integrated_ = nG > 0 ? (float)(-0.691 + 10.0 * std::log10(sumG / nG + 1e-15)) : -120.0f;

        if (stValues_.size() >= 10) {
            std::vector<float> v(stValues_.begin(), stValues_.end());
            std::sort(v.begin(), v.end());
            auto pct = [&](double q) {
                double idx = q * (double)(v.size() - 1);
                size_t i0 = (size_t)idx;
                size_t i1 = std::min(i0 + 1, v.size() - 1);
                double f = idx - (double)i0;
                return (double)v[i0] * (1.0 - f) + (double)v[i1] * f;
            };
            lra_ = (float)(pct(0.95) - pct(0.10));
        }
    }

    double fs_ = 48000.0;
    int hopSamples_ = 4800, stBlocks_ = 30;
    KWeighting k_[2];
    double hopSumSq_[2] = {0, 0};
    double hopRing_[2][4] = {{0, 0, 0, 0}, {0, 0, 0, 0}};
    int ringIdx_[2] = {0, 0};
    int sinceHop_ = 0;
    std::deque<double> blockPowers_;
    std::deque<float> stValues_;
    float momentary_ = -120.0f, shortTerm_ = -120.0f, integrated_ = -120.0f, lra_ = 0.0f;
    Polyphase4 tpOs_[2];
    double tpBlockMax_ = 0.0, tpMax_ = 0.0;
    float tpDbTP_ = -120.0f, tpMaxDb_ = -120.0f;
};

} // namespace mast
