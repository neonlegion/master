// MasteringAU: AUv3 audio unit for Logic Pro.
// Guarded with __OBJC__ so this file is an empty translation unit if a stale
// Xcode project ever lists it in Compile Sources (it would be compiled as
// plain C, where ObjC at-signs are syntax errors). Keep this file pure ASCII.
#ifdef __OBJC__

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
// and latency reporting.
@objc(MasteringAUAudioUnit)
@interface MasteringAUAudioUnit : AUAudioUnit
@end

// NSExtension principal class: the host instantiates this and asks it for
// the AUAudioUnit via createAudioUnitWithComponentDescription:error:.
@interface MasteringAUAudioUnitFactory : NSObject <AUAudioUnitFactory>
@end

NS_ASSUME_NONNULL_END

#endif // __OBJC__
