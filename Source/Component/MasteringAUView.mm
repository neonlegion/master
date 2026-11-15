// Cocoa UI for the MasteringAU AUv2 component. Loaded by the host through
// kAudioUnitProperty_CocoaUI (class MasteringAUViewFactory, conforming to
// AUCocoaUIBase). All controls are bound to AU parameters in the global scope
// via AudioUnitGet/SetParameter; meters are read-only parameters (ids 1000+)
// refreshed by a 30 Hz timer. No UI code may ever throw into the host: all
// drawing and actions are wrapped in @try/@catch.

#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioToolbox/AUCocoaUIView.h>
#import <CoreFoundation/CoreFoundation.h>
#include <cmath>
#include <cstring>
#include "../DSP/Parameters.h"

using namespace mast;

// Meter parameter ids, must match MasteringAUv2.cpp (id = 1000 + j).
enum {
    kMeterBase = 1000,
    kMeterMomentary = kMeterBase,
    kMeterShortTerm,
    kMeterIntegrated,
    kMeterLRA,
    kMeterTruePeak,
    kMeterLimGR,
    kMeterMbGR0,
    kMeterMbGR1,
    kMeterMbGR2,
    kMeterMbGR3,
    kNumMeters = 10
};

// Palette
static NSColor* colBg(void)     { return [NSColor colorWithCalibratedWhite:0.070 alpha:1.0]; }
static NSColor* colCard(void)   { return [NSColor colorWithCalibratedWhite:0.115 alpha:1.0]; }
static NSColor* colCardEdge(void){ return [NSColor colorWithCalibratedWhite:0.24 alpha:1.0]; }
static NSColor* colText(void)   { return [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]; }
static NSColor* colDim(void)    { return [NSColor colorWithCalibratedWhite:0.52 alpha:1.0]; }
static NSColor* colAccent(void) { return [NSColor colorWithCalibratedRed:0.20 green:0.60 blue:1.0 alpha:1.0]; }
static NSColor* colWarn(void)   { return [NSColor colorWithCalibratedRed:1.0 green:0.42 blue:0.18 alpha:1.0]; }
static NSColor* colGood(void)   { return [NSColor colorWithCalibratedRed:0.25 green:0.80 blue:0.45 alpha:1.0]; }

// Horizontal meter bar. Primitive ivars only (no object ivars). style:
// 0 = accent fill, 1 = warn fill (inverted), 2 = LUFS bar with zones.
@interface BarView : NSView {
@public
    float level;
    float minV, maxV;
    BOOL inverted;
    int style;
}
@end
@implementation BarView
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) { minV = 0; maxV = 1; level = 0; inverted = NO; style = 0; }
    return self;
}
- (void)drawRect:(NSRect)dirty {
    @try {
        NSRect r = self.bounds;
        [[NSColor colorWithCalibratedWhite:0.04 alpha:1.0] setFill];
        NSRectFill(r);
        float frac = (maxV > minV) ? (level - minV) / (maxV - minV) : 0.0f;
        if (frac < 0) frac = 0; if (frac > 1) frac = 1;
        if (inverted) frac = 1.0f - frac;
        CGFloat w = (r.size.width - 2) * frac;
        NSRect fill = NSMakeRect(r.origin.x + 1, r.origin.y + 1, w, r.size.height - 2);
        if (style == 2) {
            // LUFS zones: -36..-18 green, -18..-6 amber, -6..+3 red (of minV..maxV)
            CGFloat x0 = r.origin.x + 1, y0 = r.origin.y + 1, h = r.size.height - 2;
            CGFloat span = r.size.width - 2;
            float z1 = (float)((-18.0 - minV) / (maxV - minV));
            float z2 = (float)((-6.0 - minV) / (maxV - minV));
            [colGood setFill];  NSRectFill(NSMakeRect(x0, y0, span * z1, h));
            [[NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.15 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x0 + span * z1, y0, span * (z2 - z1), h));
            [colWarn setFill];  NSRectFill(NSMakeRect(x0 + span * z2, y0, span * (1.0f - z2), h));
            // level marker
            [[NSColor whiteColor] setFill];
            NSRectFill(NSMakeRect(x0 + w - 1, y0, 2, h));
        } else {
            NSColor* c = (style == 1) ? colWarn() : colAccent();
            [c setFill];
            NSRectFill(fill);
        }
        [[NSColor colorWithCalibratedWhite:0.30 alpha:1.0] setStroke];
        [[NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)] stroke];
    } @catch (NSException* e) {
        // never crash the host from UI drawing
    }
}
@end

