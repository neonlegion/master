// Guarded with __OBJC__ so the file is a harmless empty translation unit if a
// stale/wrong Xcode project ever lists this header in Compile Sources (it
// would then be compiled as plain C, where '@' is a syntax error).
#ifdef __OBJC__

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
// The AudioToolbox umbrella pulls in the full AUv3 API: AUAudioUnit,
// AUAudioUnitImplementation (AUAudioUnitFactory protocol, AUAudioUnitBus init,
// parameter-tree factory methods), AUParameters, AudioComponent,
// AudioUnitProperties (parameter flags, error codes, ...).
#import <AudioToolbox/AudioToolbox.h>
// (AudioToolbox.h's umbrella already includes AUAudioUnitImplementation.h;
// do NOT import <AudioToolboxCore/...> directly — on the macOS SDK that
// header derails ObjC++ parsing of the rest of this file.)

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

#endif // __OBJC__
