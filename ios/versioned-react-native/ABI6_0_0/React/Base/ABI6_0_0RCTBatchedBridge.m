/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import <Foundation/Foundation.h>

#import "ABI6_0_0RCTAssert.h"
#import "ABI6_0_0RCTBridge.h"
#import "ABI6_0_0RCTBridge+Private.h"
#import "ABI6_0_0RCTBridgeMethod.h"
#import "ABI6_0_0RCTConvert.h"
#import "ABI6_0_0RCTDisplayLink.h"
#import "ABI6_0_0RCTJSCExecutor.h"
#import "ABI6_0_0RCTJavaScriptLoader.h"
#import "ABI6_0_0RCTLog.h"
#import "ABI6_0_0RCTModuleData.h"
#import "ABI6_0_0RCTPerformanceLogger.h"
#import "ABI6_0_0RCTProfile.h"
#import "ABI6_0_0RCTSourceCode.h"
#import "ABI6_0_0RCTUtils.h"
#import "ABI6_0_0RCTRedBox.h"

#define ABI6_0_0RCTAssertJSThread() \
  ABI6_0_0RCTAssert(![NSStringFromClass([_javaScriptExecutor class]) isEqualToString:@"ABI6_0_0RCTJSCExecutor"] || \
              [[[NSThread currentThread] name] isEqualToString:ABI6_0_0RCTJSCThreadName], \
            @"This method must be called on JS thread")

/**
 * Must be kept in sync with `MessageQueue.js`.
 */
typedef NS_ENUM(NSUInteger, ABI6_0_0RCTBridgeFields) {
  ABI6_0_0RCTBridgeFieldRequestModuleIDs = 0,
  ABI6_0_0RCTBridgeFieldMethodIDs,
  ABI6_0_0RCTBridgeFieldParams,
  ABI6_0_0RCTBridgeFieldCallID,
};

ABI6_0_0RCT_EXTERN NSArray<Class> *ABI6_0_0RCTGetModuleClasses(void);

@implementation ABI6_0_0RCTBatchedBridge
{
  BOOL _wasBatchActive;
  NSMutableArray<dispatch_block_t> *_pendingCalls;
  NSMutableDictionary<NSString *, ABI6_0_0RCTModuleData *> *_moduleDataByName;
  NSArray<ABI6_0_0RCTModuleData *> *_moduleDataByID;
  NSArray<Class> *_moduleClassesByID;
  ABI6_0_0RCTDisplayLink *_displayLink;
}

@synthesize flowID = _flowID;
@synthesize flowIDMap = _flowIDMap;
@synthesize flowIDMapLock = _flowIDMapLock;
@synthesize loading = _loading;
@synthesize valid = _valid;

- (instancetype)initWithParentBridge:(ABI6_0_0RCTBridge *)bridge
{
  ABI6_0_0RCTAssertParam(bridge);

  if ((self = [super initWithBundleURL:bridge.bundleURL
                        moduleProvider:bridge.moduleProvider
                         launchOptions:bridge.launchOptions])) {

    _parentBridge = bridge;

    /**
     * Set Initial State
     */
    _valid = YES;
    _loading = YES;
    _pendingCalls = [NSMutableArray new];
    _displayLink = [ABI6_0_0RCTDisplayLink new];

    [ABI6_0_0RCTBridge setCurrentBridge:self];

    [[NSNotificationCenter defaultCenter]
     postNotificationName:ABI6_0_0RCTJavaScriptWillStartLoadingNotification
     object:_parentBridge userInfo:@{@"bridge": self}];

    [self start];
  }
  return self;
}