// Small circular "logo" dot.
@interface DotView : NSView
@end
@implementation DotView
- (void)drawRect:(NSRect)dirty {
    @try {
        NSRect r = NSInsetRect(self.bounds, 2, 2);
        NSBezierPath* p = [NSBezierPath bezierPathWithOvalInRect:r];
        [colAccent() setFill];
        [p fill];
        [[NSColor whiteColor] setStroke];
        [p setLineWidth: 1.5];
        [p stroke];
    } @catch (NSException* e) {}
}
@end

@interface MasteringAUView : NSView {
    AudioUnit _au;
    NSTimer* _timer;
    NSMutableDictionary* _sliders;      // @(pid) -> NSSlider
    NSMutableDictionary* _valueLabels;  // @(pid) -> NSTextField
    NSMutableDictionary* _checks;       // @(pid) -> NSButton
    NSMutableDictionary* _popups;       // @(pid) -> NSPopUpButton
    NSPopUpButton* _presetPopup;
    NSTextField* _statusLabel;
    NSTextField* _intLabel;
    NSMutableDictionary* _meterLabels;  // @(id) -> NSTextField
    NSMutableArray* _meterBars;         // BarView list (first = LUFS)
    NSMutableDictionary* _grBars;       // @(id) -> BarView
}
- (instancetype)initWithFrame:(NSRect)frame audioUnit:(AudioUnit)au;
- (CGFloat)section:(NSString*)name atY:(CGFloat)y x:(CGFloat)x w:(CGFloat)w;
@end

@implementation MasteringAUView

- (instancetype)initWithFrame:(NSRect)frame audioUnit:(AudioUnit)au {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _au = au;
    _sliders = [NSMutableDictionary new];
    _valueLabels = [NSMutableDictionary new];
    _checks = [NSMutableDictionary new];
    _popups = [NSMutableDictionary new];
    _meterLabels = [NSMutableDictionary new];
    _meterBars = [NSMutableArray new];
    _grBars = [NSMutableDictionary new];
    self.wantsLayer = YES;
    self.layer.backgroundColor = colBg().CGColor;
    @try {
        [self buildUI];
        [self refreshControls];
    } @catch (NSException* e) {
        // never let UI construction throw into the host
    }
    _timer = [NSTimer scheduledTimerWithTimeInterval:1.0/30.0 target:self
                                            selector:@selector(tick:) userInfo:nil repeats:YES];
    return self;
}

- (void)dealloc {
    [_timer invalidate];
    [_presetPopup release];
    [_sliders release];
    [_valueLabels release];
    [_checks release];
    [_popups release];
    [_meterLabels release];
    [_meterBars release];
    [_grBars release];
    [super dealloc];
}

#pragma mark - helpers

- (NSTextField*)makeLabel:(NSString*)s frame:(NSRect)r size:(CGFloat)fs bold:(BOOL)bold color:(NSColor*)c {
    NSTextField* t = [[NSTextField alloc] initWithFrame:r];
    t.stringValue = s;
    t.bezeled = NO; t.drawsBackground = NO; t.editable = NO; t.selectable = NO;
    t.textColor = c;
    t.font = bold ? [NSFont boldSystemFontOfSize:fs] : [NSFont systemFontOfSize:fs];
    t.alignment = NSLeftTextAlignment;
    [self addSubview:t];
    return [t autorelease];
}

- (NSView*)cardWithFrame:(NSRect)r title:(NSString*)title {
    NSView* card = [[NSView alloc] initWithFrame:r];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10;
    card.layer.backgroundColor = colCard().CGColor;
    card.layer.borderColor = colCardEdge().CGColor;
    card.layer.borderWidth = 1.0;
    [self addSubview:card];
    [self makeLabel:title frame:NSMakeRect(r.origin.x + 12, r.origin.y + r.size.height - 20,
                                           r.size.width - 24, 15)
               size:11 bold:YES color:colAccent()];
    [card release];
    return card;
}

- (void)updateValueLabel:(uint32_t)pid value:(float)v {
    NSTextField* l = _valueLabels[@(pid)];
    if (l) l.stringValue = [self formatValue:pid value:v];
}

