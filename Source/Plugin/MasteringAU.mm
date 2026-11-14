// Self-contained AUv3 adapter: the ObjC class declarations live directly in
// this .mm (importing a local .h with ObjC declarations from a .mm derails
// clang's ObjC parsing on some Xcode 15.2 / Ventura setups, so no .h here).
#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
// AudioToolbox.h umbrella includes AUAudioUnit, AUAudioUnitImplementation
// (factory protocol, bus init, parameter-tree factory methods), AUParameters,
// AudioComponent, AudioUnitProperties.
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

// The entire audio path lives in the portable, unit-tested C++ engine
// (Source/DSP/Engine.h); this class is a thin AUv3 adapter: buses,
// parameter tree (including read-only meter parameters), factory presets,
// and latency reporting. (No @objc(name) attribute: with the parenthesized
// name this clang 15 build rejects the token in ObjC++ files; the class name
// already matches, so the attribute is unnecessary.)
@interface MasteringAUAudioUnit : AUAudioUnit
@end

// NSExtension principal class: the host instantiates this and asks it for
// the AUAudioUnit via createAudioUnitWithComponentDescription:error:.
@interface MasteringAUAudioUnitFactory : NSObject <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END

#include "../DSP/Engine.h"
#include "../DSP/Presets.h"
#include <cstring>
#include <vector>

using namespace mast;

// Meter parameter addresses, kept clear of the ParamId range (0..P_Count-1)
// so they never collide with audio parameters.
enum {
    M_Momentary = 1000,
    M_ShortTerm,
    M_Integrated,
    M_LRA,
    M_TruePeak,
    M_LimiterGR,
    M_MbGR0,
    M_MbGR1,
    M_MbGR2,
    M_MbGR3,
    M_MeterCount
};

@interface MasteringAUAudioUnit () {
    MasteringEngine _engine;
    AUAudioUnitBusArray *_inputBusArray;
    AUAudioUnitBusArray *_outputBusArray;
    AUInternalRenderBlock _renderBlock;
    std::vector<AUParameter *> _flatParams; // index == AUParameterAddress == ParamId
    AUParameter *_meterParams[M_MeterCount];
    NSArray<AUAudioUnitPreset *> *_factoryPresets;
    AudioBufferList *_inputABL;
    std::vector<float> _inL, _inR, _inInter, _outL, _outR, _outInter;
    uint32_t _inputChannels;
    bool _inputInterleaved;
    double _sampleRate;
}
// factoryPresets is readonly in the public header; back it with our own ivar
// and override the accessors (a readwrite redeclaration would just warn).
- (NSArray<AUAudioUnitPreset *> *)factoryPresets;
- (void)setFactoryPresets:(NSArray<AUAudioUnitPreset *> *)presets;
@end

@implementation MasteringAUAudioUnitFactory
- (AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc
                                                   error:(NSError **)error {
    return [[MasteringAUAudioUnit alloc] initWithComponentDescription:desc options:0 error:error];
}
// Required by NSExtensionRequestHandling (which AUAudioUnitFactory extends).
// AUv3 instantiation goes through createAudioUnitWithComponentDescription:error:
// over XPC, so the generic extension-request entry point is a no-op here.
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    (void)context;
}
@end

@implementation MasteringAUAudioUnit

- (NSArray<AUAudioUnitPreset *> *)factoryPresets { return _factoryPresets; }
- (void)setFactoryPresets:(NSArray<AUAudioUnitPreset *> *)presets { _factoryPresets = [presets copy]; }

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    _sampleRate = 48000.0;
    _engine.setSampleRate(_sampleRate);
    _inputChannels = 2;
    _inputInterleaved = false;

    // Stereo (or mono) float32 non-interleaved buses.
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                            sampleRate:_sampleRate
                                                              channels:2
                                                           interleaved:NO];
    NSError *err = nil;
    AUAudioUnitBus *inputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:&err];
    AUAudioUnitBus *outputBus = [[AUAudioUnitBus alloc] initWithFormat:format error:&err];
    inputBus.supportedChannelCounts = @[@1, @2];
    outputBus.supportedChannelCounts = @[@1, @2];
    _inputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                             busType:AUAudioUnitBusTypeInput
                                                              busses:@[inputBus]];
    _outputBusArray = [[AUAudioUnitBusArray alloc] initWithAudioUnit:self
                                                              busType:AUAudioUnitBusTypeOutput
                                                               busses:@[outputBus]];
    self.maximumFramesToRender = 4096;

    [self buildParameterTree];
    [self buildFactoryPresets];
    return self;
}