- (void)start
{
  dispatch_queue_t bridgeQueue = dispatch_queue_create("com.facebook.ReactABI6_0_0.ABI6_0_0RCTBridgeQueue", DISPATCH_QUEUE_CONCURRENT);

  dispatch_group_t initModulesAndLoadSource = dispatch_group_create();

  // Asynchronously load source code
  dispatch_group_enter(initModulesAndLoadSource);
  __weak ABI6_0_0RCTBatchedBridge *weakSelf = self;
  __block NSData *sourceCode;
  [self loadSource:^(NSError *error, NSData *source) {
    if (error) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf stopLoadingWithError:error];
      });
    }

    sourceCode = source;
    dispatch_group_leave(initModulesAndLoadSource);
  }];

  // Synchronously initialize all native modules that cannot be loaded lazily
  [self initModulesWithDispatchGroup:initModulesAndLoadSource];

  __block NSString *config;
  dispatch_group_enter(initModulesAndLoadSource);
  dispatch_async(bridgeQueue, ^{
    dispatch_group_t setupJSExecutorAndModuleConfig = dispatch_group_create();

    // Asynchronously initialize the JS executor
    dispatch_group_async(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      ABI6_0_0RCTPerformanceLoggerStart(ABI6_0_0RCTPLJSCExecutorSetup);
      [weakSelf setUpExecutor];
      ABI6_0_0RCTPerformanceLoggerEnd(ABI6_0_0RCTPLJSCExecutorSetup);
    });

    // Asynchronously gather the module config
    dispatch_group_async(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      if (weakSelf.valid) {
        ABI6_0_0RCTPerformanceLoggerStart(ABI6_0_0RCTPLNativeModulePrepareConfig);
        config = [weakSelf moduleConfig];
        ABI6_0_0RCTPerformanceLoggerEnd(ABI6_0_0RCTPLNativeModulePrepareConfig);
      }
    });

    dispatch_group_notify(setupJSExecutorAndModuleConfig, bridgeQueue, ^{
      // We're not waiting for this to complete to leave dispatch group, since
      // injectJSONConfiguration and executeSourceCode will schedule operations
      // on the same queue anyway.
      ABI6_0_0RCTPerformanceLoggerStart(ABI6_0_0RCTPLNativeModuleInjectConfig);
      [weakSelf injectJSONConfiguration:config onComplete:^(NSError *error) {
        ABI6_0_0RCTPerformanceLoggerEnd(ABI6_0_0RCTPLNativeModuleInjectConfig);
        if (error) {
          dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf stopLoadingWithError:error];
          });
        }
      }];
      dispatch_group_leave(initModulesAndLoadSource);
    });
  });

  dispatch_group_notify(initModulesAndLoadSource, bridgeQueue, ^{
    ABI6_0_0RCTBatchedBridge *strongSelf = weakSelf;
    if (sourceCode && strongSelf.loading) {
      [strongSelf executeSourceCode:sourceCode];
    }
  });
}

- (void)loadSource:(ABI6_0_0RCTSourceLoadBlock)_onSourceLoad
{
  ABI6_0_0RCTPerformanceLoggerStart(ABI6_0_0RCTPLScriptDownload);

  ABI6_0_0RCTSourceLoadBlock onSourceLoad = ^(NSError *error, NSData *source) {
    ABI6_0_0RCTPerformanceLoggerEnd(ABI6_0_0RCTPLScriptDownload);

    _onSourceLoad(error, source);
  };

  if ([self.delegate respondsToSelector:@selector(loadSourceForBridge:withBlock:)]) {
    [self.delegate loadSourceForBridge:_parentBridge withBlock:onSourceLoad];
  } else if (self.bundleURL) {
    [ABI6_0_0RCTJavaScriptLoader loadBundleAtURL:self.bundleURL onComplete:onSourceLoad];
  } else {
    // Allow testing without a script
    dispatch_async(dispatch_get_main_queue(), ^{
      [self didFinishLoading];
      [[NSNotificationCenter defaultCenter]
       postNotificationName:ABI6_0_0RCTJavaScriptDidLoadNotification
       object:_parentBridge userInfo:@{@"bridge": self}];
    });
    onSourceLoad(nil, nil);
  }
}

- (NSArray<Class> *)moduleClasses
{
  if (ABI6_0_0RCT_DEBUG && _valid && _moduleClassesByID == nil) {
    ABI6_0_0RCTLogError(@"Bridge modules have not yet been initialized. You may be "
                "trying to access a module too early in the startup procedure.");
  }
  return _moduleClassesByID;
}

/**
 * Used by ABI6_0_0RCTUIManager
 */
- (ABI6_0_0RCTModuleData *)moduleDataForName:(NSString *)moduleName
{
  return _moduleDataByName[moduleName];
}

- (id)moduleForName:(NSString *)moduleName
{
  return _moduleDataByName[moduleName].instance;
}

- (BOOL)moduleIsInitialized:(Class)moduleClass
{
  return _moduleDataByName[ABI6_0_0RCTBridgeModuleNameForClass(moduleClass)].hasInstance;
}

- (NSArray *)configForModuleName:(NSString *)moduleName
{
  ABI6_0_0RCTModuleData *moduleData = _moduleDataByName[moduleName];
  if (!moduleData) {
    moduleData = _moduleDataByName[[@"RCT" stringByAppendingString:moduleName]];
  }
  if (moduleData) {
    return moduleData.config;
  }
  return (id)kCFNull;
}