- (NSString*)formatValue:(uint32_t)pid value:(float)v {
    if (pid >= P_Count) return [NSString stringWithFormat:@"%.1f", v];
    const ParamDesc& d = paramDescs()[pid];
    if (d.choices && d.numChoices > 0) {
        int idx = (int)lrintf(v);
        if (idx < 0) idx = 0;
        if (idx >= d.numChoices) idx = d.numChoices - 1;
        return [NSString stringWithUTF8String:d.choices[idx]];
    }
    if (!strcmp(d.unit, "dB")) return [NSString stringWithFormat:@"%.1f dB", (double)v];
    if (!strcmp(d.unit, "Hz")) return v >= 1000.0f
        ? [NSString stringWithFormat:@"%.2f kHz", (double)(v / 1000.0f)]
        : [NSString stringWithFormat:@"%.0f Hz", (double)v];
    if (!strcmp(d.unit, "ms")) return [NSString stringWithFormat:@"%.1f ms", (double)v];
    if (!strcmp(d.unit, "%"))  return [NSString stringWithFormat:@"%.0f %%", (double)v];
    return [NSString stringWithFormat:@"%.2f", (double)v];
}

- (NSSlider*)addSlider:(uint32_t)pid frame:(NSRect)r showValue:(BOOL)showValue {
    const ParamDesc& d = paramDescs()[pid];
    NSSlider* s = [[NSSlider alloc] initWithFrame:r];
    s.minValue = d.minV;
    s.maxValue = d.maxV;
    s.doubleValue = d.defV;
    s.tag = (NSInteger)pid;
    s.target = self;
    s.action = @selector(controlChanged:);
    [s setControlSize:NSSmallControlSize];
    [self addSubview:s];
    _sliders[@(pid)] = s;
    if (showValue) {
        NSRect vr = NSMakeRect(r.origin.x + r.size.width + 4, r.origin.y + 1, 54, 15);
        NSTextField* vl = [self makeLabel:@"" frame:vr size:10 bold:NO color:colText()];
        vl.alignment = NSRightTextAlignment;
        _valueLabels[@(pid)] = vl;
    }
    return [s autorelease];
}

- (NSButton*)addCheck:(uint32_t)pid label:(NSString*)label frame:(NSRect)r {
    NSButton* b = [[NSButton alloc] initWithFrame:r];
    b.buttonType = NSSwitchButton;
    b.title = label;
    b.tag = (NSInteger)pid;
    b.target = self;
    b.action = @selector(controlChanged:);
    b.font = [NSFont systemFontOfSize:10];
    b.bezelStyle = NSRoundedBezelStyle;
    [self addSubview:b];
    _checks[@(pid)] = b;
    return [b autorelease];
}

- (NSPopUpButton*)addPopup:(uint32_t)pid choices:(const char* const*)choices count:(int)n frame:(NSRect)r {
    NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:r pullsDown:NO];
    for (int i = 0; i < n; ++i) [p addItemWithTitle:[NSString stringWithUTF8String:choices[i]]];
    p.tag = (NSInteger)pid;
    p.target = self;
    p.action = @selector(controlChanged:);
    p.font = [NSFont systemFontOfSize:10];
    [self addSubview:p];
    _popups[@(pid)] = p;
    return [p autorelease];
}

// Labeled slider row inside a card: [name 72][slider][value 54]
- (void)addSliderRow:(uint32_t)pid y:(CGFloat)y x:(CGFloat)x w:(CGFloat)w name:(NSString*)name {
    [self makeLabel:name frame:NSMakeRect(x, y, 74, 15) size:10 bold:NO color:colDim()];
    [self addSlider:pid frame:NSMakeRect(x + 78, y, w - 78 - 58, 17) showValue:YES];
}

#pragma mark - actions

- (IBAction)controlChanged:(id)sender {
    @try {
    uint32_t pid = (uint32_t)[sender tag];
    float v = 0.0f;
    if ([sender isKindOfClass:[NSButton class]]) {
        v = (float)[(NSButton*)sender state];
    } else if ([sender isKindOfClass:[NSPopUpButton class]]) {
        v = (float)[(NSPopUpButton*)sender indexOfSelectedItem];
    } else {
        v = (float)[(NSControl*)sender doubleValue];
    }
    AudioUnitSetParameter(_au, pid, kAudioUnitScope_Global, 0, v, 0);
    if (pid < P_Count) {
        _statusLabel.stringValue = [NSString stringWithFormat:@"%@  =  %@",
                                    [NSString stringWithUTF8String:paramDescs()[pid].name],
                                    [self formatValue:pid value:v]];
        [self updateValueLabel:pid value:v];
    }
    } @catch (NSException* e) {}
}

