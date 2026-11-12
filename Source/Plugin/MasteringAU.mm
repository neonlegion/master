#import "MasteringAU.h"

#include "../DSP/Engine.h"
#include "../DSP/Presets.h"
#include <cstring>
#include <mutex>
#include <vector>

using namespace mast;

static AudioComponentDescription gComponentDescription = {
    kAudioUnitType_Effect,   // 'aufx'
    'MstA',                  // subtype
    'Vibe',                  // manufacturer
    0, 0
};

@interface MasteringAUAudioUnit () {
    MasteringEngine _engine;
    std::mutex _meterMutex;
    NSDictionary<NSString *, NSNumber *> *_meterSnapshot;
    std::vector<AUParameter *> _flatParams; // index == AUParameterAddress == ParamId
    AudioBufferList *_inputABL;
    std::vector<float> _inL, _inR, _outL, _outR;
    double _sampleRate;
}
@end

@implementation MasteringAUAudioUnitFactory
- (AUAudioUnit *)createAudioUnitWithComponentDescription:(AudioComponentDescription)desc {
    MasteringAUAudioUnit *unit = [[MasteringAUAudioUnit alloc] initWithComponentDescription:desc error:nil];
    return unit;
}
@end

@implementation MasteringAUAudioUnit

+ (AudioComponentDescription)componentDescription {
    return gComponentDescription;
}

- (instancetype)initWithComponentDescription:(AudioComponentDescription)desc
                                     options:(AudioComponentInstantiationOptions)options
                                       error:(NSError **)outError {
    self = [super initWithComponentDescription:desc options:options error:outError];
    if (!self) return nil;

    _sampleRate = 48000.0;
    _engine.setSampleRate(_sampleRate);

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
    self.inputBusArray = @[inputBus];
    self.outputBusArray = @[outputBus];
    self.maximumFramesToRender = 4096;

    [self buildParameterTree];
    [self buildFactoryPresets];
    return self;
}

#pragma mark - Parameters

