#ifdef __APPLE__

#include "Base.h"
#include "Platform.h"
#include "FileSystem.h"
#include "Game.h"
#include "Form.h"
#include "ScriptController.h"
#include <unistd.h>
#include <IOKit/hid/IOHIDLib.h>
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CVDisplayLink.h>
#import <OpenGL/OpenGL.h>
#import <mach/mach_time.h>
#import <Foundation/Foundation.h>

// These should probably be moved to a platform common file
#define SONY_USB_VENDOR_ID          0x54c
#define SONY_USB_PS3_PRODUCT_ID     0x268


using namespace std;
using namespace gameplay;

@class View;
@class OSXGamepad;

// Default to 720p
static int __width = 1280;
static int __height = 720;

static float ACCELEROMETER_FACTOR_X = 90.0f / __width;
static float ACCELEROMETER_FACTOR_Y = 90.0f / __height;

static double __timeStart;
static double __timeAbsolute;
static bool __vsync = WINDOW_VSYNC;
static float __pitch;
static float __roll;
static int __lx;
static int __ly;
static bool __hasMouse = false;
static bool __leftMouseDown = false;
static bool __rightMouseDown = false;
static bool __otherMouseDown = false;
static bool __shiftDown = false;
static char* __title = NULL;
static bool __fullscreen = false;
static void* __attachToWindow = NULL;
static bool __mouseCaptured = false;
static CGPoint __mouseCapturePoint;
static bool __cursorVisible = true;
static View* __view = NULL;

static NSMutableDictionary *__activeGamepads = NULL;
static NSMutableArray *__gamepads = NULL;
static IOHIDManagerRef __hidManagerRef = NULL;

// Gamepad Helper Function
OSXGamepad *gamepadForLocationID(NSNumber *locationID);
OSXGamepad *gamepadForLocationIDValue(unsigned int locationIDValue);
OSXGamepad *gamepadForGameHandle(int gameHandle);


// IOHid Helper Functions
CFMutableDictionaryRef IOHIDCreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage);
CFStringRef IOHIDDeviceGetStringProperty(IOHIDDeviceRef deviceRef, CFStringRef key);
int IOHIDDeviceGetIntProperty(IOHIDDeviceRef deviceRef, CFStringRef key);

// IOHid Callbacks
static void hidDeviceDiscoveredCallback(void *inContext, IOReturn inResult, void *inSender, IOHIDDeviceRef inIOHIDDeviceRef);
static void hidDeviceRemovalCallback(void *inContext, IOReturn inResult, void *inSender, IOHIDDeviceRef inIOHIDDeviceRef);
static void hidDeviceValueAvailableCallback(void *inContext, IOReturn inResult,  void *inSender);



double getMachTimeInMilliseconds()
{
    static const double kOneMillion = 1000 * 1000;
    static mach_timebase_info_data_t s_timebase_info;
    
    if (s_timebase_info.denom == 0) 
        (void) mach_timebase_info(&s_timebase_info);
    
    // mach_absolute_time() returns billionth of seconds, so divide by one million to get milliseconds
    GP_ASSERT(s_timebase_info.denom);
    return ((double)mach_absolute_time() * (double)s_timebase_info.numer) / (kOneMillion * (double)s_timebase_info.denom);
}


@interface OSXGamepadAxis : NSObject
{
    IOHIDElementRef e;
    CFIndex v;
    CFIndex logMin;
    CFIndex logMax;
}
+ gamepadAxisWithAxisElement:(IOHIDElementRef)element;
- initWithAxisElement:(IOHIDElementRef)element;
- (IOHIDElementRef)element;
- (IOHIDElementCookie)cookie;
- (uint32_t)usage;
- (uint32_t)usagePage;
- (CFIndex)logicalMinimum;
- (CFIndex)logicalMaximum;

- (float)calibratedValue;
- (CFIndex)value;
- (void)setValue:(CFIndex)value;
@end
@implementation OSXGamepadAxis
+ gamepadAxisWithAxisElement:(IOHIDElementRef)element
{
    return [[[[self class] alloc] initWithAxisElement:element] autorelease];
}
- initWithAxisElement:(IOHIDElementRef)element
{
    if((self = [super init]))
    {
        e = (IOHIDElementRef)CFRetain(element);
    }
    return self;
}
- (void)dealloc
{
    CFRelease(e);
    [super dealloc];
}
- (IOHIDElementRef)element
{
    return e;
}
- (IOHIDElementCookie)cookie
{
    return IOHIDElementGetCookie(e);
}
- (bool)isHatSwitch {
    return (IOHIDElementGetUsage(e) == kHIDUsage_GD_Hatswitch);
}
- (uint32_t)usage
{
    return IOHIDElementGetUsage(e);
}
- (uint32_t)usagePage
{
    return IOHIDElementGetUsagePage(e);
}
- (CFIndex)logicalMinimum
{
    return IOHIDElementGetLogicalMin(e);    
}
- (CFIndex)logicalMaximum
{
    return IOHIDElementGetLogicalMax(e);
}
- (float)calibratedValue
{
    float cmax = 2.0f;
    float cmin = 0.0f;
    return ((((v - [self logicalMinimum]) * (cmax - cmin)) / ([self logicalMaximum] - [self logicalMinimum])) + cmin - 1.0f);    
}
- (CFIndex)value
{
    return v;
}
- (void)setValue:(CFIndex)value
{
    v = value;
}
@end

@interface OSXGamepadButton : NSObject
{
    IOHIDElementRef e;
    IOHIDElementRef te;
    bool state;
    int triggerValue;
}
+ gamepadButtonWithButtonElement:(IOHIDElementRef)element;
- initWithButtonElement:(IOHIDElementRef)element;
- (void)setTriggerElement:(IOHIDElementRef)element;
- (IOHIDElementRef)element;
- (IOHIDElementCookie)cookie;
- (IOHIDElementRef)triggerElement;
- (IOHIDElementCookie)triggerCookie;

- (bool)isTriggerButton;
- (uint32_t)usage;
- (uint32_t)usagePage;
- (int)stateValue;
- (float)calibratedStateValue;
- (void)setStateValue:(int)value;
- (bool)state;
- (void)setState:(bool)state;
@end
@implementation OSXGamepadButton
+ gamepadButtonWithButtonElement:(IOHIDElementRef)element
{
    return [[[[self class] alloc] initWithButtonElement:element] autorelease];
}
- initWithButtonElement:(IOHIDElementRef)element
{
    if((self = [super init]))
    {
        e = (IOHIDElementRef)CFRetain(element);
        te = NULL;
        state = false;
    }
    return self;
}
- (void)dealloc
{
    CFRelease(e);
    if(te != NULL) CFRelease(te);
    [super dealloc];
}
- (void)setTriggerElement:(IOHIDElementRef)element {
    if(te)
    {
        CFRelease(te);
        te = NULL;
    }
    if(element)
    {
        te = (IOHIDElementRef)CFRetain(element);
    }
}
- (IOHIDElementRef)element
{
    return e;
}
- (IOHIDElementCookie)cookie
{
    return IOHIDElementGetCookie(e);
}
- (IOHIDElementRef)triggerElement
{
    return te;
}
- (IOHIDElementCookie)triggerCookie
{
    return IOHIDElementGetCookie(te);
}
- (bool)isTriggerButton
{
    return (te != NULL);
}
- (uint32_t)usage
{
    return IOHIDElementGetUsage(e);
}
- (uint32_t)usagePage
{
    return IOHIDElementGetUsagePage(e);
}
- (void)setStateValue:(int)value {
    triggerValue = value;
}
- (int)stateValue
{
    return triggerValue;
}
- (float)calibratedStateValue
{
    return (float)triggerValue; // TODO: Need to figure out expected range
}
- (bool)state
{
    return state;
}
- (void)setState:(bool)s
{
    state = s;
}
@end

