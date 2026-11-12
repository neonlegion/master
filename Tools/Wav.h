#pragma once

// Minimal RIFF/WAVE reader-writer for PCM 16/24/32-bit int and 32-bit float.
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>
#include <string>
#include <cmath>

namespace wav {

struct File {
    uint32_t sampleRate = 48000;
    int channels = 2;
    int bitsPerSample = 32; // 16, 24, 32(int), or 0 => float32
    bool isFloat = false;
    std::vector<float> data; // interleaved
};

inline uint32_t rdU32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
inline uint16_t rdU16(const uint8_t* p) { return p[0] | (p[1] << 8); }
inline void wrU32(std::vector<uint8_t>& b, uint32_t v) {
    b.push_back(v & 0xff); b.push_back((v >> 8) & 0xff); b.push_back((v >> 16) & 0xff); b.push_back((v >> 24) & 0xff);
}
inline void wrU16(std::vector<uint8_t>& b, uint16_t v) { b.push_back(v & 0xff); b.push_back((v >> 8) & 0xff); }

inline bool read(const std::string& path, File& f, std::string* err = nullptr) {
    FILE* fp = std::fopen(path.c_str(), "rb");
    if (!fp) { if (err) *err = "cannot open " + path; return false; }
    std::vector<uint8_t> buf;
    uint8_t tmp[65536];
    size_t r;
    while ((r = std::fread(tmp, 1, sizeof(tmp), fp)) > 0) buf.insert(buf.end(), tmp, tmp + r);
    std::fclose(fp);
    if (buf.size() < 44 || std::memcmp(buf.data(), "RIFF", 4) || std::memcmp(buf.data() + 8, "WAVE", 4)) {
        if (err) *err = "not a RIFF/WAVE file";
        return false;
    }
    size_t pos = 12;
    const uint8_t* fmt = nullptr;
    const uint8_t* dat = nullptr;
    size_t datLen = 0;
    while (pos + 8 <= buf.size()) {
        uint32_t id = rdU32(buf.data() + pos);
        uint32_t sz = rdU32(buf.data() + pos + 4);
        const uint8_t* body = buf.data() + pos + 8;
        if (id == 0x20746d66) { fmt = body; }                     // 'fmt '
        else if (id == 0x61746164) { dat = body; datLen = sz; }   // 'data'
        pos += 8 + sz + (sz & 1);
    }
    if (!fmt || !dat) { if (err) *err = "missing fmt/data chunk"; return false; }
    uint16_t audioFormat = rdU16(fmt);
    f.channels = rdU16(fmt + 2);
    f.sampleRate = rdU32(fmt + 4);
    f.bitsPerSample = rdU16(fmt + 14);
    f.isFloat = (audioFormat == 3 && f.bitsPerSample == 32);
    int bytesPerSample = f.bitsPerSample / 8;
    if (f.isFloat) bytesPerSample = 4;
    size_t frames = datLen / (size_t)(bytesPerSample * f.channels);
    f.data.resize(frames * f.channels);
    for (size_t i = 0; i < frames * f.channels; ++i) {
        const uint8_t* p = dat + i * bytesPerSample;
        if (f.isFloat) {
            uint32_t u = rdU32(p);
            float v;
            std::memcpy(&v, &u, 4);
            f.data[i] = v;
        } else if (f.bitsPerSample == 16) {
            int16_t s = (int16_t)rdU16(p);
            f.data[i] = s / 32768.0f;
        } else if (f.bitsPerSample == 24) {
            int32_t s = p[0] | (p[1] << 8) | (p[2] << 16);
            if (s & 0x800000) s |= ~0xFFFFFF;
            f.data[i] = s / 8388608.0f;
        } else if (f.bitsPerSample == 32) {
            int32_t s = (int32_t)rdU32(p);
            f.data[i] = s / 2147483648.0;
        } else {
            if (err) *err = "unsupported bit depth";
            return false;
        }
    }
    return true;
}

inline bool write(const std::string& path, const File& f, std::string* err = nullptr) {
    std::vector<uint8_t> out;
    auto tag = [&](const char* t) { out.insert(out.end(), t, t + 4); };
    int bytesPerSample = f.isFloat ? 4 : f.bitsPerSample / 8;
    uint32_t dataSize = (uint32_t)(f.data.size() * bytesPerSample);
    tag("RIFF");
    wrU32(out, 36 + dataSize);
    tag("WAVE");
    tag("fmt ");
    wrU32(out, 16);
    wrU16(out, f.isFloat ? 3 : 1);
    wrU16(out, (uint16_t)f.channels);
    wrU32(out, f.sampleRate);
    wrU32(out, f.sampleRate * f.channels * bytesPerSample);
    wrU16(out, (uint16_t)(f.channels * bytesPerSample));
    wrU16(out, (uint16_t)f.bitsPerSample);
    tag("data");
    wrU32(out, dataSize);
    for (float v : f.data) {
        if (f.isFloat) {
            uint32_t u;
            std::memcpy(&u, &v, 4);
            wrU32(out, u);
        } else if (f.bitsPerSample == 16) {
            int16_t s = (int16_t)std::lround(std::max(-1.0f, std::min(1.0f, v)) * 32767.0f);
            wrU16(out, (uint16_t)s);
        } else if (f.bitsPerSample == 24) {
            int32_t s = (int32_t)std::lround(std::max(-1.0f, std::min(1.0f, v)) * 8388607.0f);
            out.push_back(s & 0xff); out.push_back((s >> 8) & 0xff); out.push_back((s >> 16) & 0xff);
        } else {
            int32_t s = (int32_t)std::lround(std::max(-1.0f, std::min(1.0f, v)) * 2147483647.0);
            wrU32(out, (uint32_t)s);
        }
    }
    FILE* fp = std::fopen(path.c_str(), "wb");
    if (!fp) { if (err) *err = "cannot write " + path; return false; }
    std::fwrite(out.data(), 1, out.size(), fp);
    std::fclose(fp);
    return true;
}

} // namespace wav
