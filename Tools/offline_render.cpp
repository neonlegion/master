// Offline renderer: process a WAV through the mastering engine with a factory
// preset (or default params) and write the result. Useful for A/B listening
// and for CI-style regression renders.
//
// Usage: offline_render <in.wav> <out.wav> [presetIndex] [--float]
#include "../Source/DSP/Engine.h"
#include "../Source/DSP/Presets.h"
#include "Wav.h"
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>

using namespace mast;

int main(int argc, char** argv) {
    if (argc < 3) {
        printf("usage: %s <in.wav> <out.wav> [presetIndex=0] [--float]\n", argv[0]);
        size_t n = 0;
        const FactoryPreset* p = factoryPresets(n);
        for (size_t i = 0; i < n; ++i) printf("  [%zu] %s\n", i, p[i].name);
        return 1;
    }
    wav::File in;
    std::string err;
    if (!wav::read(argv[1], in, &err)) { fprintf(stderr, "read error: %s\n", err.c_str()); return 1; }
    int presetIdx = argc > 3 ? std::atoi(argv[3]) : 0;
    bool outFloat = argc > 4 && std::strcmp(argv[4], "--float") == 0;

    MasteringEngine engine;
    engine.setSampleRate(in.sampleRate);
    size_t nPresets = 0;
    const FactoryPreset* presets = factoryPresets(nPresets);
    if (presetIdx < 0 || (size_t)presetIdx >= nPresets) { fprintf(stderr, "bad preset index\n"); return 1; }
    const ParamValues& pv = presets[presetIdx].values;
    for (uint32_t i = 0; i < P_Count; ++i) engine.store().set(i, pv.v[i]);
    printf("preset: %s | %u Hz, %d ch, %zu frames, latency %.1f samples\n",
           presets[presetIdx].name, in.sampleRate, in.channels, in.data.size() / in.channels,
           engine.latencySamples());

    const int ch = in.channels;
    std::vector<float> l(in.data.size() / ch), r(ch == 2 ? in.data.size() / ch : 0);
    for (size_t i = 0; i < in.data.size() / ch; ++i) {
        l[i] = in.data[i * ch];
        if (ch == 2) r[i] = in.data[i * ch + 1];
    }
    float* io[2] = {l.data(), ch == 2 ? r.data() : nullptr};
    const int block = 512;
    int total = (int)l.size();
    for (int i = 0; i < total; i += block) engine.process(io, ch, std::min(block, total - i));

    const Meters& m = engine.meters();
    printf("result: integrated %.2f LUFS | short-term %.2f LUFS | LRA %.2f LU | true peak %.2f dBTP | max GR %.2f dB\n",
           m.integratedLUFS, m.shortTermLUFS, m.loudnessRangeLU, m.truePeakDbTP, m.limiterGRDb);

    wav::File out;
    out.sampleRate = in.sampleRate;
    out.channels = ch;
    out.isFloat = outFloat;
    out.bitsPerSample = outFloat ? 32 : 24;
    out.data.resize(in.data.size());
    for (size_t i = 0; i < l.size(); ++i) {
        out.data[i * ch] = l[i];
        if (ch == 2) out.data[i * ch + 1] = r[i];
    }
    if (!wav::write(argv[2], out, &err)) { fprintf(stderr, "write error: %s\n", err.c_str()); return 1; }
    printf("wrote %s\n", argv[2]);
    return 0;
}