@interface OSXGamepad : NSObject
{
    IOHIDDeviceRef hidDeviceRef;
    IOHIDQueueRef queueRef;
    NSMutableArray *buttons;
    NSMutableArray *triggerButtons;
    NSMutableArray *axes;
}
@property (assign) IOHIDDeviceRef hidDeviceRef;
@property (assign) IOHIDQueueRef queueRef;
@property (retain) NSMutableArray *buttons;
@property (retain) NSMutableArray *triggerButtons;
@property (retain) NSMutableArray *axes;

- initWithDevice:(IOHIDDeviceRef)rawDevice;
- (IOHIDDeviceRef)rawDevice;
- (NSNumber*)locationID;

- (void)initializeGamepadElements;
- (OSXGamepadButton*)buttonWithCookie:(IOHIDElementCookie)cookie;

- (bool)startListening;
- (void)stopListening;

- (NSString *)identifierName;
- (NSString *)productName;
- (NSString *)manufacturerName;
- (NSString *)serialNumber;
- (int)vendorID;
- (int)productID;

- (NSUInteger)numberOfAxes;
- (NSUInteger)numberOfSticks;
- (NSUInteger)numberOfButtons;
- (NSUInteger)numberOfTriggerButtons;
- (OSXGamepadAxis*)axisAtIndex:(NSUInteger)index;
- (OSXGamepadButton*)buttonAtIndex:(NSUInteger)index;
- (OSXGamepadButton*)triggerButtonAtIndex:(NSUInteger)index;
@end

@implementation OSXGamepad

@synthesize hidDeviceRef;
@synthesize queueRef;
@synthesize buttons;
@synthesize triggerButtons;
@synthesize axes;

- initWithDevice:(IOHIDDeviceRef)rawDevice
{
    if((self = [super init]))
    {
        [self setButtons:[NSMutableArray array]];
        [self setTriggerButtons:[NSMutableArray array]];
        [self setAxes:[NSMutableArray array]];

        CFRetain(rawDevice);
        IOHIDQueueRef queue = IOHIDQueueCreate(CFAllocatorGetDefault(), rawDevice, 10, kIOHIDOptionsTypeNone);
        [self setHidDeviceRef:rawDevice];
        [self setQueueRef:queue];
        
        [self initializeGamepadElements];
        [self startListening];
    }
    return self;
}
- (void)dealloc
{
    [self stopListening];
    
    CFRelease([self rawDevice]);
    CFRelease([self queueRef]);
    [self setQueueRef:NULL];
    [self setHidDeviceRef:NULL];
    
    [self setButtons:NULL];
    [self setTriggerButtons:NULL];
    [self setAxes:NULL];
    [super dealloc];
}
- (IOHIDDeviceRef)rawDevice
{
    return [self hidDeviceRef];
}
- (NSNumber*)locationID
{
    return (NSNumber*)IOHIDDeviceGetProperty([self rawDevice], CFSTR(kIOHIDLocationIDKey));
}

- (void)initializeGamepadElements
{
    CFArrayRef elements = IOHIDDeviceCopyMatchingElements([self rawDevice], NULL, kIOHIDOptionsTypeNone);
    for(int i = 0; i < CFArrayGetCount(elements); i++)
    {
        IOHIDElementRef hidElement = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        IOHIDElementType type = IOHIDElementGetType(hidElement);

        if (type == kIOHIDElementTypeInput_Misc || type == kIOHIDElementTypeInput_Axis)
        {
            uint32_t pageUsage = IOHIDElementGetUsage(hidElement);
            IOHIDElementCookie cookie = IOHIDElementGetCookie(hidElement);

            switch(pageUsage)
            {
                case kHIDUsage_GD_X:
                case kHIDUsage_GD_Y:
                case kHIDUsage_GD_Z:
                case kHIDUsage_GD_Rx:
                case kHIDUsage_GD_Ry:
                case kHIDUsage_GD_Rz:
                {
                    OSXGamepadAxis *axis = [OSXGamepadAxis gamepadAxisWithAxisElement:hidElement];
                    [[self axes] addObject:axis];
                }
                    break;
                default:
                    // Ignore the pointers
                    // Note: Some of the pointers are for the 6-axis accelerometer in a PS3 controller
                    // Note: L2/R2 triggers are at cookie 39 and 40 base 10 tied to 9 and 10 button elements
                    break;
            }

        }
        if(type == kIOHIDElementTypeInput_Button)
        {
            OSXGamepadButton *button = [OSXGamepadButton gamepadButtonWithButtonElement:hidElement];
            [[self buttons] addObject:button];
        }
    }
    // Go back and get proprietary information (e.g. triggers) and asscoaite with appropriate values
    // Example for other trigger buttons
    uint32_t vendorID = [self vendorID];
    uint32_t productID = [self productID];
    for(int i = 0; i < CFArrayGetCount(elements); i++)
    {
        IOHIDElementRef hidElement = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        IOHIDElementType type = IOHIDElementGetType(hidElement);
        IOHIDElementCookie cookie = IOHIDElementGetCookie(hidElement);
        
        // Gamepad specific code
        // Not sure if there is a better way to associate buttons and misc hid elements :/
        if(vendorID == SONY_USB_VENDOR_ID && productID == SONY_USB_PS3_PRODUCT_ID)
        {
            if((unsigned long)cookie == 39)
            {
                OSXGamepadButton *leftTrigger = [self buttonWithCookie:(IOHIDElementCookie)9];
                if(leftTrigger)
                {
                    [leftTrigger setTriggerElement:hidElement];
                    [[self triggerButtons] addObject:leftTrigger];
                    //[[self buttons] removeObject:leftTrigger]; Defer to gamepad team on this line..  not sure how they intend to tackle
                }
            }
            if((unsigned long)cookie == 40)
            {
                OSXGamepadButton *rightTrigger = [self buttonWithCookie:(IOHIDElementCookie)10];
                if(rightTrigger)
                {
                    [rightTrigger setTriggerElement:hidElement];
                    [[self triggerButtons] addObject:rightTrigger];
                    //[[self buttons] removeObject:rightTrigger];
                }
            }
        }
    }
    
}
- (OSXGamepadButton*)buttonWithCookie:(IOHIDElementCookie)cookie {
    for(OSXGamepadButton *b in [self buttons]) {
        if([b cookie] == cookie) return b;
    }
    return NULL;
}