- (IBAction)presetChanged:(NSPopUpButton*)sender {
    @try {
    NSMenuItem* item = sender.selectedItem;
    if (!item) return;
    AUPreset p;
    p.presetNumber = (SInt32)item.tag;
    p.presetName = (__bridge CFStringRef)item.title;
    AudioUnitSetProperty(_au, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0,
                         &p, sizeof(AUPreset));
    [self refreshControls];
    } @catch (NSException* e) {}
}

- (void)refreshControls {
    for (NSNumber* key in _sliders) {
        uint32_t pid = key.unsignedIntValue;
        AudioUnitParameterValue v = 0;
        if (AudioUnitGetParameter(_au, pid, kAudioUnitScope_Global, 0, &v) == noErr) {
            [_sliders[key] setDoubleValue:v];
            [self updateValueLabel:pid value:v];
        }
    }
    for (NSNumber* key in _checks) {
        uint32_t pid = key.unsignedIntValue;
        AudioUnitParameterValue v = 0;
        if (AudioUnitGetParameter(_au, pid, kAudioUnitScope_Global, 0, &v) == noErr)
            [_checks[key] setState:(v > 0.5f) ? NSOnState : NSOffState];
    }
    for (NSNumber* key in _popups) {
        uint32_t pid = key.unsignedIntValue;
        AudioUnitParameterValue v = 0;
        if (AudioUnitGetParameter(_au, pid, kAudioUnitScope_Global, 0, &v) == noErr)
            [_popups[key] selectItemAtIndex:(NSInteger)lrintf(v)];
    }
}

- (NSString*)meterString:(int)meterId value:(float)v {
    switch (meterId) {
        case kMeterMomentary:
        case kMeterShortTerm:
        case kMeterIntegrated: return [NSString stringWithFormat:@"%.1f LUFS", (double)v];
        case kMeterLRA:        return [NSString stringWithFormat:@"%.1f LU", (double)v];
        case kMeterTruePeak:   return [NSString stringWithFormat:@"%.1f dBTP", (double)v];
        default:               return [NSString stringWithFormat:@"%.1f dB", (double)v];
    }
}

- (void)tick:(NSTimer*)t {
    @try {
    static const int meterIds[kNumMeters] = {
        kMeterMomentary, kMeterShortTerm, kMeterIntegrated, kMeterLRA, kMeterTruePeak,
        kMeterLimGR, kMeterMbGR0, kMeterMbGR1, kMeterMbGR2, kMeterMbGR3
    };
    for (int i = 0; i < kNumMeters; ++i) {
        int mid = meterIds[i];
        AudioUnitParameterValue v = -120.0f;
        AudioUnitGetParameter(_au, (AudioUnitParameterID)mid, kAudioUnitScope_Global, 0, &v);
        NSString* s = [self meterString:mid value:v];
        if (mid == kMeterIntegrated) _intLabel.stringValue = s;
        NSTextField* l = _meterLabels[@(mid)];
        if (l) l.stringValue = s;
        BarView* bar = _grBars[@(mid)];
        if (bar) { bar->level = v; [bar setNeedsDisplay:YES]; }
    }
    BarView* lufs = [_meterBars firstObject];
    if (lufs) {
        AudioUnitParameterValue v = -120.0f;
        AudioUnitGetParameter(_au, kMeterIntegrated, kAudioUnitScope_Global, 0, &v);
        lufs->level = v;
        [lufs setNeedsDisplay:YES];
    }
    } @catch (NSException* e) {}
}

#pragma mark - layout

- (CGFloat)section:(NSString*)name atY:(CGFloat)y x:(CGFloat)x w:(CGFloat)w {
    [self makeLabel:name frame:NSMakeRect(x + 2, y - 13, w, 14) size:9 bold:YES color:colAccent()];
    return y - 19;
}

