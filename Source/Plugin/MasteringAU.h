#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
// AUv3 Obj-C API (AUAudioUnit, AUAudioUnitFactory, AUParameterTree, ...) lives in
// the AudioUnit framework on current SDKs; AudioToolbox/AudioToolboxCore on older
// ones. Import whichever is present. AudioUnit/AudioUnit.h also provides the C API
// (AudioComponentDescription, AudioUnitRender, kAudioUnitType_Effect, ...).
#if __has_include(<AudioUnit/AUAudioUnit.h>)
#import <AudioUnit/AUAudioUnit.h>
#else
#import <AudioUnit/AudioUnit.h>
#endif
#import <AudioToolbox/AudioToolbox.h>
#if __has_include(<AudioToolboxCore/AudioToolboxCore.h>)
#import <AudioToolboxCore/AudioToolboxCore.h>
#elif __has_include(<AudioToolboxCore/AUAudioUnit.h>)
#import <AudioToolboxCore/AUAudioUnit.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// MasteringAU — AUv3 audio unit for Logic Pro (and any AUv3 host).
// The entire audio path lives in the portable, unit-tested C++ engine
// (Source/DSP/Engine.h); this class is a thin AUv3 adapter: buses,
// parameter tree, presets, latency and metering.
@objc(MasteringAUAudioUnit)
@interface MasteringAUAudioUnit : AUAudioUnit
// Read-only snapshot for the custom view, updated on the render thread.
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *meterSnapshot;
@end

// NSExtension principal class: vended to the host by the AUv3 factory.
@interface MasteringAUAudioUnitFactory : NSObject <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END