- (bool)startListening
{
    IOReturn kr = IOHIDDeviceOpen([self hidDeviceRef], kIOHIDOptionsTypeNone);
    if(kr != 0) {
        return false;
    }
    IOHIDDeviceScheduleWithRunLoop([self hidDeviceRef], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    
    IOHIDQueueStart([self queueRef]);
    IOHIDQueueRegisterValueAvailableCallback([self queueRef], hidDeviceValueAvailableCallback, self);
    
    CFArrayRef elements = (CFArrayRef)[self watchedElements];
    for(int i = 0; i < CFArrayGetCount(elements); i++)
    {
        IOHIDElementRef hidElement = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
        IOHIDQueueAddElement([self queueRef], hidElement);
    }
    IOHIDQueueScheduleWithRunLoop([self queueRef], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    
    return true;
}
- (void)stopListening
{
    IOHIDQueueUnscheduleFromRunLoop([self queueRef], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDQueueStop([self queueRef]);
    
    IOHIDDeviceUnscheduleFromRunLoop([self hidDeviceRef], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDDeviceClose([self hidDeviceRef], kIOHIDOptionsTypeNone);
}

- (NSString *)identifierName
{
    NSString *idName = NULL;
    if(idName == NULL) idName = [self productName];
    if(idName == NULL) idName = [self manufacturerName];
    if(idName == NULL) idName = [self serialNumber];
    if(idName == NULL) idName = [NSString stringWithFormat:@"%d-%d", [self vendorID], [self productID]];
    return idName;
}

- (NSString *)productName {
    CFStringRef productName = (CFStringRef)IOHIDDeviceGetProperty([self rawDevice], CFSTR(kIOHIDProductKey));
    if(productName == NULL || CFGetTypeID(productName) != CFStringGetTypeID()) {
        return NULL;
    }
    return (NSString*)productName;
}
- (NSString *)manufacturerName {
    CFStringRef manufacturerName = (CFStringRef)IOHIDDeviceGetProperty([self rawDevice], CFSTR(kIOHIDManufacturerKey));
    if(manufacturerName == NULL || CFGetTypeID(manufacturerName) != CFStringGetTypeID()) {
        return NULL;
    }
    return (NSString*)manufacturerName;
}
- (NSString *)serialNumber {
    CFStringRef serialNumber = (CFStringRef)IOHIDDeviceGetProperty([self rawDevice], CFSTR(kIOHIDSerialNumberKey));
    if(serialNumber == NULL || CFGetTypeID(serialNumber) != CFStringGetTypeID()) {
        return NULL;
    }
    return (NSString*)serialNumber;
}


- (int)vendorID
{
    return IOHIDDeviceGetIntProperty([self rawDevice], CFSTR(kIOHIDVendorIDKey));
}
- (int)productID
{
    return IOHIDDeviceGetIntProperty([self rawDevice], CFSTR(kIOHIDProductIDKey));
}


- (NSUInteger)numberOfAxes
{
    return [[self axes] count];
}
- (NSUInteger)numberOfSticks
{
    return ([[self axes] count] / 2);
}
- (NSUInteger)numberOfButtons
{
    return [[self buttons] count];
}
- (NSUInteger)numberOfTriggerButtons
{
    return [[self triggerButtons] count];
}

- (OSXGamepadButton*)triggerButtonAtIndex:(NSUInteger)index
{
    OSXGamepadButton *b = NULL;
    if(index < [[self triggerButtons] count])
    {
        b = [[self triggerButtons] objectAtIndex:index];
    }
    return b;
}

- (OSXGamepadAxis*)axisAtIndex:(NSUInteger)index
{
    OSXGamepadAxis *a = NULL;
    if(index < [[self axes] count])
    {
        a = [[self axes] objectAtIndex:index];
    }
    return a;
}
- (OSXGamepadButton*)buttonAtIndex:(NSUInteger)index
{
    OSXGamepadButton *b = NULL;
    if(index < [[self buttons] count])
    {
        b = [[self buttons] objectAtIndex:index];
    }
    return b;
}
- (NSArray*)watchedElements
{
    NSMutableArray *r = [NSMutableArray array];
    for(OSXGamepadButton *b in [self buttons])
    {
        [r addObject:(id)[b element]];
    }
    for(OSXGamepadAxis *a in [self axes])
    {
        [r addObject:(id)[a element]];
    }
    return [NSArray arrayWithArray:r];
}
- (void)hidValueAvailable:(IOHIDValueRef)value
{
    IOHIDElementRef element = IOHIDValueGetElement(value);
	IOHIDElementCookie cookie = IOHIDElementGetCookie(element);
    
    if(IOHIDValueGetLength(value) > 4) return; // saftey precaution for PS3 cotroller
    CFIndex integerValue = IOHIDValueGetIntegerValue(value);
    
    for(OSXGamepadAxis *a in [self axes])
    {
        if([a cookie] == cookie)
        {
            [a setValue:integerValue];
        }
    }
    
    for(OSXGamepadButton *b in [self buttons])
    {
        if([b cookie] == cookie)
        {
            [b setState:(bool)integerValue];
            break;
        }
    }
    
    for(OSXGamepadButton *b in [self triggerButtons])
    {
        if([b triggerCookie] == cookie)
        {
            [b setStateValue:integerValue];
            break;
        }
    }

}


@end


@interface View : NSOpenGLView <NSWindowDelegate>
{
@public
    CVDisplayLinkRef displayLink;
    NSRecursiveLock* gameLock;

@protected
    Game* _game;
    unsigned int _gestureEvents;    
}
@end


@implementation View

-(void)windowWillClose:(NSNotification*)note 
{
    [gameLock lock];
    _game->exit();
    [gameLock unlock];
    [[NSApplication sharedApplication] terminate:self];
}

- (CVReturn) getFrameForTime:(const CVTimeStamp*)outputTime
{
    NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
    
    [self update];
    
    [pool release];
    
    return kCVReturnSuccess;
}

-(void) update
{       
    [gameLock lock];

    [[self openGLContext] makeCurrentContext];
    CGLLockContext((CGLContextObj)[[self openGLContext] CGLContextObj]);
    if (_game)
    {
        _game->frame();
    }
    CGLFlushDrawable((CGLContextObj)[[self openGLContext] CGLContextObj]);
    CGLUnlockContext((CGLContextObj)[[self openGLContext] CGLContextObj]);  

    [gameLock unlock];
}

static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink, const CVTimeStamp* now, const CVTimeStamp* outputTime, 
                                      CVOptionFlags flagsIn, CVOptionFlags* flagsOut, void* displayLinkContext)
{
    CVReturn result = [(View*)displayLinkContext getFrameForTime:outputTime];
    return result;
}

- (id) initWithFrame: (NSRect) frame
{
    _game = Game::getInstance();
    
    Properties* config = _game->getConfig()->getNamespace("window", true);
    int samples = config ? config->getInt("samples") : 0;
    if (samples < 0)
        samples = 0;
    
    // Note: Keep multisampling attributes at the start of the attribute lists since code below
    // assumes they are array elements 0 through 4.
    NSOpenGLPixelFormatAttribute windowedAttrs[] = 
    {
        NSOpenGLPFAMultisample,
        NSOpenGLPFASampleBuffers, samples ? 1 : 0,
        NSOpenGLPFASamples, samples,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
        0
    };
    NSOpenGLPixelFormatAttribute fullscreenAttrs[] = 
    {
        NSOpenGLPFAMultisample,
        NSOpenGLPFASampleBuffers, samples ? 1 : 0,
        NSOpenGLPFASamples, samples,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAScreenMask, (NSOpenGLPixelFormatAttribute)CGDisplayIDToOpenGLDisplayMask(CGMainDisplayID()),
        NSOpenGLPFAFullScreen,
        NSOpenGLPFAColorSize, 32,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
        0
    };
    NSOpenGLPixelFormatAttribute* attrs = __fullscreen ? fullscreenAttrs : windowedAttrs;
    
    // Try to choose a supported pixel format
    NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf)
    {
        bool valid = false;
        while (!pf && samples > 0)
        {
            samples /= 2;
            attrs[2] = samples ? 1 : 0;
            attrs[4] = samples;
            pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
            if (pf)
            {
                valid = true;
                break;
            }
        }
        
        if (!valid)
        {
            NSLog(@"OpenGL pixel format not supported.");
            GP_ERROR("Failed to create a valid OpenGL pixel format.");
            return nil;
        }
    }
    
    if ((self = [super initWithFrame:frame pixelFormat:[pf autorelease]])) 
    {
        gameLock = [[NSRecursiveLock alloc] init];
        __timeStart = getMachTimeInMilliseconds();
    }
    
    return self;
}

- (void) prepareOpenGL
{
    [super prepareOpenGL];
    
    _game->run();
    
    if (__fullscreen)
    {
        [[self window] setLevel: NSMainMenuWindowLevel+1];
        [[self window] setHidesOnDeactivate:YES]; 
    }
    else
    {
        [[self window] setLevel: NSNormalWindowLevel];
    }
    [[self window] makeKeyAndOrderFront: self];
    [[self window] setTitle: [NSString stringWithUTF8String: __title ? __title : ""]];
    
    // Make all the OpenGL calls to setup rendering and build the necessary rendering objects
    [[self openGLContext] makeCurrentContext];
    // Synchronize buffer swaps with vertical refresh rate
    GLint swapInt = __vsync ? 1 : 0;
    [[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];
    
    // Create a display link capable of being used with all active displays
    CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
    
    // Set the renderer output callback function
    CVDisplayLinkSetOutputCallback(displayLink, &MyDisplayLinkCallback, self);
    
    CGLContextObj cglContext = (CGLContextObj)[[self openGLContext] CGLContextObj];
    CGLPixelFormatObj cglPixelFormat = (CGLPixelFormatObj)[[self pixelFormat] CGLPixelFormatObj];
    CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(displayLink, cglContext, cglPixelFormat);
    
    GLint dim[2] = {__width, __height};
    CGLSetParameter(cglContext, kCGLCPSurfaceBackingSize, dim);
    CGLEnable(cglContext, kCGLCESurfaceBackingSize);
    
    // Activate the display link
    CVDisplayLinkStart(displayLink);
}

- (void) dealloc
{   
    [gameLock lock];
    
    // Release the display link
    CVDisplayLinkStop(displayLink);
    CVDisplayLinkRelease(displayLink);
    _game->exit();
    
    [gameLock unlock];

    [super dealloc];
}

- (void)resumeDisplayRenderer 
{
    [gameLock lock];
    CVDisplayLinkStop(displayLink);
    [gameLock unlock]; 
}

- (void)haltDisplayRenderer 
{
    [gameLock lock];
    CVDisplayLinkStop(displayLink);
    [gameLock unlock];
}

- (void) mouse: (Mouse::MouseEvent) mouseEvent orTouchEvent: (Touch::TouchEvent) touchEvent x: (float) x y: (float) y s: (int) s 
{
    if (!gameplay::Platform::mouseEventInternal(mouseEvent, x, y, s))
    {
        gameplay::Platform::touchEventInternal(touchEvent, x, y, 0);
    }
}

- (void) mouseDown: (NSEvent*) event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    __leftMouseDown = true;
    [self mouse: Mouse::MOUSE_PRESS_LEFT_BUTTON orTouchEvent: Touch::TOUCH_PRESS x: point.x y: __height - point.y s: 0];
}

- (void) mouseUp: (NSEvent*) event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    __leftMouseDown = false;
    [self mouse: Mouse::MOUSE_RELEASE_LEFT_BUTTON orTouchEvent: Touch::TOUCH_RELEASE x: point.x y: __height - point.y s: 0];

}

- (void)mouseMoved:(NSEvent*) event 
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    
    if (__mouseCaptured)
    {
        point.x = [event deltaX];
        point.y = [event deltaY];

        NSWindow* window = __view.window;
        NSRect rect = window.frame;
        CGPoint centerPoint;
        centerPoint.x = rect.origin.x + (rect.size.width / 2);
        centerPoint.y = rect.origin.y + (rect.size.height / 2);
        CGDisplayMoveCursorToPoint(CGDisplayPrimaryDisplay(NULL), centerPoint);
    }
    
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_MOVE, point.x, __height - point.y, 0);
}

