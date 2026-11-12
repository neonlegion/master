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
    AudioBufferList *_inputABL;
    std::vector<float> _inL, _inR, _inInter, _outL, _outR, _outInter;
    uint32_t _inputChannels;
    bool _inputInterleaved;
    double _sampleRate;
}
// factoryPresets is readonly in the public header; redeclare readwrite here.
@property (nonatomic, readwrite, copy) NSArray<AUAudioUnitPreset *> *factoryPresets;
@end

@implementation MasteringAUAudioUnitFactory
- (AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc
                                                   error:(NSError **)error {
    return [[MasteringAUAudioUnit alloc] initWithComponentDescription:desc options:0 error:error];
}
@end

@implementation MasteringAUAudioUnit

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
    return kAudioUnitParameterUnit_Indexed;
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
    p.value = minV;
    return p;
}

- (void)buildParameterTree {
    const ParamDesc *descs = paramDescs();
    NSMutableArray<AUParameter *> *flat = [NSMutableArray arrayWithCapacity:P_Count];
    NSMutableDictionary<NSString *, NSMutableArray<AUParameter *> *> *byGroup =
        [NSMutableDictionary dictionary];

    for (uint32_t i = 0; i < P_Count; ++i) {
        const ParamDesc &d = descs[i];
        NSString *identifier = [NSString stringWithUTF8String:d.id];
        NSString *name = [NSString stringWithUTF8String:d.name];
        NSArray<NSString *> *valueStrings = nil;
        if (d.choices) {
            NSMutableArray *vs = [NSMutableArray arrayWithCapacity:(NSUInteger)d.numChoices];
            for (int c = 0; c < d.numChoices; ++c)
                [vs addObject:[NSString stringWithUTF8String:d.choices[c]]];
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
        p.value = d.defV;
        [flat addObject:p];
        NSString *gn = [NSString stringWithUTF8String:d.group];
        if (!byGroup[gn]) byGroup[gn] = [NSMutableArray array];
        [byGroup[gn] addObject:p];
    }

    // Read-only meter parameters: hosts (e.g. Logic's generic AU view)
    // display these as live meters. Updated on the render thread.
    AUParameter *m[M_MeterCount] = {
        makeMeterParam(@"meterMomentary",  @"Momentary",   M_Momentary,  -120.f, 24.f),
        makeMeterParam(@"meterShortTerm",  @"Short-term",  M_ShortTerm,  -120.f, 24.f),
        makeMeterParam(@"meterIntegrated", @"Integrated",  M_Integrated, -120.f, 24.f),
        makeMeterParam(@"meterLRA",        @"LRA",         M_LRA,          0.f,  60.f),
        makeMeterParam(@"meterTruePeak",   @"True peak",   M_TruePeak,  -120.f, 24.f),
        makeMeterParam(@"meterLimiterGR",  @"Limiter GR",  M_LimiterGR, -60.f,  0.f),
        makeMeterParam(@"meterMbGR0",      @"MB GR 1",     M_MbGR0,     -60.f,  0.f),
        makeMeterParam(@"meterMbGR1",      @"MB GR 2",     M_MbGR1,     -60.f,  0.f),
        makeMeterParam(@"meterMbGR2",      @"MB GR 3",     M_MbGR2,     -60.f,  0.f),
        makeMeterParam(@"meterMbGR3",      @"MB GR 4",     M_MbGR3,     -60.f,  0.f),
    };
    NSMutableArray<AUParameter *> *meterGroup = [NSMutableArray arrayWithCapacity:M_MeterCount];
    for (int k = 0; k < M_MeterCount; ++k) {
        _meterParams[k] = m[k];
        [meterGroup addObject:m[k]];
    }

    NSMutableArray<AUParameterNode *> *children = [NSMutableArray array];
    for (NSString *gn in [byGroup.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [children addObject:[AUParameterTree createGroupWithIdentifier:gn name:gn children:byGroup[gn]]];
    }
    [children addObject:[AUParameterTree createGroupWithIdentifier:@"Meters"
                                                              name:@"Meters"
                                                          children:meterGroup]];
    self.parameterTree = [AUParameterTree createTreeWithChildren:children];

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
            if (frameCount > strongSelf->maximumFramesToRender)
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
                const float *inter = strongSelf->_inInter.data();
                for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
                    strongSelf->_inL[i] = inter[i * ch];
                    strongSelf->_inR[i] = ch > 1 ? inter[i * ch + 1] : inter[i * ch];
                }
            } else if (ch == 1) {
                memcpy(strongSelf->_inR.data(), strongSelf->_inL.data(),
                       frameCount * sizeof(float));
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
                AUParameter **mp = strongSelf->_meterParams;
                mp[0]->value = m.momentaryLUFS;
                mp[1]->value = m.shortTermLUFS;
                mp[2]->value = m.integratedLUFS;
                mp[3]->value = m.loudnessRangeLU;
                mp[4]->value = m.truePeakDbTP;
                mp[5]->value = m.limiterGRDb;
                mp[6]->value = m.mbGRDb[0];
                mp[7]->value = m.mbGRDb[1];
                mp[8]->value = m.mbGRDb[2];
                mp[9]->value = m.mbGRDb[3];
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
    return @[@1, @2]; // mono + stereo
}

- (BOOL)canProcessInPlace {
    return YES;
}

- (NSTimeInterval)latency {
    return _engine.latencySamples() / _sampleRate;
}

- (NSTimeInterval)tailTime {
    return 0.0;
}

@end