- (void)initModulesWithDispatchGroup:(dispatch_group_t)dispatchGroup
{
  ABI6_0_0RCTPerformanceLoggerStart(ABI6_0_0RCTPLNativeModuleInit);

  NSArray<id<ABI6_0_0RCTBridgeModule>> *extraModules = nil;
  if (self.delegate) {
    if ([self.delegate respondsToSelector:@selector(extraModulesForBridge:)]) {
      extraModules = [self.delegate extraModulesForBridge:_parentBridge];
    }
  } else if (self.moduleProvider) {
    extraModules = self.moduleProvider();
  }

  if (ABI6_0_0RCT_DEBUG && !ABI6_0_0RCTRunningInTestEnvironment()) {

    // Check for unexported modules
    static Class *classes;
    static unsigned int classCount;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      classes = objc_copyClassList(&classCount);
    });

    NSMutableSet *moduleClasses = [NSMutableSet new];
    [moduleClasses addObjectsFromArray:ABI6_0_0RCTGetModuleClasses()];
    [moduleClasses addObjectsFromArray:[extraModules valueForKeyPath:@"class"]];

    for (unsigned int i = 0; i < classCount; i++)
    {
      Class cls = classes[i];
      Class superclass = cls;
      while (superclass)
      {
        if (class_conformsToProtocol(superclass, @protocol(ABI6_0_0RCTBridgeModule)))
        {
          if (![moduleClasses containsObject:cls] &&
              ![cls respondsToSelector:@selector(moduleName)]) {
            ABI6_0_0RCTLogWarn(@"Class %@ was not exported. Did you forget to use "
                       "ABI6_0_0RCT_EXPORT_MODULE()?", cls);
          }
          break;
        }
        superclass = class_getSuperclass(superclass);
      }
    }
  }

  NSMutableArray<Class> *moduleClassesByID = [NSMutableArray new];
  NSMutableArray<ABI6_0_0RCTModuleData *> *moduleDataByID = [NSMutableArray new];
  NSMutableDictionary<NSString *, ABI6_0_0RCTModuleData *> *moduleDataByName = [NSMutableDictionary new];

  // Set up moduleData for pre-initialized module instances
  for (id<ABI6_0_0RCTBridgeModule> module in extraModules) {
    Class moduleClass = [module class];
    NSString *moduleName = ABI6_0_0RCTBridgeModuleNameForClass(moduleClass);

    if (ABI6_0_0RCT_DEBUG) {
      // Check for name collisions between preregistered modules
      ABI6_0_0RCTModuleData *moduleData = moduleDataByName[moduleName];
      if (moduleData) {
        ABI6_0_0RCTLogError(@"Attempted to register ABI6_0_0RCTBridgeModule class %@ for the "
                    "name '%@', but name was already registered by class %@",
                    moduleClass, moduleName, moduleData.moduleClass);
        continue;
      }
    }

    // Instantiate moduleData container
    ABI6_0_0RCTModuleData *moduleData = [[ABI6_0_0RCTModuleData alloc] initWithModuleInstance:module
                                                                       bridge:self];
    moduleDataByName[moduleName] = moduleData;
    [moduleClassesByID addObject:moduleClass];
    [moduleDataByID addObject:moduleData];

    // Set executor instance
    if (moduleClass == self.executorClass) {
      _javaScriptExecutor = (id<ABI6_0_0RCTJavaScriptExecutor>)module;
    }
  }

  // The executor is a bridge module, but we want it to be instantiated before
  // any other module has access to the bridge, in case they need the JS thread.
  // TODO: once we have more fine-grained control of init (t11106126) we can
  // probably just replace this with [self moduleForClass:self.executorClass]
  if (!_javaScriptExecutor) {
    id<ABI6_0_0RCTJavaScriptExecutor> executorModule = [self.executorClass new];
    ABI6_0_0RCTModuleData *moduleData = [[ABI6_0_0RCTModuleData alloc] initWithModuleInstance:executorModule
                                                                       bridge:self];
    moduleDataByName[moduleData.name] = moduleData;
    [moduleClassesByID addObject:self.executorClass];
    [moduleDataByID addObject:moduleData];

    // NOTE: _javaScriptExecutor is a weak reference
    _javaScriptExecutor = executorModule;
  }

  // Set up moduleData for automatically-exported modules
  for (Class moduleClass in ABI6_0_0RCTGetModuleClasses()) {
    NSString *moduleName = ABI6_0_0RCTBridgeModuleNameForClass(moduleClass);

    // Check for module name collisions
    ABI6_0_0RCTModuleData *moduleData = moduleDataByName[moduleName];
    if (moduleData) {
      if (moduleData.hasInstance) {
        // Existing module was preregistered, so it takes precedence
        continue;
      } else if ([moduleClass new] == nil) {
        // The new module returned nil from init, so use the old module
        continue;
      } else if ([moduleData.moduleClass new] != nil) {
        // Both modules were non-nil, so it's unclear which should take precedence
        ABI6_0_0RCTLogError(@"Attempted to register ABI6_0_0RCTBridgeModule class %@ for the "
                    "name '%@', but name was already registered by class %@",
                    moduleClass, moduleName, moduleData.moduleClass);
      }
    }

    // Instantiate moduleData (TODO: can we defer this until config generation?)
    moduleData = [[ABI6_0_0RCTModuleData alloc] initWithModuleClass:moduleClass
                                                     bridge:self];
    moduleDataByName[moduleName] = moduleData;
    [moduleClassesByID addObject:moduleClass];
    [moduleDataByID addObject:moduleData];
  }

  // Store modules
  _moduleDataByID = [moduleDataByID copy];
  _moduleDataByName = [moduleDataByName copy];
  _moduleClassesByID = [moduleClassesByID copy];

  // Synchronously set up the pre-initialized modules
  for (ABI6_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.hasInstance &&
        (!moduleData.requiresMainThreadSetup || [NSThread isMainThread])) {
      // Modules that were pre-initialized should ideally be set up before
      // bridge init has finished, otherwise the caller may try to access the
      // module directly rather than via `[bridge moduleForClass:]`, which won't
      // trigger the lazy initialization process. If the module cannot safely be
      // set up on the current thread, it will instead be async dispatched
      // to the main thread to be set up in the loop below.
      (void)[moduleData instance];
    }
  }

  // From this point on, ABI6_0_0RCTDidInitializeModuleNotification notifications will
  // be sent the first time a module is accessed.
  _moduleSetupComplete = YES;

  // Set up modules that require main thread init or constants export
  ABI6_0_0RCTPerformanceLoggerSet(ABI6_0_0RCTPLNativeModuleMainThread, 0);
  NSUInteger modulesOnMainThreadCount = 0;
  for (ABI6_0_0RCTModuleData *moduleData in _moduleDataByID) {
    __weak ABI6_0_0RCTBatchedBridge *weakSelf = self;
    if (moduleData.requiresMainThreadSetup || moduleData.hasConstantsToExport) {
      // Modules that need to be set up on the main thread cannot be initialized
      // lazily when required without doing a dispatch_sync to the main thread,
      // which can result in deadlock. To avoid this, we initialize all of these
      // modules on the main thread in parallel with loading the JS code, so
      // they will already be available before they are ever required.
      dispatch_group_async(dispatchGroup, dispatch_get_main_queue(), ^{
        if (weakSelf.valid) {
          ABI6_0_0RCTPerformanceLoggerAppendStart(ABI6_0_0RCTPLNativeModuleMainThread);
          (void)[moduleData instance];
          [moduleData gatherConstants];
          ABI6_0_0RCTPerformanceLoggerAppendEnd(ABI6_0_0RCTPLNativeModuleMainThread);
        }
      });
      modulesOnMainThreadCount++;
    }
  }

  ABI6_0_0RCTPerformanceLoggerEnd(ABI6_0_0RCTPLNativeModuleInit);
  ABI6_0_0RCTPerformanceLoggerSet(ABI6_0_0RCTPLNativeModuleMainThreadUsesCount, modulesOnMainThreadCount);
}

