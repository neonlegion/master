// Cocoa UI for the MasteringAU AUv2 component. Loaded by the host through
// kAudioUnitProperty_CocoaUI (class MasteringAUViewFactory, conforming to
// AUCocoaUIBase). All controls are bound to AU parameters in the global scope
// via AudioUnitGet/SetParameter; meters are read-only parameters (ids 1000+)
// refreshed by a 30 Hz timer. No UI code may ever throw into the host: all
// drawing and actions are wrapped in @try/@catch.
//
// Layout (v3, inspired by FabFilter Pro-L 2 / iZotope Ozone meter-bridge UIs):
//   header bar      logo, title, preset popup, BYPASS, status line
//   meter bridge    full-width: big integrated LUFS readout, wide zone LUFS
//                   bar with scale ticks, MOM/S/LRA/TP readouts, GR bars
//   middle row      EQ (6-band) and MULTIBAND (4-band) detail cards
//   bottom row      six mini cards in signal-flow order:
//                   1 INPUT -> 2 HIGH-PASS -> 3 STEREO -> 4 SATURATION
//                   -> 5 LIMITER -> 6 OUTPUT, each with a prominent enable

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
static NSColor* colAmber(void)  { return [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.15 alpha:1.0]; }

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
            // LUFS zones across minV..maxV: green up to -18, amber up to -6, red above
            CGFloat x0 = r.origin.x + 1, y0 = r.origin.y + 1, h = r.size.height - 2;
            CGFloat span = r.size.width - 2;
            float z1 = (float)((-18.0 - minV) / (maxV - minV));
            float z2 = (float)((-6.0 - minV) / (maxV - minV));
            [colGood setFill];  NSRectFill(NSMakeRect(x0, y0, span * z1, h));
            [colAmber setFill]; NSRectFill(NSMakeRect(x0 + span * z1, y0, span * (z2 - z1), h));
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
        [colAccent setFill];
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

// Slider cell: slider on top, small right-aligned value readout below it.
// Cell occupies r (slider) plus 11 pt below for the value label.
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
    [self addSubview:s];
    _sliders[@(pid)] = s;
    NSTextField* vl = [self makeLabel:@"" frame:NSMakeRect(r.origin.x, r.origin.y - 11, r.size.width, 11)
                                 size:8 bold:NO color:colText()];
    vl.alignment = NSRightTextAlignment;
    _valueLabels[@(pid)] = vl;
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

