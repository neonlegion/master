// Cocoa UI for the MasteringAU AUv2 component. Loaded by the host through
// kAudioUnitProperty_CocoaUI (class MasteringAUViewFactory, conforming to
// AUCocoaUIBase). All controls are bound to AU parameters in the global scope
// via AudioUnitGet/SetParameter; meters are read-only parameters (ids 1000+)
// refreshed by a 30 Hz timer. No UI code may ever throw into the host: all
// drawing and actions are wrapped in @try/@catch.
//
// Layout (v4, Pro-L 2 / Ozone style, fluid/resizable):
//   header bar      logo, title, preset popup, BYPASS, status line
//   meter bridge    full-width: big integrated LUFS readout, wide zone LUFS
//                   bar with scale ticks, MOM/S/LRA/TP readouts, GR bars
//   middle row      EQ (6-band) and MULTIBAND (4-band) detail cards (sliders)
//   bottom row      six mini cards in signal-flow order with rotary knobs:
//                   1 INPUT -> 2 HIGH-PASS -> 3 STEREO -> 4 SATURATION
//                   -> 5 LIMITER -> 6 OUTPUT, each with a prominent enable
//
// Host-safety rules (hard-won under Rosetta): views that draw on the CA
// display thread (BarView, DotView, KnobView) use ONLY primitive ivars and
// inline NSColor literals in drawRect — never helper functions returning
// objects, never object ivars.

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

// Palette — build-time code only (labels, cards, buttons). Never call these
// from drawRect on the display thread.
static NSColor* colBg(void)     { return [NSColor colorWithCalibratedWhite:0.070 alpha:1.0]; }
static NSColor* colCard(void)   { return [NSColor colorWithCalibratedWhite:0.115 alpha:1.0]; }
static NSColor* colCardEdge(void){ return [NSColor colorWithCalibratedWhite:0.24 alpha:1.0]; }
static NSColor* colText(void)   { return [NSColor colorWithCalibratedWhite:0.90 alpha:1.0]; }
static NSColor* colDim(void)    { return [NSColor colorWithCalibratedWhite:0.52 alpha:1.0]; }
static NSColor* colAccent(void) { return [NSColor colorWithCalibratedRed:0.20 green:0.60 blue:1.0 alpha:1.0]; }
static NSColor* colWarn(void)   { return [NSColor colorWithCalibratedRed:1.0 green:0.42 blue:0.18 alpha:1.0]; }

