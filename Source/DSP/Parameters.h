#pragma once

#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <atomic>

namespace mast {

// Parameter identifiers. Stable layout: the AU wrapper assigns AUParameterAddress
// equal to the enum value, so never reorder existing entries.
enum ParamId : uint32_t {
    P_InputGain = 0,
    P_OutputTrim,
    P_Bypass,
    P_HpEnable,
    P_HpFreq,

    P_EqBase, // 6 bands x 5 params: {Enable, Type, Freq, Gain, Q}

    P_MonoLowEnable = P_EqBase + 30,
    P_MonoLowFreq,
    P_Width,

    P_MbXover1,
    P_MbXover2,
    P_MbXover3,

    P_MbBandBase, // 4 bands x 6 params: {Enable, Thresh, Ratio, Attack, Release, Makeup}

    P_SatEnable = P_MbBandBase + 24,
    P_SatDrive,
    P_SatMode,
    P_SatMix,

    P_LimEnable,
    P_LimCeiling,
    P_LimLookahead,
    P_LimRelease,

    P_DitherEnable,

    P_Count
};

enum EqField : int { EqEnable = 0, EqType, EqFreq, EqGain, EqQ };
enum EqType : int { EqPeak = 0, EqLowShelf, EqHighShelf, EqLowPass, EqHighPass };
enum MbField : int { MbEnable = 0, MbThresh, MbRatio, MbAttack, MbRelease, MbMakeup };
enum SatMode : int { SatClean = 0, SatTape, SatTube };

constexpr int kNumEqBands = 6;
constexpr int kNumMbBands = 4;

inline uint32_t eqParam(int band, int field) { return P_EqBase + band * 5 + field; }
inline uint32_t mbParam(int band, int field) { return P_MbBandBase + band * 6 + field; }

struct ParamDesc {
    const char* id;      // unique string identifier (AU parameter identifier)
    const char* name;    // display name
    float minV;
    float maxV;
    float defV;
    const char* unit;    // "dB", "Hz", "ms", "%", "bool", "index"
    const char* group;   // AU parameter group name
    bool discrete;       // enum/bool: applied at block boundary, no smoothing
    const char* const* choices; // value strings for discrete params, else nullptr
    int numChoices;
};

inline const char* const kEqTypeChoices[] = {"Peak", "Low Shelf", "High Shelf", "Low Pass", "High Pass"};
inline const char* const kSatModeChoices[] = {"Clean", "Tape", "Tube"};
inline const char* const kBoolChoices[] = {"Off", "On"};

// Builds and returns the full descriptor table for all P_Count parameters.
inline const ParamDesc* paramDescs() {
    static const ParamDesc* table = [] {
        static ParamDesc d[P_Count];
        int i = 0;
        auto add = [&](const char* id, const char* name, float mn, float mx, float def,
                       const char* unit, const char* group, bool discrete,
                       const char* const* choices, int numChoices) {
            d[i++] = ParamDesc{id, name, mn, mx, def, unit, group, discrete, choices, numChoices};
        };

        add("inputGain",  "Input Gain",   -24.f, 24.f,  0.f,  "dB",   "Main",      false, nullptr, 0);
        add("outputTrim", "Output Trim",  -24.f, 24.f,  0.f,  "dB",   "Main",      false, nullptr, 0);
        add("bypass",     "Bypass",        0.f,  1.f,  0.f,  "bool", "Main",      true,  kBoolChoices, 2);
        add("hpEnable",   "HP On",         0.f,  1.f,  0.f,  "bool", "High-Pass", true,  kBoolChoices, 2);
        add("hpFreq",     "HP Frequency", 10.f, 500.f, 30.f, "Hz",   "High-Pass", false, nullptr, 0);

        static const float kEqDefaultFreq[kNumEqBands] = {60.f, 200.f, 800.f, 3000.f, 8000.f, 12000.f};
        static const int   kEqDefaultType[kNumEqBands] = {EqLowShelf, EqPeak, EqPeak, EqPeak, EqPeak, EqHighShelf};
        static char eqId[6][5][24];
        static char eqName[6][5][32];
        static char eqGroup[6][16];
        for (int b = 0; b < kNumEqBands; ++b) {
            std::snprintf(eqGroup[b], sizeof(eqGroup[b]), "EQ %d", b + 1);
            const char* fields[5] = {"enable", "type", "freq", "gain", "Q"};
            const char* names[5]  = {"Enable", "Type", "Frequency", "Gain", "Q"};
            for (int f = 0; f < 5; ++f) {
                std::snprintf(eqId[b][f], sizeof(eqId[b][f]), "eq%d%s", b + 1, fields[f]);
                std::snprintf(eqName[b][f], sizeof(eqName[b][f]), "%s", names[f]);
            }
            add(eqId[b][EqEnable], eqName[b][EqEnable], 0.f, 1.f, 0.f, "bool", eqGroup[b], true, kBoolChoices, 2);
            add(eqId[b][EqType],   eqName[b][EqType],   0.f, 4.f, (float)kEqDefaultType[b], "index", eqGroup[b], true, kEqTypeChoices, 5);
            add(eqId[b][EqFreq],   eqName[b][EqFreq],  20.f, 20000.f, kEqDefaultFreq[b], "Hz", eqGroup[b], false, nullptr, 0);
            add(eqId[b][EqGain],   eqName[b][EqGain], -15.f, 15.f, 0.f, "dB", eqGroup[b], false, nullptr, 0);
            add(eqId[b][EqQ],      eqName[b][EqQ],      0.2f, 24.f, 0.7f, "", eqGroup[b], false, nullptr, 0);
        }

        add("monoLowEnable", "Mono Low On",   0.f,  1.f,   0.f, "bool", "Stereo", true, kBoolChoices, 2);
        add("monoLowFreq",   "Mono Low Freq", 20.f, 300.f, 100.f, "Hz",  "Stereo", false, nullptr, 0);
        add("width",         "Width (Side)", -60.f, 24.f,  0.f, "dB",   "Stereo", false, nullptr, 0);

        add("mbXover1", "Crossover 1",  40.f,  2000.f,  250.f, "Hz", "Multiband", false, nullptr, 0);
        add("mbXover2", "Crossover 2", 100.f,  6000.f, 1200.f, "Hz", "Multiband", false, nullptr, 0);
        add("mbXover3", "Crossover 3", 500.f, 16000.f, 5000.f, "Hz", "Multiband", false, nullptr, 0);

        static char mbId[4][6][24];
        static char mbName[4][6][32];
        static char mbGroup[4][20];
        for (int b = 0; b < kNumMbBands; ++b) {
            std::snprintf(mbGroup[b], sizeof(mbGroup[b]), "MB Band %d", b + 1);
            const char* fields[6] = {"enable", "thresh", "ratio", "attack", "release", "makeup"};
            const char* names[6]  = {"Enable", "Threshold", "Ratio", "Attack", "Release", "Makeup"};
            for (int f = 0; f < 6; ++f) {
                std::snprintf(mbId[b][f], sizeof(mbId[b][f]), "mb%d%s", b + 1, fields[f]);
                std::snprintf(mbName[b][f], sizeof(mbName[b][f]), "%s", names[f]);
            }
            add(mbId[b][MbEnable],  mbName[b][MbEnable],  0.f,    1.f,   0.f, "bool", mbGroup[b], true,  kBoolChoices, 2);
            add(mbId[b][MbThresh],  mbName[b][MbThresh], -60.f,   0.f, -24.f, "dB",   mbGroup[b], false, nullptr, 0);
            add(mbId[b][MbRatio],   mbName[b][MbRatio],    1.f,   20.f,  2.f, "",     mbGroup[b], false, nullptr, 0);
            add(mbId[b][MbAttack],  mbName[b][MbAttack],   0.1f, 200.f, 10.f, "ms",   mbGroup[b], false, nullptr, 0);
            add(mbId[b][MbRelease], mbName[b][MbRelease],  5.f,  2000.f, 150.f, "ms",  mbGroup[b], false, nullptr, 0);
            add(mbId[b][MbMakeup],  mbName[b][MbMakeup],  -24.f,  24.f,  0.f, "dB",   mbGroup[b], false, nullptr, 0);
        }

        add("satEnable", "Saturation On",  0.f,  1.f,  0.f, "bool", "Saturation", true, kBoolChoices, 2);
        add("satDrive",  "Drive",          0.f, 18.f,  6.f, "dB",   "Saturation", false, nullptr, 0);
        add("satMode",   "Mode",           0.f,  2.f,  0.f, "index","Saturation", true, kSatModeChoices, 3);
        add("satMix",    "Mix",            0.f, 100.f, 100.f, "%",  "Saturation", false, nullptr, 0);

        add("limEnable",    "Limiter On",     0.f,   1.f,  1.f, "bool", "Limiter", true,  kBoolChoices, 2);
        add("limCeiling",   "Ceiling",       -6.f,   0.f, -1.f, "dB",   "Limiter", false, nullptr, 0);
        add("limLookahead", "Lookahead",      1.f,  10.f,  5.f, "ms",   "Limiter", false, nullptr, 0);
        add("limRelease",   "Release",        1.f, 500.f, 50.f, "ms",   "Limiter", false, nullptr, 0);

        add("ditherEnable", "Dither On",      0.f,   1.f,  1.f, "bool", "Output", true, kBoolChoices, 2);

        return d;
    }();
    return table;
}

struct ParamValues {
    float v[P_Count];
    ParamValues() { const ParamDesc* d = paramDescs(); for (uint32_t i = 0; i < P_Count; ++i) v[i] = d[i].defV; }
    float get(uint32_t id) const { return v[id]; }
    void set(uint32_t id, float value) {
        const ParamDesc& d = paramDescs()[id];
        if (value < d.minV) value = d.minV;
        if (value > d.maxV) value = d.maxV;
        v[id] = value;
    }
};

// Lock-free parameter store shared between the AU host thread and the render thread.
struct ParamStore {
    std::atomic<float> v[P_Count];
    void initFromDefaults() {
        const ParamDesc* d = paramDescs();
        for (uint32_t i = 0; i < P_Count; ++i) v[i].store(d[i].defV, std::memory_order_relaxed);
    }
    void set(uint32_t id, float value) { v[id].store(value, std::memory_order_relaxed); }
    float get(uint32_t id) const { return v[id].load(std::memory_order_relaxed); }
    void loadInto(ParamValues& out) const {
        for (uint32_t i = 0; i < P_Count; ++i) out.v[i] = v[i].load(std::memory_order_relaxed);
    }
};

} // namespace mast
