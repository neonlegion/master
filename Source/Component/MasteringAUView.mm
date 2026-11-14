// Cocoa UI for the MasteringAU AUv2 component. Loaded by the host through
// kAudioUnitProperty_CocoaUI (class MasteringAUViewFactory, conforming to
// AUCocoaUIBase). All controls are bound to AU parameters in the global scope
// via AudioUnitGet/SetParameter; meters are read-only parameters (ids 1000+)
// refreshed by a 30 Hz timer.

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

static NSColor* bgColor(void)   { return [NSColor colorWithCalibratedWhite:0.086 alpha:1.0]; }
static NSColor* panelColor(void){ return [NSColor colorWithCalibratedWhite:0.13 alpha:1.0]; }
static NSColor* textColor(void) { return [NSColor colorWithCalibratedWhite:0.86 alpha:1.0]; }
static NSColor* dimColor(void)  { return [NSColor colorWithCalibratedWhite:0.55 alpha:1.0]; }
static NSColor* accentColor(void){ return [NSColor colorWithCalibratedRed:0.25 green:0.62 blue:1.0 alpha:1.0]; }
static NSColor* warnColor(void) { return [NSColor colorWithCalibratedRed:1.0 green:0.45 blue:0.2 alpha:1.0]; }

// Simple horizontal meter bar.
@interface BarView : NSView {
@public
    float level;
    float minV, maxV;
    BOOL inverted;
    NSColor* barColor;
}
@end
@implementation BarView
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) { minV = 0; maxV = 1; level = 0; inverted = NO;
        barColor = accentColor(); self.wantsLayer = YES; }
    return self;
}
- (void)drawRect:(NSRect)dirty {
    NSRect r = self.bounds;
    [[NSColor colorWithCalibratedWhite:0.05 alpha:1.0] setFill];
    NSRectFill(r);
    float frac = (maxV > minV) ? (level - minV) / (maxV - minV) : 0.0f;
    if (frac < 0) frac = 0; if (frac > 1) frac = 1;
    if (inverted) frac = 1.0f - frac;
    NSRect fill = NSMakeRect(r.origin.x + 1, r.origin.y + 1,
                             (r.size.width - 2) * frac, r.size.height - 2);
    [barColor setFill];
    NSRectFill(fill);
    [[NSColor colorWithCalibratedWhite:0.3 alpha:1.0] setStroke];
    NSBezierPath* bp = [NSBezierPath bezierPathWithRect:NSInsetRect(r, 0.5, 0.5)];
    [bp stroke];
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
    NSMutableArray* _meterBars;         // BarView list
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
    self.layer.backgroundColor = bgColor().CGColor;
    [self buildUI];
    [self refreshControls];
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

- (NSBox*)makePanel:(NSString*)title frame:(NSRect)r {
    NSBox* box = [[NSBox alloc] initWithFrame:r];
    box.boxType = NSBoxCustom;
    box.borderType = NSLineBorder;
    box.borderColor = [NSColor colorWithCalibratedWhite:0.28 alpha:1.0];
    box.fillColor = panelColor();
    box.title = title;
    box.titleFont = [NSFont boldSystemFontOfSize:11];
    box.titlePosition = NSAtTopLeftTitlePosition;
    box.contentViewMargins = NSMakeSize(4, 4);
    [self addSubview:box];
    return [box autorelease];
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
    [self addSubview:s];
    _sliders[@(pid)] = s;
    if (showValue) {
        NSRect vr = NSMakeRect(r.origin.x + r.size.width + 4, r.origin.y + 2, 56, 16);
        NSTextField* vl = [self makeLabel:@"" frame:vr size:10 bold:NO color:textColor()];
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

// Labeled row in the left column: [name][slider][value]
- (void)addSliderRow:(uint32_t)pid y:(CGFloat)y x:(CGFloat)x w:(CGFloat)w name:(NSString*)name {
    [self makeLabel:name frame:NSMakeRect(x, y, 82, 16) size:10 bold:NO color:dimColor()];
    [self addSlider:pid frame:NSMakeRect(x + 86, y, w - 86 - 60, 18) showValue:YES];
}

- (void)addCheckRow:(uint32_t)pid y:(CGFloat)y x:(CGFloat)x w:(CGFloat)w label:(NSString*)label {
    [self addCheck:pid label:label frame:NSMakeRect(x, y - 2, w, 20)];
}

- (void)addPopupRow:(uint32_t)pid y:(CGFloat)y x:(CGFloat)x name:(NSString*)name
            choices:(const char* const*)choices count:(int)n popupW:(CGFloat)pw {
    [self makeLabel:name frame:NSMakeRect(x, y, 82, 16) size:10 bold:NO color:dimColor()];
    [self addPopup:pid choices:choices count:n frame:NSMakeRect(x + 86, y - 3, pw, 22)];
}

#pragma mark - actions

- (IBAction)controlChanged:(id)sender {
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
}

- (IBAction)presetChanged:(NSPopUpButton*)sender {
    NSMenuItem* item = sender.selectedItem;
    if (!item) return;
    AUPreset p;
    p.presetNumber = (SInt32)item.tag;
    p.presetName = (__bridge CFStringRef)item.title;
    AudioUnitSetProperty(_au, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0,
                         &p, sizeof(AUPreset));
    [self refreshControls];
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
        case kMeterLimGR:      return [NSString stringWithFormat:@"%.1f dB", (double)v];
        default:               return [NSString stringWithFormat:@"%.1f dB", (double)v];
    }
}

- (void)tick:(NSTimer*)t {
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
}

#pragma mark - layout

- (void)buildUI {
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    const CGFloat headerH = 46;

    // ---- header ----
    [self makeLabel:@"MasteringAU" frame:NSMakeRect(14, H - 34, 220, 26) size:20 bold:YES color:textColor()];
    [self makeLabel:@"VIBE MASTERING" frame:NSMakeRect(16, H - 44, 160, 12) size:9 bold:YES color:accentColor()];

    [self makeLabel:@"Preset" frame:NSMakeRect(250, H - 32, 40, 16) size:10 bold:NO color:dimColor()];
    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(292, H - 36, 190, 24) pullsDown:NO];
    _presetPopup.target = self;
    _presetPopup.action = @selector(presetChanged:);
    [self addSubview:_presetPopup];
    {
        UInt32 size = sizeof(CFArrayRef);
        CFArrayRef arr = nullptr;
        if (AudioUnitGetProperty(_au, kAudioUnitProperty_FactoryPresets, kAudioUnitScope_Global, 0,
                                 &arr, &size) == noErr && arr != nullptr) {
            CFIndex n = CFArrayGetCount(arr);
            for (CFIndex i = 0; i < n; ++i) {
                CFDictionaryRef d = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
                CFStringRef name = (CFStringRef)CFDictionaryGetValue(d, CFSTR(kAUPresetNameKey));
                CFNumberRef num = (CFNumberRef)CFDictionaryGetValue(d, CFSTR(kAUPresetNumberKey));
                SInt32 number = 0;
                if (num) CFNumberGetValue(num, kCFNumberSInt32Type, &number);
                [_presetPopup addItemWithTitle:(__bridge NSString*)name];
                [[_presetPopup lastItem] setTag:number];
            }
            CFRelease(arr);
        }
    }

    [self addCheck:P_Bypass label:@"Bypass" frame:NSMakeRect(500, H - 36, 80, 22)];

    _statusLabel = [self makeLabel:@"" frame:NSMakeRect(600, H - 32, W - 612, 16) size:11 bold:NO color:dimColor()];

    const CGFloat top = H - headerH - 8;

    // ---- left column: processing sections ----
    const CGFloat lx = 12, lw = 240;
    CGFloat y = top;
    [self makePanel:@"CHAIN" frame:NSMakeRect(lx, 8, lw, top - 8)];
    y -= 26;
    y = [self section:@"MAIN" atY:y x:lx w:lw];
    [self addSliderRow:P_InputGain  y:y-2 x:lx w:lw name:@"Input"]; y -= 22;
    [self addSliderRow:P_OutputTrim y:y-2 x:lx w:lw name:@"Output"]; y -= 22;
    y -= 2;

    y = [self section:@"HIGH-PASS" atY:y x:lx w:lw];
    [self addCheckRow:P_HpEnable y:y-2 x:lx w:lw label:@"HP On"]; y -= 22;
    [self addSliderRow:P_HpFreq y:y-2 x:lx w:lw name:@"HP Freq"]; y -= 24;

    y = [self section:@"STEREO" atY:y x:lx w:lw];
    [self addCheckRow:P_MonoLowEnable y:y-2 x:lx w:lw label:@"Mono Low"]; y -= 22;
    [self addSliderRow:P_MonoLowFreq y:y-2 x:lx w:lw name:@"Mono Freq"]; y -= 22;
    [self addSliderRow:P_Width y:y-2 x:lx w:lw name:@"Width"]; y -= 24;

    y = [self section:@"SATURATION" atY:y x:lx w:lw];
    [self addCheckRow:P_SatEnable y:y-2 x:lx w:lw label:@"Sat On"]; y -= 22;
    [self addSliderRow:P_SatDrive y:y-2 x:lx w:lw name:@"Drive"]; y -= 22;
    [self addPopupRow:P_SatMode y:y-4 x:lx name:@"Mode" choices:kSatModeChoices count:3 popupW:110]; y -= 24;
    [self addSliderRow:P_SatMix y:y-2 x:lx w:lw name:@"Mix"]; y -= 24;

    y = [self section:@"LIMITER" atY:y x:lx w:lw];
    [self addCheckRow:P_LimEnable y:y-2 x:lx w:lw label:@"Lim On"]; y -= 22;
    [self addSliderRow:P_LimCeiling y:y-2 x:lx w:lw name:@"Ceiling"]; y -= 22;
    [self addSliderRow:P_LimLookahead y:y-2 x:lx w:lw name:@"Lookahd"]; y -= 22;
    [self addSliderRow:P_LimRelease y:y-2 x:lx w:lw name:@"Release"]; y -= 24;

    y = [self section:@"OUTPUT" atY:y x:lx w:lw];
    [self addCheckRow:P_DitherEnable y:y-2 x:lx w:lw label:@"Dither"]; y -= 22;

    // ---- middle column: meters + EQ ----
    const CGFloat mx = 264, mw = 480;
    NSRect metersFrame = NSMakeRect(mx, top - 208, mw, 208);
    [self makePanel:@"METERS (BS.1770)" frame:metersFrame];
    CGFloat my = top - 40;
    [self makeLabel:@"INTEGRATED" frame:NSMakeRect(mx + 12, my, 120, 14) size:9 bold:YES color:dimColor()];
    _intLabel = [self makeLabel:@"-120.0 LUFS" frame:NSMakeRect(mx + 130, my - 8, 160, 26) size:22 bold:YES color:accentColor()];
    my -= 34;
    const int meterRows[4] = { kMeterMomentary, kMeterShortTerm, kMeterLRA, kMeterTruePeak };
    const char* meterRowNames[4] = { "Momentary", "Short-Term", "LRA", "True Peak" };
    for (int i = 0; i < 4; ++i) {
        [self makeLabel:[NSString stringWithUTF8String:meterRowNames[i]]
                  frame:NSMakeRect(mx + 12, my, 90, 14) size:10 bold:NO color:dimColor()];
        NSTextField* vl = [self makeLabel:@"--" frame:NSMakeRect(mx + 110, my, 90, 14) size:10 bold:NO color:textColor()];
        vl.alignment = NSRightTextAlignment;
        _meterLabels[@(meterRows[i])] = vl;
        my -= 18;
    }
    BarView* lufsBar = [[BarView alloc] initWithFrame:NSMakeRect(mx + 12, my - 2, mw - 24, 20)];
    lufsBar->minV = -36.0f; lufsBar->maxV = 3.0f; lufsBar->level = -120.0f;
    lufsBar->barColor = accentColor();
    [self addSubview:lufsBar];
    [_meterBars addObject:lufsBar];
    [lufsBar release];
    my -= 26;
    [self makeLabel:@"GAIN REDUCTION" frame:NSMakeRect(mx + 12, my, 120, 12) size:8 bold:YES color:dimColor()];
    my -= 14;
    const int grIds[5] = { kMeterLimGR, kMeterMbGR0, kMeterMbGR1, kMeterMbGR2, kMeterMbGR3 };
    const char* grNames[5] = { "LIM", "B1", "B2", "B3", "B4" };
    for (int i = 0; i < 5; ++i) {
        [self makeLabel:[NSString stringWithUTF8String:grNames[i]]
                  frame:NSMakeRect(mx + 12, my, 24, 12) size:8 bold:NO color:dimColor()];
        BarView* bar = [[BarView alloc] initWithFrame:NSMakeRect(mx + 40, my, mw - 130, 12)];
        bar->minV = 0.0f; bar->maxV = 24.0f; bar->level = 0.0f; bar->inverted = YES;
        bar->barColor = warnColor();
        [self addSubview:bar];
        _grBars[@(grIds[i])] = bar;
        [bar release];
        NSTextField* vl = [self makeLabel:@"0.0" frame:NSMakeRect(mx + mw - 84, my, 60, 12) size:8 bold:NO color:textColor()];
        vl.alignment = NSRightTextAlignment;
        _meterLabels[@(grIds[i])] = vl;
        my -= 15;
    }

    // EQ panel
    CGFloat eqTop = top - 208 - 12;
    NSRect eqFrame = NSMakeRect(mx, 8, mw, eqTop - 8);
    [self makePanel:@"EQ (6 BAND)" frame:eqFrame];
    CGFloat ey = eqTop - 34;
    const char* eqColNames[5] = { "", "Type", "Freq", "Gain", "Q" };
    for (int c = 0; c < 5; ++c) {
        CGFloat cx = mx + 12 + 34 + (c == 0 ? 96 : 0) + (c >= 1 ? (c - 1) * 100 : 0);
        if (c >= 1) cx = mx + 12 + 34 + 96 + (c - 1) * 100;
        [self makeLabel:[NSString stringWithUTF8String:eqColNames[c]]
                  frame:NSMakeRect(cx, ey, 90, 12) size:8 bold:YES color:dimColor()];
    }
    ey -= 16;
    for (int b = 0; b < kNumEqBands; ++b) {
        CGFloat bx = mx + 12;
        [self makeLabel:[NSString stringWithFormat:@"EQ%d", b + 1]
                  frame:NSMakeRect(bx, ey + 2, 28, 14) size:10 bold:YES color:textColor()];
        [self addCheck:eqParam(b, EqEnable) label:@"" frame:NSMakeRect(bx + 34, ey, 34, 18)];
        [self addPopup:eqParam(b, EqType) choices:kEqTypeChoices count:5 frame:NSMakeRect(bx + 74, ey - 3, 92, 22)];
        [self addSlider:eqParam(b, EqFreq) frame:NSMakeRect(bx + 172, ey, 96, 18) showValue:NO];
        [self addSlider:eqParam(b, EqGain) frame:NSMakeRect(bx + 272, ey, 96, 18) showValue:NO];
        [self addSlider:eqParam(b, EqQ)    frame:NSMakeRect(bx + 372, ey, 96, 18) showValue:NO];
        ey -= 26;
    }

    // ---- right column: multiband ----
    const CGFloat rx = 756, rw = W - rx - 12;
    NSRect mbFrame = NSMakeRect(rx, 8, rw, top - 8);
    [self makePanel:@"MULTIBAND COMPRESSOR" frame:mbFrame];
    CGFloat by = top - 40;
    [self makeLabel:@"Crossovers" frame:NSMakeRect(rx + 12, by, 80, 14) size:9 bold:YES color:dimColor()];
    by -= 4;
    const char* xoNames[3] = { "X1", "X2", "X3" };
    const uint32_t xoIds[3] = { P_MbXover1, P_MbXover2, P_MbXover3 };
    for (int i = 0; i < 3; ++i) {
        CGFloat cx = rx + 12 + i * ((rw - 24) / 3.0);
        [self makeLabel:[NSString stringWithUTF8String:xoNames[i]]
                  frame:NSMakeRect(cx, by - 12, 30, 12) size:8 bold:NO color:dimColor()];
        [self addSlider:xoIds[i] frame:NSMakeRect(cx, by, (rw - 24) / 3.0 - 8, 18) showValue:NO];
    }
    by -= 34;
    const char* mbColNames[6] = { "Thr", "Rat", "Atk", "Rel", "Mkp" };
    for (int c = 0; c < 5; ++c)
        [self makeLabel:[NSString stringWithUTF8String:mbColNames[c]]
                  frame:NSMakeRect(rx + 12 + 40 + c * 78, by, 74, 12) size:8 bold:YES color:dimColor()];
    by -= 16;
    for (int b = 0; b < kNumMbBands; ++b) {
        CGFloat bx = rx + 12;
        [self makeLabel:[NSString stringWithFormat:@"B%d", b + 1]
                  frame:NSMakeRect(bx, by + 2, 28, 14) size:10 bold:YES color:textColor()];
        [self addCheck:mbParam(b, MbEnable) label:@"" frame:NSMakeRect(bx + 32, by, 30, 18)];
        const uint32_t fields[5] = { MbThresh, MbRatio, MbAttack, MbRelease, MbMakeup };
        for (int f = 0; f < 5; ++f)
            [self addSlider:mbParam(b, fields[f]) frame:NSMakeRect(bx + 70 + f * 78, by, 74, 18) showValue:NO];
        by -= 26;
    }
}

- (CGFloat)section:(NSString*)name atY:(CGFloat)y x:(CGFloat)x w:(CGFloat)w {
    [self makeLabel:name frame:NSMakeRect(x + 2, y - 12, w, 14) size:9 bold:YES color:accentColor()];
    return y - 18;
}

@end

@interface MasteringAUViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation MasteringAUViewFactory
- (unsigned)interfaceVersion { return 0; }
- (NSString*)description { return @"MasteringAU"; }
- (NSView*)uiViewForAudioUnit:(AudioUnit)inAudioUnit withSize:(NSSize)inPreferredSize {
    CGFloat w = MAX(inPreferredSize.width, 1260.0);
    CGFloat h = MAX(inPreferredSize.height, 740.0);
    MasteringAUView* v = [[MasteringAUView alloc] initWithFrame:NSMakeRect(0, 0, w, h) audioUnit:inAudioUnit];
    return [v autorelease];
}
@end