// Horizontal meter bar. Primitive ivars only. style:
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
    // Display thread: inline NSColor literals only (Rosetta-safe).
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
            // LUFS zones across minV..maxV: green up to -18, amber up to -6, red above
            CGFloat x0 = r.origin.x + 1, y0 = r.origin.y + 1, h = r.size.height - 2;
            CGFloat span = r.size.width - 2;
            float z1 = (float)((-18.0 - minV) / (maxV - minV));
            float z2 = (float)((-6.0 - minV) / (maxV - minV));
            [[NSColor colorWithCalibratedRed:0.25 green:0.80 blue:0.45 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x0, y0, span * z1, h));
            [[NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.15 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x0 + span * z1, y0, span * (z2 - z1), h));
            [[NSColor colorWithCalibratedRed:1.0 green:0.42 blue:0.18 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x0 + span * z2, y0, span * (1.0f - z2), h));
            [[NSColor colorWithCalibratedWhite:1.0 alpha:1.0] setFill];
            NSRectFill(NSMakeRect(x0 + w - 1, y0, 2, h));
        } else {
            NSColor* c = (style == 1)
                ? [NSColor colorWithCalibratedRed:1.0 green:0.42 blue:0.18 alpha:1.0]
                : [NSColor colorWithCalibratedRed:0.20 green:0.60 blue:1.0 alpha:1.0];
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

// Small circular "logo" dot. Display thread: inline colors only.
@interface DotView : NSView
@end
@implementation DotView
- (void)drawRect:(NSRect)dirty {
    @try {
        NSRect r = NSInsetRect(self.bounds, 2, 2);
        NSBezierPath* p = [NSBezierPath bezierPathWithOvalInRect:r];
        [[NSColor colorWithCalibratedRed:0.20 green:0.60 blue:1.0 alpha:1.0] setFill];
        [p fill];
        [[NSColor colorWithCalibratedWhite:1.0 alpha:1.0] setStroke];
        [p setLineWidth: 1.5];
        [p stroke];
    } @catch (NSException* e) {}
}
@end

// Rotary knob control. Primitive ivars only; inline colors in drawRect.
// Drag vertically to change value (150 px = full range); double-click resets
// to the parameter default. Acts as an NSControl so the existing
// controlChanged:/refreshControls binding (tag = param id) works unchanged.
@interface KnobView : NSControl {
@public
    double kMin, kMax, kVal, kDef;
    double dragY, dragVal;
}
@end
@implementation KnobView
- (instancetype)initWithFrame:(NSRect)r {
    self = [super initWithFrame:r];
    if (self) { kMin = 0; kMax = 1; kVal = 0; kDef = 0; dragY = 0; dragVal = 0; }
    return self;
}
- (double)doubleValue { return kVal; }
- (void)setDoubleValue:(double)v {
    if (v < kMin) v = kMin;
    if (v > kMax) v = kMax;
    kVal = v;
    [self setNeedsDisplay:YES];
}
- (BOOL)acceptsFirstMouse:(id)sender { return YES; }
- (void)mouseDown:(NSEvent*)e {
    @try {
        if ([e clickCount] >= 2) {           // double-click: reset to default
            kVal = kDef;
            [self setNeedsDisplay:YES];
            if (self.target && self.action)
                [self.target performSelector:self.action withObject:self];
            return;
        }
        dragY = [e locationInView:self].y;
        dragVal = kVal;
    } @catch (NSException* x) {}
}
- (void)mouseDragged:(NSEvent*)e {
    @try {
        double dy = dragY - [e locationInView:self].y;
        double sens = (kMax > kMin) ? (kMax - kMin) / 150.0 : 0.0;
        double v = dragVal + dy * sens;
        if (v < kMin) v = kMin;
        if (v > kMax) v = kMax;
        kVal = v;
        [self setNeedsDisplay:YES];
        if (self.target && self.action)
            [self.target performSelector:self.action withObject:self];
    } @catch (NSException* x) {}
}
- (void)drawRect:(NSRect)dirty {
    // Display thread: inline NSColor literals only (Rosetta-safe).
    @try {
        NSRect r = self.bounds;
        double cx = r.origin.x + r.size.width / 2.0;
        double cy = r.origin.y + r.size.height / 2.0;
        CGFloat rad = (CGFloat)(fmin(r.size.width, r.size.height) / 2.0) - 3.0;
        if (rad < 4) rad = 4;
        double frac = (kMax > kMin) ? (kVal - kMin) / (kMax - kMin) : 0.0;
        if (frac < 0) frac = 0; if (frac > 1) frac = 1;
        // knob sweep: 270 deg, from 7:30 (225 deg) clockwise through 12:00 to 4:30
        double a0 = 225.0;
        double a1 = a0 - 270.0 * frac;           // pointer angle (deg, math convention)
        // track
        NSBezierPath* track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:rad
                                     startAngle:a0 endAngle:a0 - 270.0 clockwise:YES];
        [[NSColor colorWithCalibratedWhite:0.22 alpha:1.0] setStroke];
        [track setLineWidth:3.0];
        [track stroke];
        // value arc
        if (frac > 0.001) {
            NSBezierPath* arc = [NSBezierPath bezierPath];
            [arc appendBezierPathWithArcWithCenter:NSMakePoint(cx, cy) radius:rad
                                       startAngle:a0 endAngle:a1 clockwise:YES];
            [[NSColor colorWithCalibratedRed:0.20 green:0.60 blue:1.0 alpha:1.0] setStroke];
            [arc setLineWidth:3.0];
            [arc stroke];
        }
        // body
        NSBezierPath* body = [NSBezierPath bezierPathWithOvalInRect:
                              NSMakeRect(cx - rad + 4, cy - rad + 4, (rad - 4) * 2, (rad - 4) * 2)];
        [[NSColor colorWithCalibratedWhite:0.16 alpha:1.0] setFill];
        [body fill];
        [[NSColor colorWithCalibratedWhite:0.30 alpha:1.0] setStroke];
        [body setLineWidth:1.0];
        [body stroke];
        // pointer
        double ar = a1 * M_PI / 180.0;
        NSPoint p0 = NSMakePoint(cx + cos(ar) * (rad * 0.35), cy + sin(ar) * (rad * 0.35));
        NSPoint p1 = NSMakePoint(cx + cos(ar) * (rad - 2), cy + sin(ar) * (rad - 2));
        NSBezierPath* ptr = [NSBezierPath bezierPath];
        [ptr moveToPoint:p0];
        [ptr lineToPoint:p1];
        [[NSColor colorWithCalibratedWhite:0.92 alpha:1.0] setStroke];
        [ptr setLineWidth:2.0];
        [ptr stroke];
    } @catch (NSException* e) {}
}
@end