- (void) mouseDragged: (NSEvent*) event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    if (__leftMouseDown)
    {
        [self mouse: Mouse::MOUSE_MOVE orTouchEvent: Touch::TOUCH_MOVE x: point.x y: __height - point.y s: 0];
    }
}

- (void) rightMouseDown: (NSEvent*) event
{
    __rightMouseDown = true;
     NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    __lx = point.x;
    __ly = __height - point.y;
    
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_PRESS_RIGHT_BUTTON, point.x, __height - point.y, 0);
}

- (void) rightMouseUp: (NSEvent*) event
{
    __rightMouseDown = false;
    NSPoint point = [event locationInWindow];
    
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_RELEASE_RIGHT_BUTTON, point.x, __height - point.y, 0);
}

- (void) rightMouseDragged: (NSEvent*) event
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    if (__rightMouseDown)
    {
        // Update the pitch and roll by adding the scaled deltas.
        __roll += (float)(point.x - __lx) * ACCELEROMETER_FACTOR_X;
        __pitch -= -(float)(point.y - (__height - __ly)) * ACCELEROMETER_FACTOR_Y;
    
        // Clamp the values to the valid range.
        __roll = max(min(__roll, 90.0f), -90.0f);
        __pitch = max(min(__pitch, 90.0f), -90.0f);
    
        // Update the last X/Y values.
        __lx = point.x;
        __ly = (__height - point.y);
    }
    
    // In right-mouse case, whether __rightMouseDown is true or false
    // this should not matter, mouse move is still occuring
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_MOVE, point.x, __height - point.y, 0);
}

- (void)otherMouseDown: (NSEvent*) event 
{
    __otherMouseDown = true;
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_PRESS_MIDDLE_BUTTON, point.x, __height - point.y, 0);
}

- (void)otherMouseUp: (NSEvent*) event 
{
    __otherMouseDown = false;
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_RELEASE_MIDDLE_BUTTON, point.x, __height - point.y, 0);
}

- (void)otherMouseDragged: (NSEvent*) event 
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_MOVE, point.x, __height - point.y, 0);
}

- (void) mouseEntered: (NSEvent*)event
{
    __hasMouse = true;
}

- (void)scrollWheel: (NSEvent*) event 
{
    NSPoint point = [self convertPoint:[event locationInWindow] fromView:nil];
    gameplay::Platform::mouseEventInternal(Mouse::MOUSE_WHEEL, point.x, __height - point.y, (int)([event deltaY] * 10.0f));
}

