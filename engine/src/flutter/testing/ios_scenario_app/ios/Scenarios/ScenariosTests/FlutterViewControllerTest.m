// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Flutter/Flutter.h>
#import <XCTest/XCTest.h>

#import "SceneDelegate.h"

FLUTTER_ASSERT_ARC

@interface FlutterViewControllerTest : XCTestCase
@property(nonatomic, strong) FlutterViewController* flutterViewController;
@end

@implementation FlutterViewControllerTest

- (void)setUp {
  [super setUp];
  self.continueAfterFailure = NO;
}

- (void)tearDown {
  if (self.flutterViewController) {
    XCTestExpectation* vcDismissed = [self expectationWithDescription:@"dismiss"];
    [self.flutterViewController dismissViewControllerAnimated:NO
                                                   completion:^{
                                                     [vcDismissed fulfill];
                                                   }];
    [self waitForExpectationsWithTimeout:10.0 handler:nil];
  }
  [super tearDown];
}

- (void)testFirstFrameCallback {
  XCTestExpectation* firstFrameRendered = [self expectationWithDescription:@"firstFrameRendered"];

  FlutterEngine* engine = [[FlutterEngine alloc] initWithName:@"test" project:nil];
  [engine runWithEntrypoint:nil];
  self.flutterViewController = [[FlutterViewController alloc] initWithEngine:engine
                                                                     nibName:nil
                                                                      bundle:nil];

  XCTAssertFalse(self.flutterViewController.isDisplayingFlutterUI);

  XCTestExpectation* displayingFlutterUIExpectation =
      [self keyValueObservingExpectationForObject:self.flutterViewController
                                          keyPath:@"displayingFlutterUI"
                                    expectedValue:@YES];
  displayingFlutterUIExpectation.assertForOverFulfill = YES;

  [self.flutterViewController setFlutterViewDidRenderCallback:^{
    [firstFrameRendered fulfill];
  }];

  UIWindow* window = SceneDelegate.mainWindowOfFirstConnectedScene;
  XCTAssertNotNil(window, @"The host app must have a connected scene for test");
  UIViewController* rootVC = window.rootViewController;
  [rootVC presentViewController:self.flutterViewController animated:NO completion:nil];

  [self waitForExpectationsWithTimeout:30.0 handler:nil];
}

- (void)testDrawLayer {
  XCTestExpectation* firstFrameRendered = [self expectationWithDescription:@"firstFrameRendered"];
  XCTestExpectation* imageRendered = [self expectationWithDescription:@"imageRendered"];

  FlutterEngine* engine = [[FlutterEngine alloc] initWithName:@"test" project:nil];
  [engine runWithEntrypoint:nil];
  [engine.binaryMessenger
      setMessageHandlerOnChannel:@"waiting_for_status"
            binaryMessageHandler:^(NSData* _Nullable message, FlutterBinaryReply _Nonnull reply) {
              FlutterMethodChannel* channel = [FlutterMethodChannel
                  methodChannelWithName:@"driver"
                        binaryMessenger:engine.binaryMessenger
                                  codec:[FlutterJSONMethodCodec sharedInstance]];
              [channel invokeMethod:@"set_scenario" arguments:@{@"name" : @"solid_blue"}];
            }];

  self.flutterViewController = [[FlutterViewController alloc] initWithEngine:engine
                                                                     nibName:nil
                                                                      bundle:nil];

  XCTAssertFalse(self.flutterViewController.isDisplayingFlutterUI);

  [self.flutterViewController setFlutterViewDidRenderCallback:^{
    [firstFrameRendered fulfill];
  }];

  UIWindow* window = SceneDelegate.mainWindowOfFirstConnectedScene;
  XCTAssertNotNil(window, @"The host app must have a connected scene for test");
  UIViewController* rootVC = window.rootViewController;
  [rootVC presentViewController:self.flutterViewController animated:NO completion:nil];

  CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    size_t width = 300u;
    CGContextRef context =
        CGBitmapContextCreate(nil, width, width, 8, 4 * width, color_space,
                              kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    [window.layer renderInContext:context];
    uint32_t* image_data = (uint32_t*)CGBitmapContextGetData(context);
    if (image_data[20] == 0xFF0000FF) {
      [imageRendered fulfill];
      return;
    }
    CGContextRelease(context);
  });

  [self waitForExpectationsWithTimeout:30.0 handler:nil];

  CGColorSpaceRelease(color_space);
}

@end

#pragma mark - Hardware keyboard UIKit fakes

@interface KeyboardAnswerTestKey : UIKey
@end

@implementation KeyboardAnswerTestKey
- (UIKeyboardHIDUsage)keyCode {
  return UIKeyboardHIDUsageKeyboardA;
}
- (UIKeyModifierFlags)modifierFlags {
  return 0;
}
- (NSString*)characters {
  return @"a";
}
- (NSString*)charactersIgnoringModifiers {
  return @"a";
}
@end

@interface KeyboardAnswerTestPress : UIPress
@end

@implementation KeyboardAnswerTestPress {
  UIKey* _testKey;
}
- (instancetype)init {
  self = [super init];
  if (self) {
    _testKey = [[KeyboardAnswerTestKey alloc] init];
  }
  return self;
}
- (UIPressPhase)phase {
  return UIPressPhaseBegan;
}
- (UIKey*)key {
  return _testKey;
}
@end

@interface KeyboardAnswerTestPressesEvent : UIPressesEvent
@end

