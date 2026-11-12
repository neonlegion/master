#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
// The AudioToolbox umbrella pulls in the full AUv3 API: AUAudioUnit,
// AUAudioUnitImplementation (AUAudioUnitFactory protocol, AUAudioUnitBus init,
// parameter-tree factory methods), AUParameters, AudioComponent,
// AudioUnitProperties (parameter flags, error codes, ...).
#import <AudioToolbox/AudioToolbox.h>
#if __has_include(<AudioToolboxCore/AUAudioUnitImplementation.h>)
#import <AudioToolboxCore/AUAudioUnitImplementation.h>
#endif

NS_ASSUME_NONNULL_BEGIN

// MasteringAU — AUv3 effect for Logic Pro (and any AUv3 host).
// The entire audio path lives in the portable, unit-tested C++ engine
// (Source/DSP/Engine.h); this class is a thin AUv3 adapter: buses,
// parameter tree (including read-only meter parameters), factory
// presets, and latency reporting.
@objc(MasteringAUAudioUnit)
@interface MasteringAUAudioUnit : AUAudioUnit
@end

// NSExtension principal class: the host instantiates this and asks it
// for the AUAudioUnit via createAudioUnitWithComponentDescription:error:.
@interface MasteringAUAudioUnitFactory : NSObject <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END