- (void) mouseExited: (NSEvent*)event
{
    __leftMouseDown = false;
    __rightMouseDown = false;
    __otherMouseDown = false;
    __hasMouse = false;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

int getKey(unsigned short keyCode, unsigned int modifierFlags)
{
    __shiftDown = (modifierFlags & NSShiftKeyMask);
    switch(keyCode)
    {
        case 0x69:
            return Keyboard::KEY_PRINT;
        case 0x35:
            return Keyboard::KEY_ESCAPE;
        case 0x33:
            return Keyboard::KEY_BACKSPACE;
        case 0x30:
            return Keyboard::KEY_TAB;
        case 0x24:
            return Keyboard::KEY_RETURN;
        case 0x72:
            return Keyboard::KEY_INSERT;
        case 0x73:
            return Keyboard::KEY_HOME;
        case 0x74:
            return Keyboard::KEY_PG_UP;
        case 0x79:
            return Keyboard::KEY_PG_DOWN;
        case 0x75:
            return Keyboard::KEY_DELETE;
        case 0x77:
            return Keyboard::KEY_END;
        case 0x7B:
            return Keyboard::KEY_LEFT_ARROW;
        case 0x7C:
            return Keyboard::KEY_RIGHT_ARROW;
        case 0x7E:
            return Keyboard::KEY_UP_ARROW;
        case 0x7D:
            return Keyboard::KEY_DOWN_ARROW;
        case 0x47:
            return Keyboard::KEY_NUM_LOCK;
        case 0x45:
            return Keyboard::KEY_KP_PLUS;
        case 0x4E:
            return Keyboard::KEY_KP_MINUS;
        case 0x43:
            return Keyboard::KEY_KP_MULTIPLY;
        case 0x4B:
            return Keyboard::KEY_KP_DIVIDE;
        case 0x59:
            return Keyboard::KEY_KP_HOME;
        case 0x5B:
            return Keyboard::KEY_KP_UP;
        case 0x5C:
            return Keyboard::KEY_KP_PG_UP;
        case 0x56:
            return Keyboard::KEY_KP_LEFT;
        case 0x57:
            return Keyboard::KEY_KP_FIVE;
        case 0x58:
            return Keyboard::KEY_KP_RIGHT;
        case 0x53:
            return Keyboard::KEY_KP_END;
        case 0x54:
            return Keyboard::KEY_KP_DOWN;
        case 0x55:
            return Keyboard::KEY_KP_PG_DOWN;
        case 0x52:
            return Keyboard::KEY_KP_INSERT;
        case 0x41:
            return Keyboard::KEY_KP_DELETE;
        case 0x7A:
            return Keyboard::KEY_F1;
        case 0x78:
            return Keyboard::KEY_F2;
        case 0x63:
            return Keyboard::KEY_F3;
        case 0x76:
            return Keyboard::KEY_F4;
        case 0x60:
            return Keyboard::KEY_F5;
        case 0x61:
            return Keyboard::KEY_F6;
        case 0x62:
            return Keyboard::KEY_F7;
        case 0x64:
            return Keyboard::KEY_F8;
        case 0x65:
            return Keyboard::KEY_F9;
        case 0x6D:
            return Keyboard::KEY_F10;
        
        // MACOS reserved:
        // return Keyboard::KEY_F11;
        // return Keyboard::KEY_F12;
        // return Keyboard::KEY_PAUSE;
        // return Keyboard::KEY_SCROLL_LOCK;
            
        case 0x31:
            return Keyboard::KEY_SPACE;
        case 0x1D:
            return __shiftDown ? Keyboard::KEY_RIGHT_PARENTHESIS : Keyboard::KEY_ZERO;
        case 0x12:
            return __shiftDown ? Keyboard::KEY_EXCLAM : Keyboard::KEY_ONE;
        case 0x13:
            return __shiftDown ? Keyboard::KEY_AT : Keyboard::KEY_TWO;
        case 0x14:
            return __shiftDown ? Keyboard::KEY_NUMBER : Keyboard::KEY_THREE;
        case 0x15:
            return __shiftDown ? Keyboard::KEY_DOLLAR : Keyboard::KEY_FOUR;
        case 0x17:
            return __shiftDown ? Keyboard::KEY_PERCENT : Keyboard::KEY_FIVE;
        case 0x16:
            return __shiftDown ? Keyboard::KEY_CIRCUMFLEX : Keyboard::KEY_SIX;
        case 0x1A:
            return __shiftDown ? Keyboard::KEY_AMPERSAND : Keyboard::KEY_SEVEN;
        case 0x1C:
            return __shiftDown ? Keyboard::KEY_ASTERISK : Keyboard::KEY_EIGHT;
        case 0x19:
            return __shiftDown ? Keyboard::KEY_LEFT_PARENTHESIS : Keyboard::KEY_NINE;
        case 0x18:
            return __shiftDown ? Keyboard::KEY_EQUAL : Keyboard::KEY_PLUS;
        case 0x2B:
            return __shiftDown ? Keyboard::KEY_LESS_THAN : Keyboard::KEY_COMMA;
        case 0x1B:
            return __shiftDown ? Keyboard::KEY_UNDERSCORE : Keyboard::KEY_MINUS;
        case 0x2F:
            return __shiftDown ? Keyboard::KEY_GREATER_THAN : Keyboard::KEY_PERIOD;
        case 0x29:
            return __shiftDown ? Keyboard::KEY_COLON : Keyboard::KEY_SEMICOLON;
        case 0x2C:
            return __shiftDown ? Keyboard::KEY_QUESTION : Keyboard::KEY_SLASH;
        case 0x32:
            return __shiftDown ? Keyboard::KEY_GRAVE : Keyboard::KEY_TILDE;
        case 0x21:
            return __shiftDown ? Keyboard::KEY_LEFT_BRACE : Keyboard::KEY_LEFT_BRACKET;
        case 0x2A:
            return __shiftDown ? Keyboard::KEY_BAR : Keyboard::KEY_BACK_SLASH;
        case 0x1E:
            return __shiftDown ? Keyboard::KEY_RIGHT_BRACE : Keyboard::KEY_RIGHT_BRACKET;
        case 0x27:
            return __shiftDown ? Keyboard::KEY_QUOTE : Keyboard::KEY_APOSTROPHE;
            
        case 0x00:
             return __shiftDown ? Keyboard::KEY_CAPITAL_A : Keyboard::KEY_A;
        case 0x0B:
             return __shiftDown ? Keyboard::KEY_CAPITAL_B : Keyboard::KEY_B;
        case 0x08:
             return __shiftDown ? Keyboard::KEY_CAPITAL_C : Keyboard::KEY_C;
        case 0x02:
             return __shiftDown ? Keyboard::KEY_CAPITAL_D : Keyboard::KEY_D;
        case 0x0E:
             return __shiftDown ? Keyboard::KEY_CAPITAL_E : Keyboard::KEY_E;
        case 0x03:
             return __shiftDown ? Keyboard::KEY_CAPITAL_F : Keyboard::KEY_F;
        case 0x05:
             return __shiftDown ? Keyboard::KEY_CAPITAL_G : Keyboard::KEY_G;
        case 0x04:
             return __shiftDown ? Keyboard::KEY_CAPITAL_H : Keyboard::KEY_H;
        case 0x22:
             return __shiftDown ? Keyboard::KEY_CAPITAL_I : Keyboard::KEY_I;
        case 0x26:
             return __shiftDown ? Keyboard::KEY_CAPITAL_J : Keyboard::KEY_J;
        case 0x28:
             return __shiftDown ? Keyboard::KEY_CAPITAL_K : Keyboard::KEY_K;
        case 0x25:
             return __shiftDown ? Keyboard::KEY_CAPITAL_L : Keyboard::KEY_L;
        case 0x2E:
             return __shiftDown ? Keyboard::KEY_CAPITAL_M : Keyboard::KEY_M;
        case 0x2D:
             return __shiftDown ? Keyboard::KEY_CAPITAL_N : Keyboard::KEY_N;
        case 0x1F:
             return __shiftDown ? Keyboard::KEY_CAPITAL_O : Keyboard::KEY_O;
        case 0x23:
             return __shiftDown ? Keyboard::KEY_CAPITAL_P : Keyboard::KEY_P;
        case 0x0C:
             return __shiftDown ? Keyboard::KEY_CAPITAL_Q : Keyboard::KEY_Q;
        case 0x0F:
             return __shiftDown ? Keyboard::KEY_CAPITAL_R : Keyboard::KEY_R;
        case 0x01:
             return __shiftDown ? Keyboard::KEY_CAPITAL_S : Keyboard::KEY_S;
        case 0x11:
             return __shiftDown ? Keyboard::KEY_CAPITAL_T : Keyboard::KEY_T;
        case 0x20:
             return __shiftDown ? Keyboard::KEY_CAPITAL_U : Keyboard::KEY_U;
        case 0x09:
             return __shiftDown ? Keyboard::KEY_CAPITAL_V : Keyboard::KEY_V;
        case 0x0D:
             return __shiftDown ? Keyboard::KEY_CAPITAL_W : Keyboard::KEY_W;
        case 0x07:
             return __shiftDown ? Keyboard::KEY_CAPITAL_X : Keyboard::KEY_X;
        case 0x10:
            return __shiftDown ? Keyboard::KEY_CAPITAL_Y : Keyboard::KEY_Y;
        case 0x06:
            return __shiftDown ? Keyboard::KEY_CAPITAL_Z : Keyboard::KEY_Z;

        default:
            return Keyboard::KEY_NONE;
    }
}

- (void)flagsChanged: (NSEvent*)event
{
    unsigned int keyCode = [event keyCode];
    unsigned int flags = [event modifierFlags];
    switch (keyCode) 
    {
        case 0x39:
            gameplay::Platform::keyEventInternal((flags & NSAlphaShiftKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_CAPS_LOCK);
            break;
        case 0x38:
            gameplay::Platform::keyEventInternal((flags & NSShiftKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_SHIFT);
            break;
        case 0x3C:
            gameplay::Platform::keyEventInternal((flags & NSShiftKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_SHIFT);
            break;
        case 0x3A:
            gameplay::Platform::keyEventInternal((flags & NSAlternateKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_ALT);
            break;
        case 0x3D:
            gameplay::Platform::keyEventInternal((flags & NSAlternateKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_ALT);
            break;
        case 0x3B:
            gameplay::Platform::keyEventInternal((flags & NSControlKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_CTRL);
            break;
        case 0x3E:
            gameplay::Platform::keyEventInternal((flags & NSControlKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_CTRL);
            break;
        case 0x37:
            gameplay::Platform::keyEventInternal((flags & NSCommandKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_HYPER);
            break;
        case 0x36:
            gameplay::Platform::keyEventInternal((flags & NSCommandKeyMask) ? Keyboard::KEY_PRESS : Keyboard::KEY_RELEASE, Keyboard::KEY_HYPER);
            break;
    }
}

- (void) keyDown: (NSEvent*) event
{
    if ([event isARepeat] == NO)
    {
        gameplay::Platform::keyEventInternal(Keyboard::KEY_PRESS, getKey([event keyCode], [event modifierFlags]));
    }
}

- (void) keyUp: (NSEvent*) event
{    
    gameplay::Platform::keyEventInternal(Keyboard::KEY_RELEASE, getKey([event keyCode], [event modifierFlags]));
}

// Gesture support for Mac OS X Trackpads
- (bool)isGestureRegistered: (Gesture::GestureEvent) evt
{
    return ((_gestureEvents & evt) == evt);
}

- (void)registerGesture: (Gesture::GestureEvent) evt
{
    _gestureEvents |= evt;
}

- (void)unregisterGesture: (Gesture::GestureEvent) evt
{
    _gestureEvents &= (~evt);
}

- (void)magnifyWithEvent:(NSEvent *)event
{
    if([self isGestureRegistered:Gesture::GESTURE_PINCH] == false) return;
    
    NSSet *touches = [event touchesMatchingPhase:NSTouchPhaseAny  inView:nil];
    // Approximate the center by adding and averageing for now
    // Note this is centroid on the physical device be used for touching, not the display
    float xavg = 0.0f;
    float yavg = 0.0f;
    for(NSTouch *t in touches) {
        xavg += [t normalizedPosition].x;
        yavg += [t normalizedPosition].y;
    }
    xavg /= [touches count];
    yavg /= [touches count];
    
    [gameLock lock];
    _game->gesturePinchEvent((int)xavg, (int)yavg, [event magnification]);
    [gameLock unlock];
}


@end

@interface FullscreenWindow : NSWindow
{ 
}
@end

@implementation FullscreenWindow
- (BOOL)canBecomeKeyWindow
{
    return YES;
}
@end


namespace gameplay
{

extern void print(const char* format, ...)
{
    GP_ASSERT(format);
    va_list argptr;
    va_start(argptr, format);
    vfprintf(stderr, format, argptr);
    va_end(argptr);
}
    
Platform::Platform(Game* game)
: _game(game)
{
    __activeGamepads = [[NSMutableDictionary alloc] init];
    __gamepads = [[NSMutableArray alloc] init];
    __hidManagerRef = IOHIDManagerCreate(CFAllocatorGetDefault(), kIOHIDOptionsTypeNone);
    IOHIDManagerRegisterDeviceMatchingCallback(__hidManagerRef, hidDeviceDiscoveredCallback, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(__hidManagerRef, hidDeviceRemovalCallback, NULL);
    
    CFDictionaryRef matchingCFDictRef = IOHIDCreateDeviceMatchingDictionary(kHIDPage_GenericDesktop, kHIDUsage_GD_Joystick);
    if (matchingCFDictRef) IOHIDManagerSetDeviceMatching(__hidManagerRef, matchingCFDictRef);
    CFRelease(matchingCFDictRef);
    
    IOHIDManagerScheduleWithRunLoop(__hidManagerRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOReturn kr = IOHIDManagerOpen(__hidManagerRef, kIOHIDOptionsTypeNone);
    assert(kr == 0);
}

    
Platform::~Platform()
{
    IOHIDManagerUnscheduleFromRunLoop(__hidManagerRef, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
    IOHIDManagerClose(__hidManagerRef, kIOHIDOptionsTypeNone);
    
    CFRelease(__hidManagerRef);
    __hidManagerRef = NULL;
    [__activeGamepads release];
    __activeGamepads = NULL;
    [__gamepads release];
    __gamepads = NULL;
}

    
Platform* Platform::create(Game* game, void* attachToWindow)
{
    __attachToWindow = attachToWindow;
    Platform* platform = new Platform(game);
    
    return platform;
}

int Platform::enterMessagePump()
{
    NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
    NSString* path = [bundlePath stringByAppendingString:@"/Contents/Resources/"];
    FileSystem::setResourcePath([path cStringUsingEncoding:NSASCIIStringEncoding]);
    
    // Read window settings from config.
    if (_game->getConfig())
    {
        Properties* config = _game->getConfig()->getNamespace("window", true);
        if (config)
        {
            // Read window title.
            __title = const_cast<char *>(config->getString("title"));

            // Read window size.
            int width = config->getInt("width");
            if (width != 0)
                __width = width;
            int height = config->getInt("height");
            if (height != 0)
                __height = height;

            // Read fullscreen state.
            __fullscreen = config->getBool("fullscreen");
        }
    }

    // Set the scale factors for the mouse movement used to simulate the accelerometer.
    ACCELEROMETER_FACTOR_X = 90.0f / __width;
    ACCELEROMETER_FACTOR_Y = 90.0f / __height;

    NSAutoreleasePool* pool = [NSAutoreleasePool new];
    NSApplication* app = [NSApplication sharedApplication];
    NSRect screenBounds = [[NSScreen mainScreen] frame];
    NSRect viewBounds = NSMakeRect(0, 0, __width, __height);
    
    __view = [[View alloc] initWithFrame:viewBounds];
    if (__view == NULL)
    {
        GP_ERROR("Failed to create view: exiting.");
        return EXIT_FAILURE;
    }
    
    NSRect centered = NSMakeRect(NSMidX(screenBounds) - NSMidX(viewBounds),
                                 NSMidY(screenBounds) - NSMidY(viewBounds),
                                 viewBounds.size.width, 
                                 viewBounds.size.height);
    
    NSWindow* window = NULL;
    if (__fullscreen)
    {
        window = [[FullscreenWindow alloc]
                   initWithContentRect:screenBounds
                   styleMask:NSBorderlessWindowMask
                   backing:NSBackingStoreBuffered
                   defer:NO];
    }
    else
    {
        window = [[NSWindow alloc]
                   initWithContentRect:centered
                   styleMask:NSTitledWindowMask | NSClosableWindowMask
                   backing:NSBackingStoreBuffered
                   defer:NO];
    }
    
    [window setAcceptsMouseMovedEvents:YES];
    [window setContentView:__view];
    [window setDelegate:__view];
    [__view release];
    
    [app run];
    
    [pool release];
    return EXIT_SUCCESS;
}

void Platform::signalShutdown() 
{
    [__view haltDisplayRenderer];

    // Don't perform terminate right away, enqueue to give game object
    // a chance to cleanup
    NSApplication* app = [NSApplication sharedApplication];
    [app performSelectorOnMainThread:@selector(terminate:) withObject:nil waitUntilDone:NO];
}

bool Platform::canExit()
{
    return true;
}
    
unsigned int Platform::getDisplayWidth()
{
    return __width;
}

unsigned int Platform::getDisplayHeight()
{
    return __height;
}

double Platform::getAbsoluteTime()
{
    __timeAbsolute = getMachTimeInMilliseconds();
    return __timeAbsolute;
}

void Platform::setAbsoluteTime(double time)
{
    __timeAbsolute = time;
}

bool Platform::isVsync()
{
    return __vsync;
}

void Platform::setVsync(bool enable)
{
    __vsync = enable;
    GLint swapInt = enable ? 1 : 0;
    [[__view openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];
}

void Platform::swapBuffers()
{
    if (__view)
        CGLFlushDrawable((CGLContextObj)[[__view openGLContext] CGLContextObj]);
}

void Platform::sleep(long ms)
{
    usleep(ms * 1000);
}

void Platform::setMultiTouch(bool enabled)
{
}
    
bool Platform::isMultiTouch()
{
    return true;
}
    
void Platform::getAccelerometerValues(float* pitch, float* roll)
{
    GP_ASSERT(pitch);
    GP_ASSERT(roll);

    *pitch = __pitch;
    *roll = __roll;
}

bool Platform::hasMouse()
{
    return true;
}

void Platform::setMouseCaptured(bool captured)
{
    if (captured != __mouseCaptured)
    {
        if (captured)
        {
            [NSCursor hide];
        }
        else
        {   
            [NSCursor unhide];
        }
        NSWindow* window = __view.window;
        NSRect rect = window.frame;
        CGPoint centerPoint;
        centerPoint.x = rect.origin.x + (rect.size.width / 2);
        centerPoint.y = rect.origin.y + (rect.size.height / 2);
        CGDisplayMoveCursorToPoint(CGDisplayPrimaryDisplay(NULL), centerPoint);
        __mouseCaptured = captured;
    }
}

bool Platform::isMouseCaptured()
{
    return __mouseCaptured;
}

void Platform::setCursorVisible(bool visible)
{
    if (visible != __cursorVisible)
    {
        if (visible)
        {
             [NSCursor unhide];
        }
        else 
        {
             [NSCursor hide];
        }
        __cursorVisible = visible;
    }
}

bool Platform::isCursorVisible()
{
    return __cursorVisible;
}

void Platform::displayKeyboard(bool display)
{
    // Do nothing.
}

void Platform::touchEventInternal(Touch::TouchEvent evt, int x, int y, unsigned int contactIndex)
{
    [__view->gameLock lock];
    if (!Form::touchEventInternal(evt, x, y, contactIndex))
    {
        Game::getInstance()->touchEvent(evt, x, y, contactIndex);
        Game::getInstance()->getScriptController()->touchEvent(evt, x, y, contactIndex);
    }
    [__view->gameLock unlock];
}
    
void Platform::keyEventInternal(Keyboard::KeyEvent evt, int key)
{
    [__view->gameLock lock];
    if (!Form::keyEventInternal(evt, key))
    {
        Game::getInstance()->keyEvent(evt, key);
        Game::getInstance()->getScriptController()->keyEvent(evt, key);
    }
    [__view->gameLock unlock];
}

bool Platform::mouseEventInternal(Mouse::MouseEvent evt, int x, int y, int wheelDelta)
{
    [__view->gameLock lock];
    
    bool result;
    if (Form::mouseEventInternal(evt, x, y, wheelDelta))
    {
        result = true;
    }
    else if (Game::getInstance()->mouseEvent(evt, x, y, wheelDelta))
    {
        result = true;
    }
    else
    {
        result = Game::getInstance()->getScriptController()->mouseEvent(evt, x, y, wheelDelta);
    }
    
    [__view->gameLock unlock];
    
    return result;
}

bool Platform::isGestureSupported(Gesture::GestureEvent evt)
{
    // Swipe unsupported as it is considered moving mouse cursor
    // Two fingers is scrolling
    // Three fingers is swipe, but is not always enabled on users system
    // Tap not supported as it is considered a mouse click/button click
    // on some systems making it difficult to differentiate 
    switch(evt)
    {
        case Gesture::GESTURE_PINCH:
            return true;
        default:
            break;
    }
    return false;
}

void Platform::registerGesture(Gesture::GestureEvent evt)
{
    [__view registerGesture:evt];   
}

void Platform::unregisterGesture(Gesture::GestureEvent evt)
{
    [__view unregisterGesture:evt];        
}
  
bool Platform::isGestureRegistered(Gesture::GestureEvent evt)
{
     return [__view isGestureRegistered:evt];
}

unsigned int Platform::getGamepadsConnected()
{
    Game* game = Game::getInstance();
    
    if(game->isInitialized())
    {
        // Locate any newly connected devices
        for(OSXGamepad* gamepad in __gamepads)
        {
            NSNumber* locationID = [gamepad locationID];
            if([__activeGamepads objectForKey:locationID] == NULL)
            {
                unsigned int handle = game->createGamepad([[gamepad identifierName] cStringUsingEncoding:NSASCIIStringEncoding],
                                                          [locationID unsignedIntValue],
                                                          [gamepad numberOfButtons],
                                                          [gamepad numberOfSticks],
                                                          [gamepad numberOfTriggerButtons]);
                NSNumber* handleObj = [NSNumber numberWithUnsignedInt:handle];
                [__activeGamepads setObject:handleObj forKey:locationID];
                game->gamepadEvent(Gamepad::CONNECTED_EVENT, game->getGamepad(handle));
            }
        }
        
        // Detect any disconnected gamepads
        NSMutableArray* deadGamepads = [NSMutableArray array];
        for(NSNumber* locationID in __activeGamepads)
        {
            OSXGamepad* gamepad = gamepadForLocationID(locationID);
            if(gamepad == NULL)
            {
                NSNumber* gameHandle = [__activeGamepads objectForKey:locationID];
                game->gamepadEvent(Gamepad::DISCONNECTED_EVENT, game->getGamepad([gameHandle unsignedIntValue]));
                [deadGamepads addObject:locationID];
            }
        }
        [__activeGamepads removeObjectsForKeys:deadGamepads];
    }
    return [__gamepads count];
}

bool Platform::isGamepadConnected(unsigned int gamepadHandle)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    return (gamepad != NULL);
}

const char* Platform::getGamepadId(unsigned int gamepadHandle)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    if(gamepad)
    {
        return [[gamepad productName] cStringUsingEncoding:NSASCIIStringEncoding];
    }
    return NULL;
}

unsigned int Platform::getGamepadButtonCount(unsigned int gamepadHandle)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    if(gamepad)
    {
        return [gamepad numberOfButtons];
    }
    return 0;
}

bool Platform::getGamepadButtonState(unsigned int gamepadHandle, unsigned int buttonIndex)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    OSXGamepadButton* button = [gamepad buttonAtIndex:buttonIndex];
    if(button)
    {
        return [button state];
    }
    return false;
}

unsigned int Platform::getGamepadJoystickCount(unsigned int gamepadHandle)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    if(gamepad)
    {
        return [gamepad numberOfSticks];
    }
    return 0;
}

bool Platform::isGamepadJoystickActive(unsigned int gamepadHandle, unsigned int joystickIndex)
{
    return true;
}

float Platform::getGamepadJoystickAxisX(unsigned int gamepadHandle, unsigned int joystickIndex)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    OSXGamepadAxis* xAxis = [gamepad axisAtIndex:(joystickIndex*2)];
    return [xAxis calibratedValue];
}

float Platform::getGamepadJoystickAxisY(unsigned int gamepadHandle, unsigned int joystickIndex)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    OSXGamepadAxis* yAxis = [gamepad axisAtIndex:((joystickIndex*2)+1)];
    return [yAxis calibratedValue];
}

void Platform::getGamepadJoystickAxisValues(unsigned int gamepadHandle, unsigned int joystickIndex, Vector2* outValue)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    OSXGamepadAxis* xAxis = [gamepad axisAtIndex:(joystickIndex*2)];
    OSXGamepadAxis* yAxis = [gamepad axisAtIndex:((joystickIndex*2)+1)];
    if(outValue)
    {
        outValue->x = [xAxis calibratedValue];
        outValue->y = [yAxis calibratedValue];
    }
}

unsigned int Platform::getGamepadTriggerCount(unsigned int gamepadHandle)
{
    OSXGamepad *gamepad = gamepadForLocationIDValue(gamepadHandle);
    return [gamepad numberOfTriggerButtons];
}

float Platform::getGamepadTriggerValue(unsigned int gamepadHandle, unsigned int triggerIndex)
{
    OSXGamepad* gamepad = gamepadForLocationIDValue(gamepadHandle);
    OSXGamepadButton* button = [gamepad triggerButtonAtIndex:triggerIndex];
    if(button)
    {
        return [button stateValue];
    }
    return 0.0f;
}

}


OSXGamepad* gamepadForLocationID(NSNumber* locationID)
{
    OSXGamepad* fgamepad = NULL;
    for(OSXGamepad* gamepad in __gamepads)
    {
        if([[gamepad locationID] isEqual:locationID])
        {
            fgamepad = gamepad;
            break;
        }
    }
    return fgamepad;
}

OSXGamepad* gamepadForLocationIDValue(unsigned int locationIDValue)
{
    return gamepadForLocationID([NSNumber numberWithUnsignedInt:locationIDValue]);
}

OSXGamepad* gamepadForGameHandle(int gameHandle)
{
    OSXGamepad* gamepad = NULL;
    for(NSNumber* locationID in __activeGamepads)
    {
        NSNumber* handleID = [__activeGamepads objectForKey:locationID];
        if([handleID integerValue] == gameHandle)
        {
            gamepad = gamepadForLocationID(locationID);
            break;
        }
    }
    return gamepad;
}

CFMutableDictionaryRef IOHIDCreateDeviceMatchingDictionary(UInt32 inUsagePage, UInt32 inUsage) 
{
    // create a dictionary to add usage page/usages to
    CFMutableDictionaryRef result = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (result) {
        if (inUsagePage) 
        {
            // Add key for device type to refine the matching dictionary.
            CFNumberRef pageCFNumberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &inUsagePage);
            if (pageCFNumberRef) 
            {
                CFDictionarySetValue(result, CFSTR( kIOHIDDeviceUsagePageKey ), pageCFNumberRef);
                CFRelease(pageCFNumberRef);
                
                // note: the usage is only valid if the usage page is also defined
                if (inUsage) 
                {
                    CFNumberRef usageCFNumberRef = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &inUsage);
                    if (usageCFNumberRef) 
                    {
                        CFDictionarySetValue(result, CFSTR(kIOHIDDeviceUsageKey), usageCFNumberRef);
                        CFRelease(usageCFNumberRef);
                    } 
                    else 
                    {
                        fprintf(stderr, "%s: CFNumberCreate( usage ) failed.", __PRETTY_FUNCTION__);
                    }
                }
            } 
            else 
            {
                fprintf( stderr, "%s: CFNumberCreate( usage page ) failed.", __PRETTY_FUNCTION__);
            }
        }
    } 
    else 
    {
        fprintf( stderr, "%s: CFDictionaryCreateMutable failed.", __PRETTY_FUNCTION__);
    }
    return result;
}

CFStringRef IOHIDDeviceGetStringProperty(IOHIDDeviceRef deviceRef, CFStringRef key) 
{
	CFTypeRef typeRef = IOHIDDeviceGetProperty(deviceRef, key);
	if (typeRef == NULL || CFGetTypeID(typeRef) != CFNumberGetTypeID()) 
    {
		return NULL;
	}
    return (CFStringRef)typeRef;
}

int IOHIDDeviceGetIntProperty(IOHIDDeviceRef deviceRef, CFStringRef key) 
{
	CFTypeRef typeRef = IOHIDDeviceGetProperty(deviceRef, key);
	if (typeRef == NULL || CFGetTypeID(typeRef) != CFNumberGetTypeID()) 
    {
		return 0;
	}
    
    int value;
	CFNumberGetValue((CFNumberRef) typeRef, kCFNumberSInt32Type, &value);
	return value;
}

static void hidDeviceDiscoveredCallback(void* inContext, IOReturn inResult, void* inSender, IOHIDDeviceRef inIOHIDDeviceRef) 
{
    CFNumberRef locID = (CFNumberRef)IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    if(locID)
    {
        OSXGamepad* gamepad = [[OSXGamepad alloc] initWithDevice:inIOHIDDeviceRef];
        [__gamepads addObject:gamepad];
    }
    
}

static void hidDeviceRemovalCallback(void* inContext, IOReturn inResult, void* inSender, IOHIDDeviceRef inIOHIDDeviceRef) 
{
    int removeIndex = -1;
    NSNumber *locID = (NSNumber*)IOHIDDeviceGetProperty(inIOHIDDeviceRef, CFSTR(kIOHIDLocationIDKey));
    if(locID)
    {
        for(int i = 0; i < [__gamepads count]; i++)
        {
            OSXGamepad* gamepad = [__gamepads objectAtIndex:i];
            if([[gamepad locationID] isEqual:locID])
            {
                removeIndex = i;
                break;
            }
        }
    }
    if(removeIndex >= 0)
    {
        [__gamepads removeObjectAtIndex:removeIndex];
    }
}

static void hidDeviceValueAvailableCallback(void* inContext, IOReturn inResult,  void* inSender)
{
    OSXGamepad* d = (OSXGamepad*)inContext;
    do
    {
        IOHIDValueRef valueRef = IOHIDQueueCopyNextValueWithTimeout( ( IOHIDQueueRef ) inSender, 0. );
        if (!valueRef) break;
        [d hidValueAvailable:valueRef];
        CFRelease(valueRef); // Don't forget to release our HID value reference
    } while (1);
}
#endif