@interface MasteringAUView : NSView {
    AudioUnit _au;
    NSView* _content;                   // logical 1280x880 UI; frame follows window, bounds fixed -> scales
    NSTimer* _timer;
    NSMutableDictionary* _sliders;      // @(pid) -> NSControl (NSSlider or KnobView)
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
@end

@implementation MasteringAUView

- (instancetype)initWithFrame:(NSRect)frame audioUnit:(AudioUnit)au {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    _au = au;
    // Content view keeps logical bounds (1280x880); its frame tracks the host
    // window, so AppKit scales drawing AND hit-testing automatically.
    _content = [[NSView alloc] initWithFrame:frame];
    [_content setBoundsSize:NSMakeSize(1280.0, 880.0)];
    [self addSubview:_content];
    _sliders = [NSMutableDictionary new];
    _valueLabels = [NSMutableDictionary new];
    _checks = [NSMutableDictionary new];
    _popups = [NSMutableDictionary new];
    _meterLabels = [NSMutableDictionary new];
    _meterBars = [NSMutableArray new];
    _grBars = [NSMutableDictionary new];
    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 210, 26) pullsDown:NO];
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
    [_content release];
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

// Host resized the plugin window: just let the content view's frame follow;
// its bounds stay logical (1280x880) so the whole UI scales to fit.
- (void)setFrameSize:(NSSize)s {
    @try {
        [super setFrameSize:s];
        _content.frame = self.bounds;
    } @catch (NSException* e) {}
}

#pragma mark - helpers

- (NSTextField*)makeLabel:(NSString*)s frame:(NSRect)r size:(CGFloat)fs bold:(BOOL)bold color:(NSColor*)c {
    NSTextField* t = [[NSTextField alloc] initWithFrame:r];
    t.stringValue = s;
    t.bezeled = NO; t.drawsBackground = NO; t.editable = NO; t.selectable = NO;
    t.textColor = c;
    t.font = bold ? [NSFont boldSystemFontOfSize:fs] : [NSFont systemFontOfSize:fs];
    t.alignment = NSLeftTextAlignment;
    [_content addSubview:t];
    return [t autorelease];
}