// The base class declares these readonly; subclasses override the getters.
- (AUAudioUnitBusArray *)inputBusses { return _inputBusArray; }
- (AUAudioUnitBusArray *)outputBusses { return _outputBusArray; }

#pragma mark - Parameters

static AudioUnitParameterUnit unitForString(const char *u) {
    if (!strcmp(u, "dB"))   return kAudioUnitParameterUnit_Decibels;
    if (!strcmp(u, "Hz"))   return kAudioUnitParameterUnit_Hertz;
    if (!strcmp(u, "ms"))   return kAudioUnitParameterUnit_Milliseconds;
    if (!strcmp(u, "%"))    return kAudioUnitParameterUnit_Percent;
    if (!strcmp(u, "bool")) return kAudioUnitParameterUnit_Boolean;
    if (!strcmp(u, "index")) return kAudioUnitParameterUnit_Indexed;
    return kAudioUnitParameterUnit_Generic;
}

static AUParameter *makeMeterParam(NSString *identifier, NSString *name,
                                   AUParameterAddress address, float minV, float maxV) {
    AUParameter *p = [AUParameterTree createParameterWithIdentifier:identifier
                                                                name:name
                                                             address:address
                                                                 min:minV
                                                                 max:maxV
                                                                unit:kAudioUnitParameterUnit_Decibels
                                                            unitName:nil
                                                               flags:(kAudioUnitParameterFlag_IsReadable |
                                                                      kAudioUnitParameterFlag_MeterReadOnly)
                                                        valueStrings:nil
                                                 dependentParameters:nil];
    if (!p) NSLog(@"[MasteringAU] meter param creation returned nil: %@", identifier);
    else p.value = minV;
    return p;
}

- (void)buildParameterTree {
    const ParamDesc *descs = paramDescs();
    NSMutableArray<AUParameter *> *flat = [NSMutableArray arrayWithCapacity:P_Count];
    NSMutableArray<AUParameterNode *> *children = [NSMutableArray array];

    for (uint32_t i = 0; i < P_Count; ++i) {
        const ParamDesc &d = descs[i];
        NSString *identifier = [NSString stringWithUTF8String:d.id];
        NSString *name = [NSString stringWithUTF8String:d.name];
        NSArray<NSString *> *valueStrings = nil;
        if (d.choices && strcmp(d.unit, "bool") != 0) {
            NSMutableArray *vs = [NSMutableArray arrayWithCapacity:(NSUInteger)d.numChoices];
            for (int c = 0; c < d.numChoices; ++c) {
                NSString *cs = [NSString stringWithUTF8String:d.choices[c]];
                if (cs) [vs addObject:cs];
                else NSLog(@"[MasteringAU] nil choice string %d for %s", c, d.id);
            }
            valueStrings = vs;
        }
        AUParameter *p = [AUParameterTree createParameterWithIdentifier:identifier
                                                                    name:name
                                                                 address:i
                                                                     min:d.minV
                                                                     max:d.maxV
                                                                    unit:unitForString(d.unit)
                                                                unitName:nil
                                                                   flags:(kAudioUnitParameterFlag_IsReadable |
                                                                          kAudioUnitParameterFlag_IsWritable)
                                                            valueStrings:valueStrings
                                                     dependentParameters:nil];
        if (!p) {
            NSLog(@"[MasteringAU] param creation returned nil: id=%s unit=%s min=%f max=%f choices=%d",
                  d.id, d.unit, (double)d.minV, (double)d.maxV, d.numChoices);
            continue;
        }
        p.value = d.defV;
        [flat addObject:p];
        [children addObject:p];
    }

    AUParameterTree *tree = [AUParameterTree createTreeWithChildren:children];
    if (!tree) NSLog(@"[MasteringAU] parameter tree creation returned nil (%lu children)", (unsigned long)children.count);
    self.parameterTree = tree;

    _flatParams.assign(flat.count, nil);
    for (AUParameter *p in flat) _flatParams[p.address] = p;
}

