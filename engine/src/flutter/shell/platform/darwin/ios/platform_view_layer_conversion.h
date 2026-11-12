// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_DARWIN_IOS_PLATFORM_VIEW_LAYER_CONVERSION_H_
#define FLUTTER_SHELL_PLATFORM_DARWIN_IOS_PLATFORM_VIEW_LAYER_CONVERSION_H_

#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>

#include "flutter/display_list/geometry/dl_geometry_types.h"
#include "flutter/display_list/geometry/dl_path.h"
#include "flutter/flow/embedded_views.h"
#include "flutter/fml/platform/darwin/cf_utils.h"
#import "flutter/shell/platform/darwin/ios/framework/Source/FlutterPlatformViewLayer.h"

namespace flutter {

/// Returns `matrix` as a `CATransform3D`.
CATransform3D GetCATransform3DFromDlMatrix(const DlMatrix& matrix);

/// Returns `rect` as a `CGRect`.
CGRect GetCGRectFromDlRect(const DlRect& rect);

/// Returns `path` as a `CGPath`.
fml::CFRef<CGPathRef> GetCGPathFromDlPath(const DlPath& path);

/// Returns the layer for the platform view identified by `view_id`.
///
/// The layer's size is the size in `params` scaled by `device_pixel_ratio`.
///
/// This function omits rect, rounded rect, and rounded superellipse clips that cover the whole
/// view, since they do not clip it.
/// It also omits backdrop filters other than blurs, since we can't apply those to a platform view.
FlutterPlatformViewLayer* GetPlatformViewLayerFromEmbeddedViewParams(
    int64_t view_id,
    const EmbeddedViewParams& params,
    double device_pixel_ratio);

}  // namespace flutter

#endif  // FLUTTER_SHELL_PLATFORM_DARWIN_IOS_PLATFORM_VIEW_LAYER_CONVERSION_H_