- (void)setUpExecutor
{
  [_javaScriptExecutor setUp];
}

- (void)registerModuleForFrameUpdates:(id<ABI6_0_0RCTBridgeModule>)module
                       withModuleData:(ABI6_0_0RCTModuleData *)moduleData
{
  [_displayLink registerModuleForFrameUpdates:module withModuleData:moduleData];
}

- (NSString *)moduleConfig
{
  NSMutableArray<NSArray *> *config = [NSMutableArray new];
  for (ABI6_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (self.executorClass == [ABI6_0_0RCTJSCExecutor class]) {
      [config addObject:@[moduleData.name]];
    } else {
      [config addObject:ABI6_0_0RCTNullIfNil(moduleData.config)];
    }
  }

  return ABI6_0_0RCTJSONStringify(@{
    @"remoteModuleConfig": config,
  }, NULL);
}

- (void)injectJSONConfiguration:(NSString *)configJSON
                     onComplete:(void (^)(NSError *))onComplete
{
  if (!_valid) {
    return;
  }

  [_javaScriptExecutor injectJSONText:configJSON
                  asGlobalObjectNamed:@"__fbBatchedBridgeConfig"
                             callback:onComplete];
}

- (void)executeSourceCode:(NSData *)sourceCode
{
  if (!_valid || !_javaScriptExecutor) {
    return;
  }

  ABI6_0_0RCTSourceCode *sourceCodeModule = [self moduleForClass:[ABI6_0_0RCTSourceCode class]];
  sourceCodeModule.scriptURL = self.bundleURL;
  sourceCodeModule.scriptData = sourceCode;

  [self enqueueApplicationScript:sourceCode url:self.bundleURL onComplete:^(NSError *loadError) {
    if (!_valid) {
      return;
    }

    if (loadError) {
      dispatch_async(dispatch_get_main_queue(), ^{
        [self stopLoadingWithError:loadError];
      });
      return;
    }

    // Register the display link to start sending js calls after everything is setup
    NSRunLoop *targetRunLoop = [_javaScriptExecutor isKindOfClass:[ABI6_0_0RCTJSCExecutor class]] ? [NSRunLoop currentRunLoop] : [NSRunLoop mainRunLoop];
    [_displayLink addToRunLoop:targetRunLoop];

    // Perform the state update and notification on the main thread, so we can't run into
    // timing issues with ABI6_0_0RCTRootView
    dispatch_async(dispatch_get_main_queue(), ^{
      [self didFinishLoading];
      [[NSNotificationCenter defaultCenter]
       postNotificationName:ABI6_0_0RCTJavaScriptDidLoadNotification
       object:_parentBridge userInfo:@{@"bridge": self}];
    });
  }];

#if ABI6_0_0RCT_DEV

  if ([ABI6_0_0RCTGetURLQueryParam(self.bundleURL, @"hot") boolValue]) {
    NSString *path = [self.bundleURL.path substringFromIndex:1]; // strip initial slash
    NSString *host = self.bundleURL.host;
    NSNumber *port = self.bundleURL.port;
    [self enqueueJSCall:@"HMRClient.enable" args:@[@"ios", path, host, ABI6_0_0RCTNullIfNil(port)]];
  }

#endif

}