#pragma mark - Presets

- (void)buildFactoryPresets {
    size_t count = 0;
    const FactoryPreset *presets = factoryPresets(count);
    NSMutableArray<AUAudioUnitPreset *> *arr = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; ++i) {
        AUAudioUnitPreset *p = [[AUAudioUnitPreset alloc] init];
        p.name = [NSString stringWithUTF8String:presets[i].name];
        p.number = (NSInteger)i;
        [arr addObject:p];
    }
    self.factoryPresets = arr;
}

- (void)setCurrentPreset:(AUAudioUnitPreset *)preset {
    [super setCurrentPreset:preset];
    if (preset == nil) return;
    size_t count = 0;
    const FactoryPreset *presets = factoryPresets(count);
    NSInteger idx = preset.number;
    if (idx < 0 || (size_t)idx >= count) return;
    const ParamValues &v = presets[idx].values;
    for (uint32_t i = 0; i < P_Count; ++i) {
        if (_flatParams[i]) _flatParams[i].value = v.v[i];
        _engine.store().set(i, v.v[i]);
    }
}

#pragma mark - Rendering

- (BOOL)allocateRenderResourcesAndReturnError:(NSError **)outError {
    if (![super allocateRenderResourcesAndReturnError:outError]) return NO;

    AUAudioUnitBus *inBus = self.inputBusses[0];
    AVAudioFormat *inFormat = inBus.format;
    _sampleRate = inFormat.sampleRate;
    _inputChannels = (uint32_t)MIN(2, MAX(1, inFormat.channelCount));
    _inputInterleaved =
        !(inFormat.streamDescription->mFormatFlags & kAudioFormatFlagIsNonInterleaved);
    NSLog(@"[MasteringAU] allocate sr=%f ch=%u inter=%d maxFrames=%u",
          _sampleRate, _inputChannels, (int)_inputInterleaved, (unsigned)self.maximumFramesToRender);
    _engine.setSampleRate(_sampleRate);
    _engine.reset();

    AUAudioFrameCount maxFrames = self.maximumFramesToRender;
    if (maxFrames == 0) maxFrames = 4096;
    _inL.assign(maxFrames, 0.0f);
    _inR.assign(maxFrames, 0.0f);
    _inInter.assign((size_t)maxFrames * 2, 0.0f);
    _outL.assign(maxFrames, 0.0f);
    _outR.assign(maxFrames, 0.0f);
    _outInter.assign((size_t)maxFrames * 2, 0.0f);

    if (_inputABL) { free(_inputABL); _inputABL = nullptr; }
    _inputABL = (AudioBufferList *)calloc(1, sizeof(AudioBufferList) + 2 * sizeof(AudioBuffer));
    if (_inputInterleaved) {
        _inputABL->mNumberBuffers = 1;
        _inputABL->mBuffers[0].mNumberChannels = _inputChannels;
        _inputABL->mBuffers[0].mDataByteSize = maxFrames * _inputChannels * sizeof(float);
        _inputABL->mBuffers[0].mData = _inInter.data();
    } else {
        _inputABL->mNumberBuffers = _inputChannels;
        for (uint32_t c = 0; c < _inputChannels; ++c) {
            _inputABL->mBuffers[c].mNumberChannels = 1;
            _inputABL->mBuffers[c].mDataByteSize = maxFrames * sizeof(float);
            _inputABL->mBuffers[c].mData = c == 0 ? _inL.data() : _inR.data();
        }
    }

    for (uint32_t i = 0; i < P_Count; ++i) {
        AUParameter *p = _flatParams[i];
        if (p) _engine.store().set(i, p.value);
    }
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_inputABL) { free(_inputABL); _inputABL = nullptr; }
}

