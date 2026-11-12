#pragma once

#include "Parameters.h"

namespace mast {

struct FactoryPreset {
    const char* name;
    ParamValues values;
};

// Factory presets, shared by the AU wrapper and the offline renderer.
inline const FactoryPreset* factoryPresets(size_t& count) {
    static const FactoryPreset presets[] = {
        { "Init (Default)", [] {
            ParamValues v;
            return v;
        }() },
        { "Streaming -14 LUFS", [] {
            ParamValues v;
            v.set(P_LimCeiling, -1.0f);
            v.set(P_LimRelease, 80.0f);
            v.set(eqParam(0, EqEnable), 1.0f);
            v.set(eqParam(0, EqType), (float)EqLowShelf);
            v.set(eqParam(0, EqFreq), 70.0f);
            v.set(eqParam(0, EqGain), 1.5f);
            v.set(eqParam(5, EqEnable), 1.0f);
            v.set(eqParam(5, EqType), (float)EqHighShelf);
            v.set(eqParam(5, EqFreq), 11000.0f);
            v.set(eqParam(5, EqGain), 1.5f);
            v.set(mbParam(0, MbEnable), 1.0f);
            v.set(mbParam(0, MbThresh), -20.0f);
            v.set(mbParam(0, MbRatio), 2.0f);
            v.set(mbParam(0, MbRelease), 200.0f);
            v.set(mbParam(3, MbEnable), 1.0f);
            v.set(mbParam(3, MbThresh), -22.0f);
            v.set(mbParam(3, MbRatio), 3.0f);
            v.set(mbParam(3, MbAttack), 5.0f);
            v.set(mbParam(3, MbRelease), 120.0f);
            return v;
        }() },
        { "Loud -9 LUFS", [] {
            ParamValues v;
            v.set(P_LimCeiling, -0.5f);
            v.set(P_LimRelease, 40.0f);
            v.set(P_SatEnable, 1.0f);
            v.set(P_SatDrive, 4.0f);
            v.set(P_SatMode, (float)SatClean);
            v.set(eqParam(0, EqEnable), 1.0f);
            v.set(eqParam(0, EqType), (float)EqLowShelf);
            v.set(eqParam(0, EqFreq), 60.0f);
            v.set(eqParam(0, EqGain), 2.0f);
            v.set(mbParam(0, MbEnable), 1.0f);
            v.set(mbParam(0, MbThresh), -16.0f);
            v.set(mbParam(0, MbRatio), 3.0f);
            v.set(mbParam(1, MbEnable), 1.0f);
            v.set(mbParam(1, MbThresh), -14.0f);
            v.set(mbParam(1, MbRatio), 4.0f);
            v.set(mbParam(2, MbEnable), 1.0f);
            v.set(mbParam(2, MbThresh), -14.0f);
            v.set(mbParam(2, MbRatio), 4.0f);
            v.set(mbParam(3, MbEnable), 1.0f);
            v.set(mbParam(3, MbThresh), -18.0f);
            v.set(mbParam(3, MbRatio), 6.0f);
            v.set(mbParam(3, MbAttack), 3.0f);
            v.set(mbParam(3, MbRelease), 80.0f);
            return v;
        }() },
        { "Air & Warmth", [] {
            ParamValues v;
            v.set(P_HpEnable, 1.0f);
            v.set(P_HpFreq, 25.0f);
            v.set(P_LimCeiling, -1.0f);
            v.set(P_SatEnable, 1.0f);
            v.set(P_SatDrive, 3.0f);
            v.set(P_SatMode, (float)SatTape);
            v.set(P_SatMix, 30.0f);
            v.set(eqParam(5, EqEnable), 1.0f);
            v.set(eqParam(5, EqType), (float)EqHighShelf);
            v.set(eqParam(5, EqFreq), 12000.0f);
            v.set(eqParam(5, EqGain), 2.5f);
            v.set(eqParam(3, EqEnable), 1.0f);
            v.set(eqParam(3, EqType), (float)EqPeak);
            v.set(eqParam(3, EqFreq), 3500.0f);
            v.set(eqParam(3, EqGain), -1.5f);
            v.set(eqParam(3, EqQ), 1.2f);
            return v;
        }() },
        { "Vinyl Prep", [] {
            ParamValues v;
            v.set(P_HpEnable, 1.0f);
            v.set(P_HpFreq, 30.0f);
            v.set(P_MonoLowEnable, 1.0f);
            v.set(P_MonoLowFreq, 120.0f);
            v.set(P_Width, -1.0f);
            v.set(P_LimCeiling, -1.5f);
            v.set(P_LimRelease, 100.0f);
            v.set(mbParam(0, MbEnable), 1.0f);
            v.set(mbParam(0, MbThresh), -18.0f);
            v.set(mbParam(0, MbRatio), 2.5f);
            v.set(mbParam(0, MbMakeup), 1.0f);
            return v;
        }() },
    };
    count = sizeof(presets) / sizeof(presets[0]);
    return presets;
}

} // namespace mast