- (void)didFinishLoading
{
  ABI6_0_0RCTPerformanceLoggerEnd(ABI6_0_0RCTPLBridgeStartup);
  _loading = NO;
  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    for (dispatch_block_t call in _pendingCalls) {
      call();
    }
  }];
}

- (void)stopLoadingWithError:(NSError *)error
{
  ABI6_0_0RCTAssertMainThread();

  if (!_valid || !_loading) {
    return;
  }

  _loading = NO;
  [_javaScriptExecutor invalidate];

  [[NSNotificationCenter defaultCenter]
   postNotificationName:ABI6_0_0RCTJavaScriptDidFailToLoadNotification
   object:_parentBridge userInfo:@{@"bridge": self, @"error": error}];

  if ([error userInfo][ABI6_0_0RCTJSStackTraceKey]) {
    [self.redBox showErrorMessage:[error localizedDescription]
                        withStack:[error userInfo][ABI6_0_0RCTJSStackTraceKey]];
  }
  ABI6_0_0RCTFatal(error);
}

ABI6_0_0RCT_NOT_IMPLEMENTED(- (instancetype)initWithBundleURL:(__unused NSURL *)bundleURL
                    moduleProvider:(__unused ABI6_0_0RCTBridgeModuleProviderBlock)block
                    launchOptions:(__unused NSDictionary *)launchOptions)

/**
 * Prevent super from calling setUp (that'd create another batchedBridge)
 */
- (void)setUp {}
- (void)bindKeys {}

- (void)reload
{
  [_parentBridge reload];
}

- (Class)executorClass
{
  return _parentBridge.executorClass ?: [ABI6_0_0RCTJSCExecutor class];
}

- (void)setExecutorClass:(Class)executorClass
{
  ABI6_0_0RCTAssertMainThread();

  _parentBridge.executorClass = executorClass;
}

- (NSURL *)bundleURL
{
  return _parentBridge.bundleURL;
}

- (void)setBundleURL:(NSURL *)bundleURL
{
  _parentBridge.bundleURL = bundleURL;
}

- (id<ABI6_0_0RCTBridgeDelegate>)delegate
{
  return _parentBridge.delegate;
}

- (BOOL)isLoading
{
  return _loading;
}

- (BOOL)isValid
{
  return _valid;
}

- (void)dispatchBlock:(dispatch_block_t)block
                queue:(dispatch_queue_t)queue
{
  if (queue == ABI6_0_0RCTJSThread) {
    [_javaScriptExecutor executeBlockOnJavaScriptQueue:block];
  } else if (queue) {
    dispatch_async(queue, block);
  }
}

#pragma mark - ABI6_0_0RCTInvalidating

- (void)invalidate
{
  if (!_valid) {
    return;
  }

  ABI6_0_0RCTAssertMainThread();
  ABI6_0_0RCTAssert(_javaScriptExecutor != nil, @"Can't complete invalidation without a JS executor");

  _loading = NO;
  _valid = NO;
  if ([ABI6_0_0RCTBridge currentBridge] == self) {
    [ABI6_0_0RCTBridge setCurrentBridge:nil];
  }

  // Invalidate modules
  dispatch_group_t group = dispatch_group_create();
  for (ABI6_0_0RCTModuleData *moduleData in _moduleDataByID) {
    // Be careful when grabbing an instance here, we don't want to instantiate
    // any modules just to invalidate them.
    id<ABI6_0_0RCTBridgeModule> instance = nil;
    if ([moduleData hasInstance]) {
      instance = moduleData.instance;
    }

    if (instance == _javaScriptExecutor) {
      continue;
    }

    if ([instance respondsToSelector:@selector(invalidate)]) {
      dispatch_group_enter(group);
      [self dispatchBlock:^{
        [(id<ABI6_0_0RCTInvalidating>)instance invalidate];
        dispatch_group_leave(group);
      } queue:moduleData.methodQueue];
    }
    [moduleData invalidate];
  }

  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
      [_displayLink invalidate];
      _displayLink = nil;

      [_javaScriptExecutor invalidate];
      _javaScriptExecutor = nil;

      if (ABI6_0_0RCTProfileIsProfiling()) {
        ABI6_0_0RCTProfileUnhookModules(self);
      }

      _moduleDataByName = nil;
      _moduleDataByID = nil;
      _moduleClassesByID = nil;
      _pendingCalls = nil;

      if (_flowIDMap != NULL) {
        CFRelease(_flowIDMap);
      }
    }];
  });
}