@implementation KeyboardAnswerTestPressesEvent
- (UIEventType)type {
  return UIEventTypePresses;
}
- (NSTimeInterval)timestamp {
  return 1.0;
}
@end

static const NSTimeInterval kKeyPressWatchdogSeconds = 3.0;

// Creates a timer that runs |block| after |seconds| in every mode of the main run loop.
//
// FlutterKeyboardManager waits in a private mode, so this lets the timer fire inside the wait
// without depending on the name of the mode.
//
// The caller must invalidate and release the timer.
static CFRunLoopTimerRef CreateTimerInAllMainRunLoopModes(NSTimeInterval seconds,
                                                          void (^block)(void)) {
  CFRunLoopTimerRef timer =
      CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent() + seconds, 0,
                                      0, 0, ^(CFRunLoopTimerRef firedTimer) {
                                        block();
                                      });
  NSArray<NSString*>* modes = CFBridgingRelease(CFRunLoopCopyAllModes(CFRunLoopGetMain()));
  for (NSString* mode in modes) {
    CFRunLoopAddTimer(CFRunLoopGetMain(), timer, (__bridge CFStringRef)mode);
  }
  return timer;
}

// Sends a hardware key press to a FlutterViewController whose Dart side answers both key channels.
//
// FlutterKeyboardManager blocks the main thread in a nested run loop until the framework response
// has been received by both primary responders.
//
// Each answer arrives as a task posted to the platform task runner. The answer on flutter/keyevent
// is produced from a microtask, to emulate framework behavior. The press only completes if both
// kinds of task run inside the nested run loop.
@interface HardwareKeyboardAnswerTest : XCTestCase
@end

@implementation HardwareKeyboardAnswerTest

- (void)testKeyPressCompletesWhenKeyEventAnswerIsSynchronous {
  [self verifyKeyPressCompletesWithScenario:@"key_event_reply_sync"];
}

- (void)testKeyPressCompletesWhenKeyEventAnswerComesFromMicrotask {
  [self verifyKeyPressCompletesWithScenario:@"key_event_reply_microtask"];
}

- (void)verifyKeyPressCompletesWithScenario:(NSString*)scenario {
  FlutterEngine* engine = [[FlutterEngine alloc] initWithName:@"keyboard_answer" project:nil];
  FlutterViewController* viewController = [self viewControllerForEngine:engine scenario:scenario];

  // If the responses never arrive, stop the innermost run loop (the keyboard manager's
  // wait), so the test fails instead of hanging.
  __block BOOL watchdogFired = NO;
  CFRunLoopTimerRef watchdog = CreateTimerInAllMainRunLoopModes(kKeyPressWatchdogSeconds, ^{
    watchdogFired = YES;
    CFRunLoopStop(CFRunLoopGetCurrent());
  });
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [viewController pressesBegan:[NSSet setWithObject:[[KeyboardAnswerTestPress alloc] init]]
                     withEvent:[[KeyboardAnswerTestPressesEvent alloc] init]];
  CFTimeInterval blocked = CFAbsoluteTimeGetCurrent() - start;
  CFRunLoopTimerInvalidate(watchdog);
  CFRelease(watchdog);

  // Deliver any late answers inside a run loop that this test controls, then shut down.
  NSDate* deadline = [NSDate dateWithTimeIntervalSinceNow:0.5];
  while (deadline.timeIntervalSinceNow > 0) {
    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode beforeDate:deadline];
  }
  [engine destroyContext];

  NSLog(@"KEYBOARD_ANSWER scenario=%@ watchdogFired=%d blocked=%.3fs", scenario, watchdogFired,
        blocked);
  XCTAssertFalse(watchdogFired,
                 @"pressesBegan:withEvent: was still waiting for the framework's answers after "
                 @"%.0f seconds.",
                 kKeyPressWatchdogSeconds);
}

// Runs |engine| with |scenario| and returns a view controller whose key responders are
// registered, once the scenario has installed its key channel handlers.
- (FlutterViewController*)viewControllerForEngine:(FlutterEngine*)engine
                                         scenario:(NSString*)scenario {
  XCTAssertTrue([engine runWithEntrypoint:nil]);
  XCTestExpectation* ready = [self expectationWithDescription:@"key handlers installed"];
  __weak FlutterEngine* weakEngine = engine;
  [engine.binaryMessenger
      setMessageHandlerOnChannel:@"waiting_for_status"
            binaryMessageHandler:^(NSData* message, FlutterBinaryReply reply) {
              FlutterMethodChannel* driver = [FlutterMethodChannel
                  methodChannelWithName:@"driver"
                        binaryMessenger:weakEngine.binaryMessenger
                                  codec:[FlutterJSONMethodCodec sharedInstance]];
              [driver invokeMethod:@"set_scenario" arguments:@{@"name" : scenario}];
            }];
  [engine.binaryMessenger setMessageHandlerOnChannel:@"key_event_reply_ready"
                                binaryMessageHandler:^(NSData* message, FlutterBinaryReply reply) {
                                  [ready fulfill];
                                }];
  FlutterViewController* viewController = [[FlutterViewController alloc] initWithEngine:engine
                                                                                nibName:nil
                                                                                 bundle:nil];
  // viewDidLoad registers the key responders.
  [viewController loadViewIfNeeded];
  [self waitForExpectations:@[ ready ] timeout:30.0];
  return viewController;
}

@end
