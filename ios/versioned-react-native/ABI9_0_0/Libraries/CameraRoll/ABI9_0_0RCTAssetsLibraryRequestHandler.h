/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ABI9_0_0RCTBridge.h"
#import "ABI9_0_0RCTURLRequestHandler.h"

@class ALAssetsLibrary;

@interface ABI9_0_0RCTAssetsLibraryRequestHandler : NSObject <ABI9_0_0RCTURLRequestHandler>

@end

@interface ABI9_0_0RCTBridge (ABI9_0_0RCTAssetsLibraryImageLoader)

/**
 * The shared asset library instance.
 */
@property (nonatomic, readonly) ALAssetsLibrary *assetsLibrary;

@end