- (void)logMessage:(NSString *)message level:(NSString *)level
{
  if (ABI6_0_0RCT_DEBUG && [_javaScriptExecutor isValid]) {
    [self enqueueJSCall:@"ABI6_0_0RCTLog.logIfNoNativeHook"
                   args:@[level, message]];
  }
}

#pragma mark - ABI6_0_0RCTBridge methods

/**
 * Public. Can be invoked from any thread.
 */
- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args
{
 moduleDotMethod = ABI6_0_0EX_REMOVE_VERSION(moduleDotMethod);
 /**
   * AnyThread
   */

  ABI6_0_0RCT_PROFILE_BEGIN_EVENT(ABI6_0_0RCTProfileTagAlways, @"-[ABI6_0_0RCTBatchedBridge enqueueJSCall:]", nil);

  NSArray<NSString *> *ids = [moduleDotMethod componentsSeparatedByString:@"."];

  NSString *module = ids[0];
  NSString *method = ids[1];

  ABI6_0_0RCTProfileBeginFlowEvent();

  __weak ABI6_0_0RCTBatchedBridge *weakSelf = self;
  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    ABI6_0_0RCTProfileEndFlowEvent();

    ABI6_0_0RCTBatchedBridge *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.valid) {
      return;
    }

    if (strongSelf.loading) {
      dispatch_block_t pendingCall = ^{
        [weakSelf _actuallyInvokeAndProcessModule:module method:method arguments:args ?: @[]];
      };
      [strongSelf->_pendingCalls addObject:pendingCall];
    } else {
      [strongSelf _actuallyInvokeAndProcessModule:module method:method arguments:args ?: @[]];
    }
  }];

  ABI6_0_0RCT_PROFILE_END_EVENT(ABI6_0_0RCTProfileTagAlways, @"", nil);
}

/**
 * Called by ABI6_0_0RCTModuleMethod from any thread.
 */
- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args
{
  /**
   * AnyThread
   */

  ABI6_0_0RCTProfileBeginFlowEvent();

  __weak ABI6_0_0RCTBatchedBridge *weakSelf = self;
  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    ABI6_0_0RCTProfileEndFlowEvent();

    ABI6_0_0RCTBatchedBridge *strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.valid) {
      return;
    }

    if (strongSelf.loading) {
      dispatch_block_t pendingCall = ^{
        [weakSelf _actuallyInvokeCallback:cbID arguments:args ?: @[]];
      };
      [strongSelf->_pendingCalls addObject:pendingCall];
    } else {
      [strongSelf _actuallyInvokeCallback:cbID arguments:args];
    }
  }];
}

/**
 * Private hack to support `setTimeout(fn, 0)`
 */
- (void)_immediatelyCallTimer:(NSNumber *)timer
{
  ABI6_0_0RCTAssertJSThread();

  dispatch_block_t block = ^{
    [self _actuallyInvokeAndProcessModule:@"JSTimersExecution"
                                   method:@"callTimers"
                                arguments:@[@[timer]]];
  };

  if ([_javaScriptExecutor respondsToSelector:@selector(executeAsyncBlockOnJavaScriptQueue:)]) {
    [_javaScriptExecutor executeAsyncBlockOnJavaScriptQueue:block];
  } else {
    [_javaScriptExecutor executeBlockOnJavaScriptQueue:block];
  }
}

- (void)enqueueApplicationScript:(NSData *)script
                             url:(NSURL *)url
                      onComplete:(ABI6_0_0RCTJavaScriptCompleteBlock)onComplete
{
  ABI6_0_0RCTAssert(onComplete != nil, @"onComplete block passed in should be non-nil");

  ABI6_0_0RCTProfileBeginFlowEvent();
  [_javaScriptExecutor executeApplicationScript:script sourceURL:url onComplete:^(NSError *scriptLoadError) {
    ABI6_0_0RCTProfileEndFlowEvent();
    ABI6_0_0RCTAssertJSThread();

    if (scriptLoadError) {
      onComplete(scriptLoadError);
      return;
    }

    ABI6_0_0RCT_PROFILE_BEGIN_EVENT(ABI6_0_0RCTProfileTagAlways, @"FetchApplicationScriptCallbacks", nil);
    [_javaScriptExecutor flushedQueue:^(id json, NSError *error)
     {
       ABI6_0_0RCT_PROFILE_END_EVENT(ABI6_0_0RCTProfileTagAlways, @"js_call,init", @{
         @"json": ABI6_0_0RCTNullIfNil(json),
         @"error": ABI6_0_0RCTNullIfNil(error),
       });

       [self handleBuffer:json batchEnded:YES];

       onComplete(error);
     }];
  }];
}

