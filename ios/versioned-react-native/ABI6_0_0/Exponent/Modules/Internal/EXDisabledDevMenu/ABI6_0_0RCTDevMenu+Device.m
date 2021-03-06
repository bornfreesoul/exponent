// Copyright 2015-present 650 Industries. All rights reserved.

#import "ABI6_0_0RCTDevMenu+Device.h"
#import "ABI6_0_0RCTUtils.h"

NS_ASSUME_NONNULL_BEGIN

@interface ABI6_0_0RCTDevMenuItem ()

@property (nonatomic, copy, readonly) NSString *title;

@end

@implementation ABI6_0_0RCTDevMenu (Device)

+ (void)load
{
  ABI6_0_0RCTSwapInstanceMethods(self, @selector(menuItems), @selector(ex_menuItems));
}

- (NSArray *)ex_menuItems
{
  NSArray *allMenuItems = [self ex_menuItems];
  NSString *className = NSStringFromClass([self class]);
  BOOL isVersioned = [className hasPrefix:@"ABI"];
  
#if TARGET_IPHONE_SIMULATOR
  // enable everything on simulator
  // but only if we're running in an ABI
  // TODO: more permanent fix for remote debugging
  if (isVersioned) {
    return allMenuItems;
  }
#endif

  NSError *error;
  NSRegularExpression *regexToDisable;
  if (isVersioned) {
    regexToDisable = [NSRegularExpression regularExpressionWithPattern:@"\\b(Debug)\\b"
                                                               options:NSRegularExpressionUseUnicodeWordBoundaries
                                                                 error:&error];
  } else {
    // TODO: enable live reloading once ABI6_0_0RCTReloadNotification is not global
    regexToDisable = [NSRegularExpression regularExpressionWithPattern:@"\\b(Debug|Live)\\b"
                                                               options:NSRegularExpressionUseUnicodeWordBoundaries
                                                                 error:&error];
  }
  if (!regexToDisable) {
    return allMenuItems;
  }
  
  NSIndexSet *indexes = [[self ex_menuItems] indexesOfObjectsWithOptions:NSEnumerationConcurrent passingTest:^BOOL(ABI6_0_0RCTDevMenuItem *menuItem, NSUInteger index, BOOL *stop) {
    NSRange matchRange = [regexToDisable rangeOfFirstMatchInString:menuItem.title options:0 range:NSMakeRange(0, menuItem.title.length)];
    return matchRange.location == NSNotFound;
  }];
  return [allMenuItems objectsAtIndexes:indexes];
}

@end

NS_ASSUME_NONNULL_END