- (NSView*)cardWithFrame:(NSRect)r title:(NSString*)title {
    NSView* card = [[NSView alloc] initWithFrame:r];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 10;
    card.layer.backgroundColor = colCard().CGColor;
    card.layer.borderColor = colCardEdge().CGColor;
    card.layer.borderWidth = 1.0;
    [_content addSubview:card];
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

// Slider cell (EQ / multiband detail cards): slider on top, value below.
- (NSSlider*)addSliderCell:(uint32_t)pid frame:(NSRect)r {
    const ParamDesc& d = paramDescs()[pid];
    NSSlider* s = [[NSSlider alloc] initWithFrame:NSMakeRect(r.origin.x, r.origin.y, r.size.width, 15)];
    s.minValue = d.minV;
    s.maxValue = d.maxV;
    s.doubleValue = d.defV;
    s.tag = (NSInteger)pid;
    s.target = self;
    s.action = @selector(controlChanged:);
    [s setControlSize:NSSmallControlSize];
    [_content addSubview:s];
    _sliders[@(pid)] = s;
    NSTextField* vl = [self makeLabel:@"" frame:NSMakeRect(r.origin.x, r.origin.y - 11, r.size.width, 11)
                                 size:8 bold:NO color:colText()];
    vl.alignment = NSRightTextAlignment;
    _valueLabels[@(pid)] = vl;
    return [s autorelease];
}

// Rotary knob cell (signal-flow mini cards): knob on top, name + value below.
- (KnobView*)addKnobCell:(uint32_t)pid x:(CGFloat)x y:(CGFloat)y w:(CGFloat)w name:(NSString*)name {
    const ParamDesc& d = paramDescs()[pid];
    CGFloat dia = fmin(36.0, w - 6);
    KnobView* k = [[KnobView alloc] initWithFrame:NSMakeRect(x + (w - dia) / 2, y, dia, dia)];
    k->kMin = d.minV;
    k->kMax = d.maxV;
    k->kDef = d.defV;
    k->kVal = d.defV;
    k.tag = (NSInteger)pid;
    k.target = self;
    k.action = @selector(controlChanged:);
    [_content addSubview:k];
    _sliders[@(pid)] = k;
    NSTextField* nl = [self makeLabel:name frame:NSMakeRect(x, y - 11, w, 10) size:8 bold:NO color:colDim()];
    nl.alignment = NSCenterTextAlignment;
    NSTextField* vl = [self makeLabel:@"" frame:NSMakeRect(x, y - 21, w, 10) size:8 bold:NO color:colText()];
    vl.alignment = NSCenterTextAlignment;
    _valueLabels[@(pid)] = vl;
    return [k autorelease];
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
    [_content addSubview:b];
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
    [_content addSubview:p];
    _popups[@(pid)] = p;
    return [p autorelease];
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

#pragma mark - layout (fluid: all positions derive from W/H)

- (void)buildUI {
    const CGFloat W = _content.bounds.size.width;   // logical 1280
    const CGFloat H = _content.bounds.size.height;  // logical 880
    const CGFloat headerH = 56;
    const CGFloat top = H - headerH;
    const CGFloat bridgeH = 168;
    const CGFloat bridgeY = top - 10 - bridgeH;
    const CGFloat botY = 12;
    const CGFloat botH = fmin(212.0, H * 0.26);
    const CGFloat midY = botY + botH + 10;
    const CGFloat midH = bridgeY - 10 - midY;

    // ================= header =================
    DotView* dot = [[DotView alloc] initWithFrame:NSMakeRect(16, H - 42, 26, 26)];
    [_content addSubview:dot];
    [dot release];
    [self makeLabel:@"MasteringAU" frame:NSMakeRect(50, H - 42, 220, 28) size:22 bold:YES color:colText()];
    [self makeLabel:@"VIBE MASTERING" frame:NSMakeRect(52, H - 52, 150, 10) size:8 bold:YES color:colAccent()];

    [self makeLabel:@"PRESET" frame:NSMakeRect(284, H - 36, 46, 12) size:9 bold:YES color:colDim()];
    _presetPopup.frame = NSMakeRect(332, H - 41, 210, 26);
    _presetPopup.target = self;
    _presetPopup.action = @selector(presetChanged:);
    _presetPopup.font = [NSFont systemFontOfSize:11];
    [_content addSubview:_presetPopup];
    {
        [_presetPopup removeAllItems];
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

    [self addCheck:P_Bypass label:@"BYPASS" frame:NSMakeRect(560, H - 40, 92, 24)];
    _statusLabel = [self makeLabel:@"" frame:NSMakeRect(668, H - 38, W - 680, 16) size:11 bold:NO color:colDim()];

    // ================= meter bridge (full width, top) =================
    [self cardWithFrame:NSMakeRect(12, bridgeY, W - 24, bridgeH) title:@"METER BRIDGE \u00b7 BS.1770-4 LOUDNESS"];
    const CGFloat bx0 = 28, bTop = bridgeY + bridgeH;

    const CGFloat barX = fmax(230.0, W * 0.195);
    const CGFloat grBlockW = fmin(346.0, W * 0.28);
    const CGFloat barW = W - 24 - barX - grBlockW - 30;
    const CGFloat grX = barX + barW + 30;

    // left: big integrated readout
    [self makeLabel:@"INTEGRATED" frame:NSMakeRect(bx0, bTop - 52, 110, 11) size:8 bold:YES color:colDim()];
    _intLabel = [self makeLabel:@"-120.0 LUFS" frame:NSMakeRect(bx0, bTop - 92, barX - bx0 - 14, 38) size:32 bold:YES color:colAccent()];

    // middle: wide zone LUFS bar + scale ticks + 4 readout cells
    const CGFloat barY = bTop - 74, barH = 26;
    BarView* lufsBar = [[BarView alloc] initWithFrame:NSMakeRect(barX, barY, barW, barH)];
    lufsBar->minV = -36.0f; lufsBar->maxV = 3.0f; lufsBar->level = -120.0f; lufsBar->style = 2;
    [_content addSubview:lufsBar];
    [_meterBars addObject:lufsBar];
    [lufsBar release];
    {
        const float ticks[7] = { -36, -24, -18, -12, -6, 0, 3 };
        for (int i = 0; i < 7; ++i) {
            float frac = (ticks[i] + 36.0f) / 39.0f;
            CGFloat tx = barX + barW * frac;
            NSString* ts = [NSString stringWithFormat:@"%.0f", ticks[i]];
            NSTextField* tl = [self makeLabel:ts frame:NSMakeRect(tx - 14, barY - 12, 28, 10) size:8 bold:NO color:colDim()];
            tl.alignment = NSCenterTextAlignment;
        }
    }
    {
        const int cells[4] = { kMeterMomentary, kMeterShortTerm, kMeterLRA, kMeterTruePeak };
        const char* names[4] = { "MOMENTARY", "SHORT-TERM", "LRA", "TRUE PEAK" };
        const CGFloat cw = barW / 4.0;
        for (int i = 0; i < 4; ++i) {
            CGFloat cx = barX + i * cw;
            [self makeLabel:[NSString stringWithUTF8String:names[i]]
                      frame:NSMakeRect(cx, barY - 28, cw - 6, 10) size:8 bold:YES color:colDim()];
            NSTextField* vl = [self makeLabel:@"--" frame:NSMakeRect(cx, barY - 48, cw - 6, 18) size:13 bold:YES color:colText()];
            _meterLabels[@(cells[i])] = vl;
        }
    }

    // right: gain reduction bars LIM + B1..B4
    [self makeLabel:@"GAIN REDUCTION" frame:NSMakeRect(grX, bTop - 52, 180, 11) size:8 bold:YES color:colDim()];
    {
        const int grIds[5] = { kMeterLimGR, kMeterMbGR0, kMeterMbGR1, kMeterMbGR2, kMeterMbGR3 };
        const char* grNames[5] = { "LIM", "B1", "B2", "B3", "B4" };
        CGFloat gy = bTop - 70;
        for (int i = 0; i < 5; ++i) {
            [self makeLabel:[NSString stringWithUTF8String:grNames[i]]
                      frame:NSMakeRect(grX, gy, 26, 11) size:8 bold:NO color:colDim()];
            BarView* bar = [[BarView alloc] initWithFrame:NSMakeRect(grX + 30, gy, grBlockW - 116, 11)];
            bar->minV = 0.0f; bar->maxV = 24.0f; bar->level = 0.0f; bar->inverted = YES; bar->style = 1;
            [_content addSubview:bar];
            _grBars[@(grIds[i])] = bar;
            [bar release];
            NSTextField* vl = [self makeLabel:@"0.0" frame:NSMakeRect(grX + grBlockW - 80, gy, 80, 11) size:9 bold:NO color:colText()];
            vl.alignment = NSRightTextAlignment;
            _meterLabels[@(grIds[i])] = vl;
            gy -= 15;
        }
    }

    // ================= middle row: EQ + MULTIBAND =================
    const CGFloat eqX = 12, eqW = (W - 24 - 8) * 0.495;
    const CGFloat mbX = eqX + eqW + 8, mbW = W - 12 - mbX;
    [self cardWithFrame:NSMakeRect(eqX, midY, eqW, midH) title:@"EQ \u00b7 6 BAND"];
    [self cardWithFrame:NSMakeRect(mbX, midY, mbW, midH) title:@"MULTIBAND COMPRESSOR \u00b7 4 BAND"];

    // ---- EQ card (sliders) ----
    {
        const CGFloat x0 = eqX + 14;
        const CGFloat hdrY = midY + midH - 40;
        [self makeLabel:@"Band" frame:NSMakeRect(x0, hdrY, 30, 11) size:8 bold:YES color:colDim()];
        [self makeLabel:@"Type" frame:NSMakeRect(x0 + 64, hdrY, 100, 11) size:8 bold:YES color:colDim()];
        const char* eqCols[3] = { "FREQ", "GAIN", "Q" };
        const CGFloat cellW = (eqW - 28 - 172) / 3.0, cellX0 = x0 + 172;
        for (int c = 0; c < 3; ++c)
            [self makeLabel:[NSString stringWithUTF8String:eqCols[c]]
                      frame:NSMakeRect(cellX0 + c * cellW, hdrY, cellW, 11) size:8 bold:YES color:colDim()];
        const CGFloat ey0 = hdrY - 26;
        const CGFloat rowStep = fmax(30.0, (ey0 - (midY + 18)) / kNumEqBands);
        for (int b = 0; b < kNumEqBands; ++b) {
            CGFloat ey = ey0 - b * rowStep;
            [self makeLabel:[NSString stringWithFormat:@"EQ%d", b + 1]
                      frame:NSMakeRect(x0, ey + 3, 30, 15) size:11 bold:YES color:colAccent()];
            [self addCheck:eqParam(b, EqEnable) label:@"" frame:NSMakeRect(x0 + 34, ey + 1, 26, 16)];
            [self addPopup:eqParam(b, EqType) choices:kEqTypeChoices count:5
                     frame:NSMakeRect(x0 + 64, ey - 3, 100, 22)];
            [self addSliderCell:eqParam(b, EqFreq) frame:NSMakeRect(cellX0 + 0 * cellW, ey, cellW, 15)];
            [self addSliderCell:eqParam(b, EqGain) frame:NSMakeRect(cellX0 + 1 * cellW, ey, cellW, 15)];
            [self addSliderCell:eqParam(b, EqQ)    frame:NSMakeRect(cellX0 + 2 * cellW, ey, cellW, 15)];
        }
    }

    // ---- MULTIBAND card (sliders) ----
    {
        const CGFloat x0 = mbX + 14;
        const CGFloat iw = mbW - 28;
        const CGFloat hdrY = midY + midH - 40;
        [self makeLabel:@"CROSSOVERS" frame:NSMakeRect(x0, hdrY, 90, 11) size:8 bold:YES color:colDim()];
        const uint32_t xoIds[3] = { P_MbXover1, P_MbXover2, P_MbXover3 };
        const char* xoNames[3] = { "X1", "X2", "X3" };
        const CGFloat xoW = (iw - 16) / 3.0;
        for (int i = 0; i < 3; ++i) {
            CGFloat cx = x0 + i * (xoW + 8);
            [self makeLabel:[NSString stringWithUTF8String:xoNames[i]]
                      frame:NSMakeRect(cx, hdrY - 26, 30, 10) size:8 bold:NO color:colDim()];
            [self addSliderCell:xoIds[i] frame:NSMakeRect(cx, hdrY - 40, xoW, 15)];
        }
        const CGFloat colHdrY = hdrY - 72;
        const CGFloat cellW = (iw - 62) / 5.0, cellX0 = x0 + 62;
        [self makeLabel:@"Band" frame:NSMakeRect(x0, colHdrY, 30, 11) size:8 bold:YES color:colDim()];
        const char* mbCols[5] = { "THR", "RATIO", "ATK", "REL", "MAKEUP" };
        for (int c = 0; c < 5; ++c)
            [self makeLabel:[NSString stringWithUTF8String:mbCols[c]]
                      frame:NSMakeRect(cellX0 + c * cellW, colHdrY, cellW, 11) size:8 bold:YES color:colDim()];
        const CGFloat by0 = colHdrY - 26;
        const CGFloat rowStep = fmax(30.0, (by0 - (midY + 18)) / kNumMbBands);
        for (int b = 0; b < kNumMbBands; ++b) {
            CGFloat by = by0 - b * rowStep;
            [self makeLabel:[NSString stringWithFormat:@"B%d", b + 1]
                      frame:NSMakeRect(x0, by + 3, 30, 15) size:11 bold:YES color:colWarn()];
            [self addCheck:mbParam(b, MbEnable) label:@"" frame:NSMakeRect(x0 + 34, by + 1, 26, 16)];
            const uint32_t fields[5] = { MbThresh, MbRatio, MbAttack, MbRelease, MbMakeup };
            for (int f = 0; f < 5; ++f)
                [self addSliderCell:mbParam(b, fields[f]) frame:NSMakeRect(cellX0 + f * cellW, by, cellW, 15)];
        }
    }

    // ================= bottom row: signal-flow mini cards (rotary knobs) =================
    const CGFloat mcGap = 8, mcX0 = 12;
    const CGFloat mcW = (W - 24 - 5 * mcGap) / 6.0;
    const char* mcTitles[6] = { "1 \u00b7 INPUT", "2 \u00b7 HIGH-PASS", "3 \u00b7 STEREO",
                                "4 \u00b7 SATURATION", "5 \u00b7 LIMITER", "6 \u00b7 OUTPUT" };
    for (int i = 0; i < 6; ++i) {
        CGFloat cx = mcX0 + i * (mcW + mcGap);
        [self cardWithFrame:NSMakeRect(cx, botY, mcW, botH)
                      title:[NSString stringWithUTF8String:mcTitles[i]]];
        if (i < 5) {
            NSTextField* ar = [self makeLabel:@"\u2192" frame:NSMakeRect(cx + mcW - 1, botY + botH / 2 - 7, 10, 14)
                                         size:11 bold:YES color:colDim()];
            ar.alignment = NSCenterTextAlignment;
        }
    }
    const CGFloat knobRowY = botY + botH - 102;
    // card 1: INPUT
    {
        CGFloat ix = mcX0 + 10, iw = mcW - 20;
        [self addKnobCell:P_InputGain x:ix y:knobRowY w:iw name:@"Input gain"];
    }
    // card 2: HIGH-PASS
    {
        CGFloat cx = mcX0 + 1 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        [self addCheck:P_HpEnable label:@"ENABLED" frame:NSMakeRect(ix, botY + botH - 42, iw, 20)];
        [self addKnobCell:P_HpFreq x:ix y:knobRowY w:iw name:@"Cutoff"];
    }
    // card 3: STEREO
    {
        CGFloat cx = mcX0 + 2 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        [self addCheck:P_MonoLowEnable label:@"MONO LOW" frame:NSMakeRect(ix, botY + botH - 42, iw, 20)];
        [self addKnobCell:P_MonoLowFreq x:ix y:knobRowY w:iw / 2 name:@"Mono freq"];
        [self addKnobCell:P_Width x:ix + iw / 2 y:knobRowY w:iw / 2 name:@"Width"];
    }
    // card 4: SATURATION
    {
        CGFloat cx = mcX0 + 3 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        [self addCheck:P_SatEnable label:@"ENABLED" frame:NSMakeRect(ix, botY + botH - 42, iw, 20)];
        [self addKnobCell:P_SatDrive x:ix y:knobRowY w:iw / 2 name:@"Drive"];
        [self addKnobCell:P_SatMix x:ix + iw / 2 y:knobRowY w:iw / 2 name:@"Mix"];
        CGFloat py = knobRowY - 58;
        [self makeLabel:@"Mode" frame:NSMakeRect(ix, py, 40, 12) size:8 bold:NO color:colDim()];
        [self addPopup:P_SatMode choices:kSatModeChoices count:3 frame:NSMakeRect(ix + 44, py - 4, iw - 44, 22)];
    }
    // card 5: LIMITER
    {
        CGFloat cx = mcX0 + 4 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        [self addCheck:P_LimEnable label:@"ENABLED" frame:NSMakeRect(ix, botY + botH - 42, iw, 20)];
        [self addKnobCell:P_LimCeiling x:ix y:knobRowY w:iw / 3 name:@"Ceiling"];
        [self addKnobCell:P_LimLookahead x:ix + iw / 3 y:knobRowY w:iw / 3 name:@"Lookahead"];
        [self addKnobCell:P_LimRelease x:ix + 2 * iw / 3 y:knobRowY w:iw / 3 name:@"Release"];
    }
    // card 6: OUTPUT
    {
        CGFloat cx = mcX0 + 5 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        [self addCheck:P_DitherEnable label:@"DITHER" frame:NSMakeRect(ix, botY + botH - 42, iw, 20)];
        [self addKnobCell:P_OutputTrim x:ix y:knobRowY w:iw name:@"Output trim"];
    }
}

@end

@interface MasteringAUViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation MasteringAUViewFactory
- (unsigned)interfaceVersion { return 0; }
- (NSString*)description { return @"MasteringAU"; }
- (NSView*)uiViewForAudioUnit:(AudioUnit)inAudioUnit withSize:(NSSize)inPreferredSize {
    // Return a moderate window size; the UI inside scales to whatever the
    // host window ends up being (content bounds are fixed at 1280x880).
    CGFloat w = (inPreferredSize.width > 0) ? fmin(fmax(inPreferredSize.width, 720.0), 1200.0) : 1180.0;
    CGFloat h = (inPreferredSize.height > 0) ? fmin(fmax(inPreferredSize.height, 520.0), 820.0) : 800.0;
    MasteringAUView* v = [[MasteringAUView alloc] initWithFrame:NSMakeRect(0, 0, w, h) audioUnit:inAudioUnit];
    return [v autorelease];
}
@end