#pragma mark - Payload Generation

- (void)_actuallyInvokeAndProcessModule:(NSString *)module
                                 method:(NSString *)method
                              arguments:(NSArray *)args
{
  ABI6_0_0RCTAssertJSThread();

  __weak typeof(self) weakSelf = self;
  [_javaScriptExecutor callFunctionOnModule:module
                                     method:method
                                  arguments:args
                                   callback:^(id json, NSError *error) {
                                     [weakSelf _processResponse:json error:error];
                                   }];
}

- (void)_actuallyInvokeCallback:(NSNumber *)cbID
                      arguments:(NSArray *)args
{
  ABI6_0_0RCTAssertJSThread();

  __weak typeof(self) weakSelf = self;
  [_javaScriptExecutor invokeCallbackID:cbID
                              arguments:args
                               callback:^(id json, NSError *error) {
                                 [weakSelf _processResponse:json error:error];
                               }];
}

- (void)_processResponse:(id)json error:(NSError *)error
{
  if (error) {
    if ([error userInfo][ABI6_0_0RCTJSStackTraceKey]) {
      [self.redBox showErrorMessage:[error localizedDescription]
                          withStack:[error userInfo][ABI6_0_0RCTJSStackTraceKey]];
    }
    ABI6_0_0RCTFatal(error);
  }

  if (!_valid) {
    return;
  }
  [self handleBuffer:json batchEnded:YES];
}

#pragma mark - Payload Processing

- (void)handleBuffer:(id)buffer batchEnded:(BOOL)batchEnded
{
  ABI6_0_0RCTAssertJSThread();

  if (buffer != nil && buffer != (id)kCFNull) {
    _wasBatchActive = YES;
    [self handleBuffer:buffer];
    [self partialBatchDidFlush];
  }

  if (batchEnded) {
    if (_wasBatchActive) {
      [self batchDidComplete];
    }

    _wasBatchActive = NO;
  }
}

- (void)handleBuffer:(NSArray *)buffer
{
  NSArray *requestsArray = [ABI6_0_0RCTConvert NSArray:buffer];

  if (ABI6_0_0RCT_DEBUG && requestsArray.count <= ABI6_0_0RCTBridgeFieldParams) {
    ABI6_0_0RCTLogError(@"Buffer should contain at least %tu sub-arrays. Only found %tu",
                ABI6_0_0RCTBridgeFieldParams + 1, requestsArray.count);
    return;
  }

  NSArray<NSNumber *> *moduleIDs = [ABI6_0_0RCTConvert NSNumberArray:requestsArray[ABI6_0_0RCTBridgeFieldRequestModuleIDs]];
  NSArray<NSNumber *> *methodIDs = [ABI6_0_0RCTConvert NSNumberArray:requestsArray[ABI6_0_0RCTBridgeFieldMethodIDs]];
  NSArray<NSArray *> *paramsArrays = [ABI6_0_0RCTConvert NSArrayArray:requestsArray[ABI6_0_0RCTBridgeFieldParams]];

  int64_t callID = -1;

  if (requestsArray.count > 3) {
    callID = [requestsArray[ABI6_0_0RCTBridgeFieldCallID] longLongValue];
  }

  if (ABI6_0_0RCT_DEBUG && (moduleIDs.count != methodIDs.count || moduleIDs.count != paramsArrays.count)) {
    ABI6_0_0RCTLogError(@"Invalid data message - all must be length: %zd", moduleIDs.count);
    return;
  }

  NSMapTable *buckets = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                                  valueOptions:NSPointerFunctionsStrongMemory
                                                      capacity:_moduleDataByName.count];

  [moduleIDs enumerateObjectsUsingBlock:^(NSNumber *moduleID, NSUInteger i, __unused BOOL *stop) {
    ABI6_0_0RCTModuleData *moduleData = _moduleDataByID[moduleID.integerValue];
    dispatch_queue_t queue = moduleData.methodQueue;
    NSMutableOrderedSet<NSNumber *> *set = [buckets objectForKey:queue];
    if (!set) {
      set = [NSMutableOrderedSet new];
      [buckets setObject:set forKey:queue];
    }
    [set addObject:@(i)];
  }];

  for (dispatch_queue_t queue in buckets) {
    ABI6_0_0RCTProfileBeginFlowEvent();

    dispatch_block_t block = ^{
      ABI6_0_0RCTProfileEndFlowEvent();
      ABI6_0_0RCT_PROFILE_BEGIN_EVENT(ABI6_0_0RCTProfileTagAlways, @"-[ABI6_0_0RCTBatchedBridge handleBuffer:]", nil);

      NSOrderedSet *calls = [buckets objectForKey:queue];
      @autoreleasepool {
        for (NSNumber *indexObj in calls) {
          NSUInteger index = indexObj.unsignedIntegerValue;
          if (ABI6_0_0RCT_DEV && callID != -1 && _flowIDMap != NULL && ABI6_0_0RCTProfileIsProfiling()) {
            [self.flowIDMapLock lock];
            int64_t newFlowID = (int64_t)CFDictionaryGetValue(_flowIDMap, (const void *)(_flowID + index));
            _ABI6_0_0RCTProfileEndFlowEvent(@(newFlowID));
            CFDictionaryRemoveValue(_flowIDMap, (const void *)(_flowID + index));
            [self.flowIDMapLock unlock];
          }
          [self _handleRequestNumber:index
                            moduleID:[moduleIDs[index] integerValue]
                            methodID:[methodIDs[index] integerValue]
                              params:paramsArrays[index]];
        }
      }

      ABI6_0_0RCT_PROFILE_END_EVENT(ABI6_0_0RCTProfileTagAlways, @"objc_call,dispatch_async", @{
        @"calls": @(calls.count),
      });
    };

    if (queue == ABI6_0_0RCTJSThread) {
      [_javaScriptExecutor executeBlockOnJavaScriptQueue:block];
    } else if (queue) {
      dispatch_async(queue, block);
    }
  }

  _flowID = callID;
}