static AudioUnitParameterUnit unitForString(const char *u) {
    if (!strcmp(u, "dB"))   return kAudioUnitParameterUnit_Decibels;
    if (!strcmp(u, "Hz"))   return kAudioUnitParameterUnit_Hertz;
    if (!strcmp(u, "ms"))   return kAudioUnitParameterUnit_Milliseconds;
    if (!strcmp(u, "%"))    return kAudioUnitParameterUnit_Percent;
    if (!strcmp(u, "bool")) return kAudioUnitParameterUnit_Boolean;
    return kAudioUnitParameterUnit_Indexed;
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
                                                         unitValueStrings:nil
                                                            valueStrings:valueStrings
                                                     dependentParameters:nil];
        p.value = d.defV;
        [flat addObject:p];
        NSString *gn = [NSString stringWithUTF8String:d.group];
        if (!byGroup[gn]) byGroup[gn] = [NSMutableArray array];
        [byGroup[gn] addObject:p];
    }

    NSMutableArray<AUParameterNode *> *groupNodes = [NSMutableArray array];
    for (NSString *gn in byGroup) {
        AUParameterGroup *g = [[AUParameterGroup alloc] initWithIdentifier:gn name:gn children:byGroup[gn]];
        [groupNodes addObject:g];
    }
    AUParameterGroup *root = [[AUParameterGroup alloc] initWithIdentifier:@"root"
                                                                     name:@"MasteringAU"
                                                                  children:groupNodes];
    self.parameterTree = [AUParameterTree createTreeWithRootNode:root];

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
    AVAudioFormat *outFormat = self.outputBus.format;
    _sampleRate = outFormat.sampleRate;
    _engine.setSampleRate(_sampleRate);
    _engine.reset();

    const AUAudioFrameCount maxFrames = self.maximumFramesToRender;
    _inL.assign(maxFrames, 0.0f);
    _inR.assign(maxFrames, 0.0f);
    _outL.assign(maxFrames, 0.0f);
    _outR.assign(maxFrames, 0.0f);

    _inputABL = (AudioBufferList *)calloc(1, sizeof(AudioBufferList) + 2 * sizeof(AudioBuffer));
    _inputABL->mNumberBuffers = 2;
    for (int c = 0; c < 2; ++c) {
        _inputABL->mBuffers[c].mNumberChannels = 1;
        _inputABL->mBuffers[c].mDataByteSize = maxFrames * sizeof(float);
        _inputABL->mBuffers[c].mData = c == 0 ? _inL.data() : _inR.data();
    }

    __weak MasteringAUAudioUnit *weakSelf = self;
    self.internalRenderBlock = ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                                                  const AudioTimeStamp *timestamp,
                                                  AUAudioFrameCount frameCount,
                                                  NSInteger outputBusNumber,
                                                  AudioBufferList *outputData,
                                                  const AURenderEvent *realtimeEventListHead) {
        MasteringAUAudioUnit *strongSelf = weakSelf;
        if (!strongSelf || outputBusNumber != 0 || frameCount > strongSelf->maximumFramesToRender)
            return kAudioUnitErr_TooManyFramesToProcess;

        // Pull input from the upstream unit through the input bus.
        AUAudioUnitBus *inBus = strongSelf.inputBusArray.firstObject;
        AUAudioUnitStatus status = AudioUnitRender(inBus.audioUnit, actionFlags, timestamp,
                                                    inBus.index, frameCount, strongSelf->_inputABL);
        if (status != noErr) {
            // No upstream connection: silence in, still render (meters run).
            memset(strongSelf->_inL.data(), 0, frameCount * sizeof(float));
            memset(strongSelf->_inR.data(), 0, frameCount * sizeof(float));
        }

        // Push host parameter values into the lock-free engine store.
        const ParamDesc *descs = paramDescs();
        for (uint32_t i = 0; i < P_Count; ++i) {
            AUParameter *p = strongSelf->_flatParams[i];
            if (p) strongSelf->_engine.store().set(i, p.value);
        }
        (void)descs;

        const int channels = (int)inBus.format.channelCount;
        float *io[2] = {strongSelf->_outL.data(), strongSelf->_outR.data()};
        // Copy input into out buffers, process in place, copy to outputData.
        for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
            strongSelf->_outL[i] = strongSelf->_inL[i];
            strongSelf->_outR[i] = channels > 1 ? strongSelf->_inR[i] : strongSelf->_inL[i];
        }
        strongSelf->_engine.process(io, channels, (int)frameCount);

        for (AUAudioFrameCount i = 0; i < frameCount; ++i) {
            ((float *)outputData->mBuffers[0].mData)[i] = strongSelf->_outL[i];
            if (outputData->mNumberBuffers > 1)
                ((float *)outputData->mBuffers[1].mData)[i] = strongSelf->_outR[i];
            else if (outputData->mBuffers[0].mNumberChannels == 2) {
                float *inter = (float *)outputData->mBuffers[0].mData;
                inter[2 * i] = strongSelf->_outL[i];
                inter[2 * i + 1] = strongSelf->_outR[i];
            }
        }

        [strongSelf updateMeterSnapshot];
        return noErr;
    };
    return YES;
}

- (void)deallocateRenderResources {
    [super deallocateRenderResources];
    if (_inputABL) { free(_inputABL); _inputABL = nullptr; }
}

- (void)updateMeterSnapshot {
    const Meters &m = _engine.meters();
    NSDictionary *snap = @{
        @"momentaryLUFS":  @(m.momentaryLUFS),
        @"shortTermLUFS":  @(m.shortTermLUFS),
        @"integratedLUFS": @(m.integratedLUFS),
        @"lraLU":          @(m.loudnessRangeLU),
        @"truePeakDbTP":   @(m.truePeakDbTP),
        @"limiterGRDb":    @(m.limiterGRDb),
        @"mbGR0":          @(m.mbGRDb[0]),
        @"mbGR1":          @(m.mbGRDb[1]),
        @"mbGR2":          @(m.mbGRDb[2]),
        @"mbGR3":          @(m.mbGRDb[3]),
    };
    std::lock_guard<std::mutex> lock(_meterMutex);
    _meterSnapshot = snap;
}

- (NSDictionary<NSString *, NSNumber *> *)meterSnapshot {
    std::lock_guard<std::mutex> lock(_meterMutex);
    return _meterSnapshot ?: @{};
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
