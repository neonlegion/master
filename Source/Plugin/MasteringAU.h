#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import <Foundation/Foundation.h>

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