- (void)partialBatchDidFlush
{
  for (ABI6_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.implementsPartialBatchDidFlush) {
      [self dispatchBlock:^{
        [moduleData.instance partialBatchDidFlush];
      } queue:moduleData.methodQueue];
    }
  }
}

- (void)batchDidComplete
{
  // TODO: batchDidComplete is only used by ABI6_0_0RCTUIManager - can we eliminate this special case?
  for (ABI6_0_0RCTModuleData *moduleData in _moduleDataByID) {
    if (moduleData.implementsBatchDidComplete) {
      [self dispatchBlock:^{
        [moduleData.instance batchDidComplete];
      } queue:moduleData.methodQueue];
    }
  }
}

- (BOOL)_handleRequestNumber:(NSUInteger)i
                    moduleID:(NSUInteger)moduleID
                    methodID:(NSUInteger)methodID
                      params:(NSArray *)params
{
  if (!_valid) {
    return NO;
  }

  if (ABI6_0_0RCT_DEBUG && ![params isKindOfClass:[NSArray class]]) {
    ABI6_0_0RCTLogError(@"Invalid module/method/params tuple for request #%zd", i);
    return NO;
  }

  ABI6_0_0RCTModuleData *moduleData = _moduleDataByID[moduleID];
  if (ABI6_0_0RCT_DEBUG && !moduleData) {
    ABI6_0_0RCTLogError(@"No module found for id '%zd'", moduleID);
    return NO;
  }

  id<ABI6_0_0RCTBridgeMethod> method = moduleData.methods[methodID];
  if (ABI6_0_0RCT_DEBUG && !method) {
    ABI6_0_0RCTLogError(@"Unknown methodID: %zd for module: %zd (%@)", methodID, moduleID, moduleData.name);
    return NO;
  }

  @try {
    [method invokeWithBridge:self module:moduleData.instance arguments:params];
  }
  @catch (NSException *exception) {
    // Pass on JS exceptions
    if ([exception.name hasPrefix:ABI6_0_0RCTFatalExceptionName]) {
      @throw exception;
    }

    NSString *message = [NSString stringWithFormat:
                         @"Exception '%@' was thrown while invoking %@ on target %@ with params %@",
                         exception, method.JSMethodName, moduleData.name, params];
    ABI6_0_0RCTFatal(ABI6_0_0RCTErrorWithMessage(message));
  }

  return YES;
}

- (void)startProfiling
{
  ABI6_0_0RCTAssertMainThread();

  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    ABI6_0_0RCTProfileInit(self);
  }];
}

- (void)stopProfiling:(void (^)(NSData *))callback
{
  ABI6_0_0RCTAssertMainThread();

  [_javaScriptExecutor executeBlockOnJavaScriptQueue:^{
    ABI6_0_0RCTProfileEnd(self, ^(NSString *log) {
      NSData *logData = [log dataUsingEncoding:NSUTF8StringEncoding];
      callback(logData);
    });
  }];
}

- (BOOL)isBatchActive
{
  return _wasBatchActive;
}

- (ABI6_0_0RCTBridge *)baseBridge
{
  return _parentBridge;
}

@end
