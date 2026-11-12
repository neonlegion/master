#pragma once

#include "dsp.h"
#include <vector>
#include <cmath>
#include <complex>
#include <algorithm>

namespace mast {

// Real-time spectrum analyzer meter: 4096-point Hann-windowed FFT, 50% hop.
class SpectrumAnalyzer {
public:
    static constexpr int kFFT = 4096;
    static constexpr int kHop = kFFT / 2;

    void setSampleRate(double fs) { fs_ = fs; reset(); }

    void reset() {
        std::fill(ring_.begin(), ring_.end(), 0.0f);
        idx_ = 0; since_ = 0;
        ready_ = false;
    }

    void processBlock(const float* ch, int n) {
        for (int i = 0; i < n; ++i) {
            ring_[idx_] = ch[i];
            idx_ = (idx_ + 1) & (kFFT - 1);
            if (++since_ >= kHop) {
                since_ = 0;
                compute();
                ready_ = true;
            }
        }
    }

    // Magnitude spectrum in dBFS, bins 0..kFFT/2 (call only when ready()).
    const std::vector<float>& spectrumDb() const { return specDb_; }
    bool ready() const { return ready_; }
    int numBins() const { return kFFT / 2 + 1; }

private:
    void compute() {
        specDb_.assign(kFFT / 2 + 1, -240.0f);
        std::vector<std::complex<double>> a(kFFT);
        for (int i = 0; i < kFFT; ++i) {
            double w = 0.5 - 0.5 * std::cos(2.0 * kPi * i / (kFFT - 1)); // Hann
            a[i] = std::complex<double>(ring_[(idx_ + i) & (kFFT - 1)] * w, 0.0);
        }
        fft(a);
        double norm = 2.0 / (kFFT * 0.5); // coherent gain of Hann = 0.5
        for (int k = 0; k <= kFFT / 2; ++k) {
            double mag = std::abs(a[k]) * norm;
            specDb_[k] = (float)linToDb(std::max(mag, 1e-12));
        }
    }

    static void fft(std::vector<std::complex<double>>& a) {
        const int n = (int)a.size();
        for (int i = 1, j = 0; i < n; ++i) {
            int bit = n >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(a[i], a[j]);
        }
        for (int len = 2; len <= n; len <<= 1) {
            double ang = -2.0 * kPi / len;
            std::complex<double> wlen(std::cos(ang), std::sin(ang));
            for (int i = 0; i < n; i += len) {
                std::complex<double> w(1.0, 0.0);
                for (int j = 0; j < len / 2; ++j) {
                    auto u = a[i + j];
                    auto v = a[i + j + len / 2] * w;
                    a[i + j] = u + v;
                    a[i + j + len / 2] = u - v;
                    w *= wlen;
                }
            }
        }
    }

    double fs_ = 48000.0;
    std::vector<float> ring_ = std::vector<float>(kFFT, 0.0f);
    std::vector<float> specDb_;
    int idx_ = 0, since_ = 0;
    bool ready_ = false;
};

// TPDF dither (xorshift PRNG, audio-thread safe, no allocation).
class TpdfDither {
public:
    void reset(uint32_t seed) { s_ = seed ? seed : 0x9E3779B9u; }
    // lsb = weight of one LSB of the target integer depth (e.g. 2^-23 for 24-bit).
    inline float process(float x, float lsb) {
        float u1 = next01();
        float u2 = next01();
        return x + (u1 - u2) * lsb;
    }
private:
    inline float next01() {
        s_ ^= s_ << 13; s_ ^= s_ >> 17; s_ ^= s_ << 5;
        return (float)(s_ >> 8) * (1.0f / 16777216.0f);
    }
    uint32_t s_ = 0x9E3779B9u;
};

} // namespace mast
