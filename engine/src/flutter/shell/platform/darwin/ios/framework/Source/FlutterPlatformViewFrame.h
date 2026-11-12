// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_DARWIN_IOS_FRAMEWORK_SOURCE_FLUTTERPLATFORMVIEWFRAME_H_
#define FLUTTER_SHELL_PLATFORM_DARWIN_IOS_FRAMEWORK_SOURCE_FLUTTERPLATFORMVIEWFRAME_H_

#import <UIKit/UIKit.h>

#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformViewLayer.h"

NS_ASSUME_NONNULL_BEGIN

/// The views that display the Flutter content painted above a platform view.
@interface FlutterPlatformViewOverlay : NSObject

/// The view that the Flutter content is rendered to.
@property(nonatomic, readonly) UIView* view;

/// The superview of `view`, which masks it to `rect`.
@property(nonatomic, readonly) UIView* wrapperView;

/// The region of the Flutter view that the Flutter content covers, in physical pixels.
@property(nonatomic, readonly) CGRect rect;

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithView:(UIView*)view
                 wrapperView:(UIView*)wrapperView
                        rect:(CGRect)rect NS_DESIGNATED_INITIALIZER;

@end

/// The platform views and overlays that make up one frame, along with the block that presents the
/// frame's Flutter content.
@interface FlutterPlatformViewFrame : NSObject

/// The platform views in the frame, in composition order.
@property(nonatomic, readonly) NSArray<FlutterPlatformViewLayer*>* layers;

/// The overlays in the frame, keyed by the ID of the platform view that each one is painted above.
@property(nonatomic, readonly) NSDictionary<NSNumber*, FlutterPlatformViewOverlay*>* overlays;

/// The wrapper views of the overlays that an earlier frame used and this frame does not.
///
/// `FlutterPlatformViewsController` removes them from the Flutter view in `presentFrame:`.
@property(nonatomic, readonly) NSArray<UIView*>* unusedOverlayViews;

/// Presents the Flutter content of the frame.
///
/// `FlutterPlatformViewsController` calls this block in the same `CATransaction` in which it
/// updates the platform views and overlays.
@property(nonatomic, readonly) void (^present)(void);

- (instancetype)init NS_UNAVAILABLE;

- (instancetype)initWithLayers:(NSArray<FlutterPlatformViewLayer*>*)layers
                      overlays:(NSDictionary<NSNumber*, FlutterPlatformViewOverlay*>*)overlays
            unusedOverlayViews:(NSArray<UIView*>*)unusedOverlayViews
                       present:(void (^)(void))present NS_DESIGNATED_INITIALIZER;

@end

NS_ASSUME_NONNULL_END

#endif  // FLUTTER_SHELL_PLATFORM_DARWIN_IOS_FRAMEWORK_SOURCE_FLUTTERPLATFORMVIEWFRAME_H_
