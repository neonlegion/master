#pragma once

#if !defined(__cplusplus) || __cplusplus < 201703L
#error "MasteringAU requires C++17: set CLANG_CXX_LANGUAGE_STANDARD = c++17 (project.yml already does - regenerate the Xcode project with `xcodegen generate` after `git pull`)"
#endif

#include <cstdint>
#include <cstddef>
#include <cmath>
#include <algorithm>

namespace mast {

constexpr double kPi = 3.14159265358979323846264338327950288;

inline float flushDenormal(float x) {
    return std::fabs(x) < 1e-20f ? 0.0f : x;
}

inline double flushDenormal(double x) {
    return std::fabs(x) < 1e-25 ? 0.0 : x;
}

inline float dbToLin(float db) { return std::pow(10.0f, db * 0.05f); }
inline float linToDb(float lin) { return lin > 1e-12f ? 20.0f * std::log10(lin) : -240.0f; }
inline double dbToLin(double db) { return std::pow(10.0, db * 0.05); }
inline double linToDb(double lin) { return lin > 1e-15 ? 20.0 * std::log10(lin) : -300.0; }

inline float clampf(float x, float lo, float hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}

inline double clampd(double x, double lo, double hi) {
    return x < lo ? lo : (x > hi ? hi : x);
}

// One-pole smoothing coefficient for a given time constant in seconds.
inline float onePoleCoef(double fs, double tauSeconds) {
    return 1.0f - std::exp(-1.0 / (fs * tauSeconds));
}

} // namespace mast