- (AUInternalRenderBlock)internalRenderBlock {
    if (!_renderBlock) {
        __weak MasteringAUAudioUnit *weakSelf = self;
        _renderBlock = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                                          const AudioTimeStamp *timestamp,
                                          AUAudioFrameCount frameCount,
                                          NSInteger outputBusNumber,
                                          AudioBufferList *outputData,
                                          const AURenderEvent *realtimeEventListHead,
                                          AURenderPullInputBlock pullInputBlock) {
            MasteringAUAudioUnit *strongSelf = weakSelf;
            if (!strongSelf || !outputData || outputBusNumber != 0 || !strongSelf->_inputABL)
                return kAudioUnitErr_Uninitialized;
            if (frameCount > strongSelf.maximumFramesToRender)
                return kAudioUnitErr_TooManyFramesToProcess;
            if (frameCount == 0) return noErr;

            // Pull input from upstream through the input bus.
            const uint32_t ch = strongSelf->_inputChannels;
            if (strongSelf->_inputInterleaved) {
                strongSelf->_inputABL->mBuffers[0].mDataByteSize =
                    frameCount * ch * sizeof(float);
            } else {
                for (uint32_t b = 0; b < ch; ++b)
                    strongSelf->_inputABL->mBuffers[b].mDataByteSize = frameCount * sizeof(float);
            }
            AUAudioUnitStatus inStatus = kAudioUnitErr_Uninitialized;
            if (pullInputBlock)
                inStatus = pullInputBlock(actionFlags, timestamp, frameCount, 0,
                                          strongSelf->_inputABL);
            if (inStatus != noErr) {
                memset(strongSelf->_inL.data(), 0, frameCount * sizeof(float));
                memset(strongSelf->_inR.data(), 0, frameCount * sizeof(float));
            } else if (strongSelf->_inputInterleaved) {
                // Read from the ABL's current mData: the host may substitute its own
                // buffers during pullInputBlock instead of honoring ours.
                const float *inter = (const float *)strongSelf->_inputABL->mBuffers[0].mData;
                for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
                    strongSelf->_inL[i] = inter[i * ch];
                    strongSelf->_inR[i] = ch > 1 ? inter[i * ch + 1] : inter[i * ch];
                }
            } else {
                const float *s0 = (const float *)strongSelf->_inputABL->mBuffers[0].mData;
                if (s0 && s0 != strongSelf->_inL.data())
                    memcpy(strongSelf->_inL.data(), s0, frameCount * sizeof(float));
                if (ch > 1) {
                    const float *s1 = (const float *)strongSelf->_inputABL->mBuffers[1].mData;
                    if (s1 && s1 != strongSelf->_inR.data())
                        memcpy(strongSelf->_inR.data(), s1, frameCount * sizeof(float));
                } else {
                    memcpy(strongSelf->_inR.data(), strongSelf->_inL.data(),
                           frameCount * sizeof(float));
                }
            }

            // Push host parameter values into the lock-free engine store.
            for (uint32_t i = 0; i < P_Count; ++i) {
                AUParameter *p = strongSelf->_flatParams[i];
                if (p) strongSelf->_engine.store().set(i, p.value);
            }

            float *outL = strongSelf->_outL.data();
            float *outR = strongSelf->_outR.data();
            memcpy(outL, strongSelf->_inL.data(), frameCount * sizeof(float));
            memcpy(outR, strongSelf->_inR.data(), frameCount * sizeof(float));

            if (!strongSelf.shouldBypassEffect) {
                float *io[2] = { outL, outR };
                strongSelf->_engine.process(io, 2, (int)frameCount);

                const Meters &m = strongSelf->_engine.meters();
                AUParameter *__strong *mp = strongSelf->_meterParams;
                mp[0].value = m.momentaryLUFS;
                mp[1].value = m.shortTermLUFS;
                mp[2].value = m.integratedLUFS;
                mp[3].value = m.loudnessRangeLU;
                mp[4].value = m.truePeakDbTP;
                mp[5].value = m.limiterGRDb;
                mp[6].value = m.mbGRDb[0];
                mp[7].value = m.mbGRDb[1];
                mp[8].value = m.mbGRDb[2];
                mp[9].value = m.mbGRDb[3];
            }

            static int gProbe = 0;
            gProbe++;
            if (gProbe <= 10 || gProbe % 200 == 0) {
                float mIn = 0.f, mOut = 0.f, mPre = 0.f;
                for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
                    float a = strongSelf->_inL[i] < 0 ? -strongSelf->_inL[i] : strongSelf->_inL[i];
                    if (a > mIn) mIn = a;
                    float b = outL[i] < 0 ? -outL[i] : outL[i];
                    if (b > mOut) mOut = b;
                }
                for (UInt32 b = 0; b < outputData->mNumberBuffers; ++b) {
                    AudioBuffer *ab = &outputData->mBuffers[b];
                    if (ab->mData) {
                        const float *fd = (const float *)ab->mData;
                        UInt32 n = frameCount * ab->mNumberChannels;
                        for (UInt32 i = 0; i < n; ++i) {
                            float a = fd[i] < 0 ? -fd[i] : fd[i];
                            if (a > mPre) mPre = a;
                        }
                    }
                }
                NSLog(@"[MasteringAU] render#%d frames=%u ch=%u inter=%d pull=%d bypass=%d maxIn=%f maxOut=%f maxPre=%f buf0=%p inL=%p same=%d outBufs=%u outData=%p",
                      gProbe, (unsigned)frameCount, ch, (int)strongSelf->_inputInterleaved, (int)inStatus,
                      (int)strongSelf.shouldBypassEffect, (double)mIn, (double)mOut, (double)mPre,
                      strongSelf->_inputABL->mBuffers[0].mData, (void *)strongSelf->_inL.data(),
                      (int)(strongSelf->_inputABL->mBuffers[0].mData == (void *)strongSelf->_inL.data()),
                      outputData->mNumberBuffers, (void *)outputData);
            }

            // Write output, honoring the host-provided buffer layout.
            const UInt32 nBuf = outputData->mNumberBuffers;
            for (UInt32 b = 0; b < nBuf; ++b) {
                AudioBuffer *ab = &outputData->mBuffers[b];
                if (ab->mNumberChannels <= 1 || nBuf > 1) {
                    const float *src = (b == 0) ? outL : outR;
                    if (!ab->mData) {
                        ab->mData = (void *)src;
                        ab->mDataByteSize = frameCount * sizeof(float);
                    } else {
                        memcpy(ab->mData, src, frameCount * sizeof(float));
                    }
                } else {
                    // Single interleaved buffer with 2+ channels.
                    const UInt32 nc = ab->mNumberChannels;
                    float *dst;
                    if (ab->mData) {
                        dst = (float *)ab->mData;
                    } else {
                        ab->mData = strongSelf->_outInter.data();
                        ab->mDataByteSize = frameCount * nc * sizeof(float);
                        dst = strongSelf->_outInter.data();
                    }
                    for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
                        dst[i * nc] = outL[i];
                        if (nc > 1) dst[i * nc + 1] = outR[i];
                    }
                }
            }
            return noErr;
        };
    }
    return _renderBlock;
}

#pragma mark - Capabilities / latency

- (NSArray<NSNumber *> *)channelCapabilities {
    // Flattened (input, output) channel-count pairs: mono->mono, stereo->stereo.
    return @[@1, @1, @2, @2];
}

- (BOOL)canProcessInPlace {
    // NO: with in-place rendering the host delivers input inside outputData and the
    // pull path yields zeros; non-in-place forces input delivery via pullInputBlock.
    return NO;
}

- (NSTimeInterval)latency {
    return _engine.latencySamples() / _sampleRate;
}

- (NSTimeInterval)tailTime {
    return 0.0;
}

@end