- (void)buildUI {
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    const CGFloat headerH = 58;
    const CGFloat top = H - headerH;

    // ---- header ----
    DotView* dot = [[DotView alloc] initWithFrame:NSMakeRect(16, H - 40, 24, 24)];
    [self addSubview:dot];
    [dot release];
    [self makeLabel:@"MasteringAU" frame:NSMakeRect(48, H - 40, 200, 26) size:21 bold:YES color:colText()];
    [self makeLabel:@"VIBE MASTERING" frame:NSMakeRect(50, H - 50, 150, 11) size:8 bold:YES color:colAccent()];

    [self makeLabel:@"PRESET" frame:NSMakeRect(262, H - 34, 46, 14) size:9 bold:YES color:colDim()];
    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(310, H - 39, 200, 26) pullsDown:NO];
    _presetPopup.target = self;
    _presetPopup.action = @selector(presetChanged:);
    _presetPopup.font = [NSFont systemFontOfSize:11];
    [self addSubview:_presetPopup];
    {
        UInt32 size = sizeof(CFArrayRef);
        CFArrayRef arr = nullptr;
        if (AudioUnitGetProperty(_au, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0,
                                 &arr, &size) == noErr && arr != nullptr) {
            CFIndex n = CFArrayGetCount(arr);
            for (CFIndex i = 0; i < n; ++i) {
                AUPreset* p = (AUPreset*)CFArrayGetValueAtIndex(arr, i);
                [_presetPopup addItemWithTitle:(__bridge NSString*)p->presetName];
                [[_presetPopup lastItem] setTag:p->presetNumber];
            }
            CFRelease(arr);
        }
    }

    [self addCheck:P_Bypass label:@"BYPASS" frame:NSMakeRect(530, H - 38, 90, 24)];
    _statusLabel = [self makeLabel:@"" frame:NSMakeRect(640, H - 36, W - 652, 16) size:11 bold:NO color:colDim()];

    // ---- left column: meters card + chain card ----
    const CGFloat lx = 12, lw = 244;
    const CGFloat metersH = 268;
    [self cardWithFrame:NSMakeRect(lx, top - 8 - metersH, lw, metersH) title:@"METERS · BS.1770"];
    CGFloat my = top - 8 - metersH + metersH - 34; // below card title
    [self makeLabel:@"INTEGRATED" frame:NSMakeRect(lx + 14, my, 110, 12) size:8 bold:YES color:colDim()];
    _intLabel = [self makeLabel:@"-120.0 LUFS" frame:NSMakeRect(lx + 14, my - 26, lw - 28, 30) size:26 bold:YES color:colAccent()];
    my -= 40;
    const int meterRows[4] = { kMeterMomentary, kMeterShortTerm, kMeterLRA, kMeterTruePeak };
    const char* meterRowNames[4] = { "Momentary", "Short-term", "LRA", "True peak" };
    for (int i = 0; i < 4; ++i) {
        [self makeLabel:[NSString stringWithUTF8String:meterRowNames[i]]
                  frame:NSMakeRect(lx + 14, my, 84, 14) size:10 bold:NO color:colDim()];
        NSTextField* vl = [self makeLabel:@"--" frame:NSMakeRect(lx + 104, my, lw - 118, 14) size:10 bold:NO color:colText()];
        vl.alignment = NSRightTextAlignment;
        _meterLabels[@(meterRows[i])] = vl;
        my -= 18;
    }
    BarView* lufsBar = [[BarView alloc] initWithFrame:NSMakeRect(lx + 14, my - 4, lw - 28, 22)];
    lufsBar->minV = -36.0f; lufsBar->maxV = 3.0f; lufsBar->level = -120.0f; lufsBar->style = 2;
    [self addSubview:lufsBar];
    [_meterBars addObject:lufsBar];
    [lufsBar release];
    my -= 30;
    [self makeLabel:@"GAIN REDUCTION" frame:NSMakeRect(lx + 14, my, 120, 11) size:8 bold:YES color:colDim()];
    my -= 15;
    const int grIds[5] = { kMeterLimGR, kMeterMbGR0, kMeterMbGR1, kMeterMbGR2, kMeterMbGR3 };
    const char* grNames[5] = { "LIM", "B1", "B2", "B3", "B4" };
    for (int i = 0; i < 5; ++i) {
        [self makeLabel:[NSString stringWithUTF8String:grNames[i]]
                  frame:NSMakeRect(lx + 14, my, 24, 12) size:8 bold:NO color:colDim()];
        BarView* bar = [[BarView alloc] initWithFrame:NSMakeRect(lx + 42, my, lw - 130, 12)];
        bar->minV = 0.0f; bar->maxV = 24.0f; bar->level = 0.0f; bar->inverted = YES; bar->style = 1;
        [self addSubview:bar];
        _grBars[@(grIds[i])] = bar;
        [bar release];
        NSTextField* vl = [self makeLabel:@"0.0" frame:NSMakeRect(lx + lw - 82, my, 68, 12) size:8 bold:NO color:colText()];
        vl.alignment = NSRightTextAlignment;
        _meterLabels[@(grIds[i])] = vl;
        my -= 15;
    }

    const CGFloat chainTop = top - 8 - metersH - 16;
    [self cardWithFrame:NSMakeRect(lx, 8, lw, chainTop - 8) title:@"CHAIN"];
    CGFloat y = chainTop - 26;
    const CGFloat cx = lx + 12, cw = lw - 24;
    y = [self section:@"MAIN" atY:y x:cx w:cw];
    [self addSliderRow:P_InputGain  y:y x:cx w:cw name:@"Input"]; y -= 21;
    [self addSliderRow:P_OutputTrim y:y x:cx w:cw name:@"Output"]; y -= 23;

    y = [self section:@"HIGH-PASS" atY:y x:cx w:cw];
    [self addCheck:P_HpEnable label:@"HP on" frame:NSMakeRect(cx, y - 2, cw, 19)]; y -= 21;
    [self addSliderRow:P_HpFreq y:y x:cx w:cw name:@"HP freq"]; y -= 23;

    y = [self section:@"STEREO" atY:y x:cx w:cw];
    [self addCheck:P_MonoLowEnable label:@"Mono low" frame:NSMakeRect(cx, y - 2, cw, 19)]; y -= 21;
    [self addSliderRow:P_MonoLowFreq y:y x:cx w:cw name:@"Mono freq"]; y -= 21;
    [self addSliderRow:P_Width y:y x:cx w:cw name:@"Width"]; y -= 23;

    y = [self section:@"SATURATION" atY:y x:cx w:cw];
    [self addCheck:P_SatEnable label:@"Sat on" frame:NSMakeRect(cx, y - 2, cw, 19)]; y -= 21;
    [self addSliderRow:P_SatDrive y:y x:cx w:cw name:@"Drive"]; y -= 21;
    [self makeLabel:@"Mode" frame:NSMakeRect(cx, y, 74, 15) size:10 bold:NO color:colDim()];
    [self addPopup:P_SatMode choices:kSatModeChoices count:3 frame:NSMakeRect(cx + 78, y - 4, 120, 22)]; y -= 25;
    [self addSliderRow:P_SatMix y:y x:cx w:cw name:@"Mix"]; y -= 23;

    y = [self section:@"LIMITER" atY:y x:cx w:cw];
    [self addCheck:P_LimEnable label:@"Lim on" frame:NSMakeRect(cx, y - 2, cw, 19)]; y -= 21;
    [self addSliderRow:P_LimCeiling y:y x:cx w:cw name:@"Ceiling"]; y -= 21;
    [self addSliderRow:P_LimLookahead y:y x:cx w:cw name:@"Lookahead"]; y -= 21;
    [self addSliderRow:P_LimRelease y:y x:cx w:cw name:@"Release"]; y -= 23;

    y = [self section:@"OUTPUT" atY:y x:cx w:cw];
    [self addCheck:P_DitherEnable label:@"Dither" frame:NSMakeRect(cx, y - 2, cw, 19)]; y -= 21;

    // ---- middle column: EQ card ----
    const CGFloat mx = 268, mw = 484;
    [self cardWithFrame:NSMakeRect(mx, 8, mw, top - 16) title:@"EQ · 6 BAND"];
    CGFloat ey = top - 40;
    // column headers
    const char* eqCols[3] = { "Freq", "Gain", "Q" };
    [self makeLabel:@"Band" frame:NSMakeRect(mx + 14, ey, 30, 11) size:8 bold:YES color:colDim()];
    [self makeLabel:@"Type" frame:NSMakeRect(mx + 78, ey, 88, 11) size:8 bold:YES color:colDim()];
    for (int c = 0; c < 3; ++c)
        [self makeLabel:[NSString stringWithUTF8String:eqCols[c]]
                  frame:NSMakeRect(mx + 176 + c * 100, ey, 92, 11) size:8 bold:YES color:colDim()];
    ey -= 18;
    for (int b = 0; b < kNumEqBands; ++b) {
        CGFloat bx = mx + 14;
        [self makeLabel:[NSString stringWithFormat:@"EQ%d", b + 1]
                  frame:NSMakeRect(bx, ey + 3, 28, 15) size:11 bold:YES color:colAccent()];
        [self addCheck:eqParam(b, EqEnable) label:@"" frame:NSMakeRect(bx + 36, ey + 1, 30, 17)];
        [self addPopup:eqParam(b, EqType) choices:kEqTypeChoices count:5 frame:NSMakeRect(bx + 72, ey - 2, 92, 22)];
        [self addSlider:eqParam(b, EqFreq) frame:NSMakeRect(bx + 172, ey, 94, 18) showValue:NO];
        [self addSlider:eqParam(b, EqGain) frame:NSMakeRect(bx + 272, ey, 94, 18) showValue:NO];
        [self addSlider:eqParam(b, EqQ)    frame:NSMakeRect(bx + 372, ey, 94, 18) showValue:NO];
        ey -= 34;
    }

    // ---- right column: multiband card ----
    const CGFloat rx = 764, rw = W - rx - 12;
    [self cardWithFrame:NSMakeRect(rx, 8, rw, top - 16) title:@"MULTIBAND COMPRESSOR · 4 BAND"];
    CGFloat by = top - 40;
    [self makeLabel:@"Crossovers" frame:NSMakeRect(rx + 14, by, 90, 13) size:9 bold:YES color:colDim()];
    by -= 6;
    const char* xoNames[3] = { "X1", "X2", "X3" };
    const uint32_t xoIds[3] = { P_MbXover1, P_MbXover2, P_MbXover3 };
    for (int i = 0; i < 3; ++i) {
        CGFloat cxp = rx + 14 + i * ((rw - 28) / 3.0);
        [self makeLabel:[NSString stringWithUTF8String:xoNames[i]]
                  frame:NSMakeRect(cxp, by - 13, 30, 11) size:8 bold:NO color:colDim()];
        [self addSlider:xoIds[i] frame:NSMakeRect(cxp, by, (rw - 28) / 3.0 - 10, 18) showValue:NO];
    }
    by -= 36;
    const char* mbCols[5] = { "Thr", "Ratio", "Atk", "Rel", "Makeup" };
    [self makeLabel:@"Band" frame:NSMakeRect(rx + 14, by, 30, 11) size:8 bold:YES color:colDim()];
    for (int c = 0; c < 5; ++c)
        [self makeLabel:[NSString stringWithUTF8String:mbCols[c]]
                  frame:NSMakeRect(rx + 78 + c * 76, by, 72, 11) size:8 bold:YES color:colDim()];
    by -= 18;
    for (int b = 0; b < kNumMbBands; ++b) {
        CGFloat bx = rx + 14;
        [self makeLabel:[NSString stringWithFormat:@"B%d", b + 1]
                  frame:NSMakeRect(bx, by + 3, 28, 15) size:11 bold:YES color:colWarn()];
        [self addCheck:mbParam(b, MbEnable) label:@"" frame:NSMakeRect(bx + 36, by + 1, 30, 17)];
        const uint32_t fields[5] = { MbThresh, MbRatio, MbAttack, MbRelease, MbMakeup };
        for (int f = 0; f < 5; ++f)
            [self addSlider:mbParam(b, fields[f]) frame:NSMakeRect(bx + 74 + f * 76, by, 72, 18) showValue:NO];
        by -= 30;
    }
}

@end

@interface MasteringAUViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation MasteringAUViewFactory
- (unsigned)interfaceVersion { return 0; }
- (NSString*)description { return @"MasteringAU"; }
- (NSView*)uiViewForAudioUnit:(AudioUnit)inAudioUnit withSize:(NSSize)inPreferredSize {
    CGFloat w = MAX(inPreferredSize.width, 1260.0);
    CGFloat h = MAX(inPreferredSize.height, 760.0);
    MasteringAUView* v = [[MasteringAUView alloc] initWithFrame:NSMakeRect(0, 0, w, h) audioUnit:inAudioUnit];
    return [v autorelease];
}
@end