- (void)buildUI {
    const CGFloat W = self.bounds.size.width;
    const CGFloat H = self.bounds.size.height;
    const CGFloat headerH = 56;
    const CGFloat top = H - headerH;          // 824
    const CGFloat bridgeH = 168;
    const CGFloat bridgeY = top - 10 - bridgeH; // 646
    const CGFloat botH = 212;
    const CGFloat botY = 12;
    const CGFloat midY = botY + botH + 10;      // 234
    const CGFloat midH = bridgeY - 10 - midY;   // 402

    // ================= header =================
    DotView* dot = [[DotView alloc] initWithFrame:NSMakeRect(16, H - 42, 26, 26)];
    [self addSubview:dot];
    [dot release];
    [self makeLabel:@"MasteringAU" frame:NSMakeRect(50, H - 42, 220, 28) size:22 bold:YES color:colText()];
    [self makeLabel:@"VIBE MASTERING" frame:NSMakeRect(52, H - 52, 150, 10) size:8 bold:YES color:colAccent()];

    [self makeLabel:@"PRESET" frame:NSMakeRect(284, H - 36, 46, 12) size:9 bold:YES color:colDim()];
    _presetPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(332, H - 41, 210, 26) pullsDown:NO];
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

    [self addCheck:P_Bypass label:@"BYPASS" frame:NSMakeRect(560, H - 40, 92, 24)];
    _statusLabel = [self makeLabel:@"" frame:NSMakeRect(668, H - 38, W - 680, 16) size:11 bold:NO color:colDim()];

    // ================= meter bridge (full width, top) =================
    [self cardWithFrame:NSMakeRect(12, bridgeY, W - 24, bridgeH) title:@"METER BRIDGE \u00b7 BS.1770-4 LOUDNESS"];
    const CGFloat bx0 = 28, bTop = bridgeY + bridgeH;   // card inner origin/top

    // left: big integrated readout
    [self makeLabel:@"INTEGRATED" frame:NSMakeRect(bx0, bTop - 52, 110, 11) size:8 bold:YES color:colDim()];
    _intLabel = [self makeLabel:@"-120.0 LUFS" frame:NSMakeRect(bx0, bTop - 92, 210, 38) size:32 bold:YES color:colAccent()];

    // middle: wide zone LUFS bar + scale ticks + 4 readout cells
    const CGFloat barX = 250, barW = 640, barY = bTop - 74, barH = 26;
    BarView* lufsBar = [[BarView alloc] initWithFrame:NSMakeRect(barX, barY, barW, barH)];
    lufsBar->minV = -36.0f; lufsBar->maxV = 3.0f; lufsBar->level = -120.0f; lufsBar->style = 2;
    [self addSubview:lufsBar];
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
    const CGFloat grX = 912, grW = W - 24 - grX - 12;
    [self makeLabel:@"GAIN REDUCTION" frame:NSMakeRect(grX, bTop - 52, 180, 11) size:8 bold:YES color:colDim()];
    {
        const int grIds[5] = { kMeterLimGR, kMeterMbGR0, kMeterMbGR1, kMeterMbGR2, kMeterMbGR3 };
        const char* grNames[5] = { "LIM", "B1", "B2", "B3", "B4" };
        CGFloat gy = bTop - 70;
        for (int i = 0; i < 5; ++i) {
            [self makeLabel:[NSString stringWithUTF8String:grNames[i]]
                      frame:NSMakeRect(grX, gy, 26, 11) size:8 bold:NO color:colDim()];
            BarView* bar = [[BarView alloc] initWithFrame:NSMakeRect(grX + 30, gy, grW - 116, 11)];
            bar->minV = 0.0f; bar->maxV = 24.0f; bar->level = 0.0f; bar->inverted = YES; bar->style = 1;
            [self addSubview:bar];
            _grBars[@(grIds[i])] = bar;
            [bar release];
            NSTextField* vl = [self makeLabel:@"0.0" frame:NSMakeRect(grX + grW - 80, gy, 80, 11) size:9 bold:NO color:colText()];
            vl.alignment = NSRightTextAlignment;
            _meterLabels[@(grIds[i])] = vl;
            gy -= 15;
        }
    }

    // ================= middle row: EQ + MULTIBAND =================
    const CGFloat eqX = 12, eqW = 620;
    const CGFloat mbX = eqX + eqW + 8, mbW = W - 12 - mbX;
    [self cardWithFrame:NSMakeRect(eqX, midY, eqW, midH) title:@"EQ \u00b7 6 BAND"];
    [self cardWithFrame:NSMakeRect(mbX, midY, mbW, midH) title:@"MULTIBAND COMPRESSOR \u00b7 4 BAND"];

    // ---- EQ card ----
    {
        const CGFloat x0 = eqX + 14;
        const CGFloat hdrY = midY + midH - 40;
        [self makeLabel:@"Band" frame:NSMakeRect(x0, hdrY, 30, 11) size:8 bold:YES color:colDim()];
        [self makeLabel:@"Type" frame:NSMakeRect(x0 + 64, hdrY, 100, 11) size:8 bold:YES color:colDim()];
        const char* eqCols[3] = { "FREQ", "GAIN", "Q" };
        const CGFloat cellW = 140, cellX0 = x0 + 172;
        for (int c = 0; c < 3; ++c)
            [self makeLabel:[NSString stringWithUTF8String:eqCols[c]]
                      frame:NSMakeRect(cellX0 + c * cellW, hdrY, cellW, 11) size:8 bold:YES color:colDim()];
        CGFloat ey = hdrY - 26;
        for (int b = 0; b < kNumEqBands; ++b) {
            [self makeLabel:[NSString stringWithFormat:@"EQ%d", b + 1]
                      frame:NSMakeRect(x0, ey + 3, 30, 15) size:11 bold:YES color:colAccent()];
            [self addCheck:eqParam(b, EqEnable) label:@"" frame:NSMakeRect(x0 + 34, ey + 1, 26, 16)];
            [self addPopup:eqParam(b, EqType) choices:kEqTypeChoices count:5
                     frame:NSMakeRect(x0 + 64, ey - 3, 100, 22)];
            [self addSliderCell:eqParam(b, EqFreq) frame:NSMakeRect(cellX0 + 0 * cellW, ey, cellW, 15)];
            [self addSliderCell:eqParam(b, EqGain) frame:NSMakeRect(cellX0 + 1 * cellW, ey, cellW, 15)];
            [self addSliderCell:eqParam(b, EqQ)    frame:NSMakeRect(cellX0 + 2 * cellW, ey, cellW, 15)];
            ey -= 46;
        }
    }

    // ---- MULTIBAND card ----
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
        const CGFloat cellW = 106, cellX0 = x0 + 62;
        [self makeLabel:@"Band" frame:NSMakeRect(x0, colHdrY, 30, 11) size:8 bold:YES color:colDim()];
        const char* mbCols[5] = { "THR", "RATIO", "ATK", "REL", "MAKEUP" };
        for (int c = 0; c < 5; ++c)
            [self makeLabel:[NSString stringWithUTF8String:mbCols[c]]
                      frame:NSMakeRect(cellX0 + c * cellW, colHdrY, cellW, 11) size:8 bold:YES color:colDim()];
        CGFloat by = colHdrY - 26;
        for (int b = 0; b < kNumMbBands; ++b) {
            [self makeLabel:[NSString stringWithFormat:@"B%d", b + 1]
                      frame:NSMakeRect(x0, by + 3, 30, 15) size:11 bold:YES color:colWarn()];
            [self addCheck:mbParam(b, MbEnable) label:@"" frame:NSMakeRect(x0 + 34, by + 1, 26, 16)];
            const uint32_t fields[5] = { MbThresh, MbRatio, MbAttack, MbRelease, MbMakeup };
            for (int f = 0; f < 5; ++f)
                [self addSliderCell:mbParam(b, fields[f]) frame:NSMakeRect(cellX0 + f * cellW, by, cellW, 15)];
            by -= 46;
        }
    }

    // ================= bottom row: signal-flow mini cards =================
    const CGFloat mcW = 202, mcGap = 8, mcX0 = 12;
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
    // helper locals for mini-card content
    // card content top: title row then controls
    // card 1: INPUT — input gain
    {
        CGFloat cx = mcX0, ix = cx + 10, iw = mcW - 20;
        CGFloat y = botY + botH - 40;
        [self makeLabel:@"Input gain" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_InputGain frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
    }
    // card 2: HIGH-PASS — prominent enable + freq
    {
        CGFloat cx = mcX0 + 1 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        CGFloat y = botY + botH - 40;
        [self addCheck:P_HpEnable label:@"ENABLED" frame:NSMakeRect(ix, y, iw, 20)];
        y -= 30;
        [self makeLabel:@"Cutoff" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_HpFreq frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
    }
    // card 3: STEREO — mono low enable + freq + width
    {
        CGFloat cx = mcX0 + 2 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        CGFloat y = botY + botH - 40;
        [self addCheck:P_MonoLowEnable label:@"MONO LOW" frame:NSMakeRect(ix, y, iw, 20)];
        y -= 30;
        [self makeLabel:@"Mono freq" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_MonoLowFreq frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
        y -= 30;
        [self makeLabel:@"Width" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_Width frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
    }
    // card 4: SATURATION — enable + drive + mode + mix
    {
        CGFloat cx = mcX0 + 3 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        CGFloat y = botY + botH - 40;
        [self addCheck:P_SatEnable label:@"ENABLED" frame:NSMakeRect(ix, y, iw, 20)];
        y -= 30;
        [self makeLabel:@"Drive" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_SatDrive frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
        y -= 30;
        [self makeLabel:@"Mode" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addPopup:P_SatMode choices:kSatModeChoices count:3 frame:NSMakeRect(ix + 66, y - 4, iw - 66, 22)];
        y -= 30;
        [self makeLabel:@"Mix" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_SatMix frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
    }
    // card 5: LIMITER — enable + ceiling + lookahead + release
    {
        CGFloat cx = mcX0 + 4 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        CGFloat y = botY + botH - 40;
        [self addCheck:P_LimEnable label:@"ENABLED" frame:NSMakeRect(ix, y, iw, 20)];
        y -= 30;
        [self makeLabel:@"Ceiling" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_LimCeiling frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
        y -= 30;
        [self makeLabel:@"Lookahead" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_LimLookahead frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
        y -= 30;
        [self makeLabel:@"Release" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_LimRelease frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
    }
    // card 6: OUTPUT — output trim + dither
    {
        CGFloat cx = mcX0 + 5 * (mcW + mcGap), ix = cx + 10, iw = mcW - 20;
        CGFloat y = botY + botH - 40;
        [self addCheck:P_DitherEnable label:@"DITHER" frame:NSMakeRect(ix, y, iw, 20)];
        y -= 30;
        [self makeLabel:@"Output trim" frame:NSMakeRect(ix, y, 70, 12) size:8 bold:NO color:colDim()];
        [self addSliderCell:P_OutputTrim frame:NSMakeRect(ix + 66, y + 1, iw - 66, 15)];
    }
}

@end

@interface MasteringAUViewFactory : NSObject <AUCocoaUIBase>
@end

@implementation MasteringAUViewFactory
- (unsigned)interfaceVersion { return 0; }
- (NSString*)description { return @"MasteringAU"; }
- (NSView*)uiViewForAudioUnit:(AudioUnit)inAudioUnit withSize:(NSSize)inPreferredSize {
    CGFloat w = MAX(inPreferredSize.width, 1280.0);
    CGFloat h = MAX(inPreferredSize.height, 880.0);
    MasteringAUView* v = [[MasteringAUView alloc] initWithFrame:NSMakeRect(0, 0, w, h) audioUnit:inAudioUnit];
    return [v autorelease];
}
@end
