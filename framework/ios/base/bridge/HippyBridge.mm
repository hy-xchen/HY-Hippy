/*!
 * iOS SDK
 *
 * Tencent is pleased to support the open source community by making
 * Hippy available.
 *
 * Copyright (C) 2019 THL A29 Limited, a Tencent company.
 * All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "HippyBridge.h"
#import "HippyBridge+Private.h"
#import "HippyBundleLoadOperation.h"
#import "HippyBundleExecutionOperation.h"
#import "HippyBundleOperationQueue.h"
#import "HippyDeviceBaseInfo.h"
#import "HippyDisplayLink.h"
#import "HippyEventDispatcher.h"
#import "HippyFileHandler.h"
#import "HippyJSEnginesMapper.h"
#import "HippyJSExecutor.h"
#import "HippyKeyCommands.h"
#import "HippyModuleData.h"
#import "HippyModuleMethod.h"
#import "HippyTurboModuleManager.h"
#import "HippyOCTurboModule.h"
#import "HippyRedBox.h"
#import "HippyTurboModule.h"
#import "HippyUtils.h"
#import "HippyAssert.h"
#import "HippyConvert.h"
#import "HippyDefaultImageProvider.h"
#import "HippyI18nUtils.h"
#import "HippyInvalidating.h"
#import "HippyLog.h"
#import "HippyOCToHippyValue.h"
#import "HippyUtils.h"
#import "TypeConverter.h"
#import "VFSUriLoader.h"
#import "HippyBase64DataHandler.h"
#import "NativeRenderManager.h"
#import "HippyRootView.h"
#import "UIView+Hippy.h"
#import "UIView+MountEvent.h"
#import "HippyUIManager.h"
#import "HippyUIManager+Private.h"

#include "dom/animation/animation_manager.h"
#include "dom/dom_manager.h"
#include "dom/scene.h"
#include "dom/render_manager.h"
#include "dom/layer_optimized_render_manager.h"
#include "driver/scope.h"
#include "footstone/worker_manager.h"
#include "vfs/uri_loader.h"
#include "VFSUriHandler.h"
#include "footstone/logging.h"

#include <objc/runtime.h>
#include <sys/utsname.h>
#include <string>

#ifdef ENABLE_INSPECTOR
#include "devtools/vfs/devtools_handler.h"
#include "devtools/devtools_data_source.h"
#endif


NSString *const _HippySDKVersion = @HIPPY_STR(HIPPY_VERSION);
NSString *const HippyReloadNotification = @"HippyReloadNotification";
NSString *const HippyJavaScriptWillStartLoadingNotification = @"HippyJavaScriptWillStartLoadingNotification";
NSString *const HippyJavaScripDidLoadSourceCodeNotification = @"HippyJavaScripDidLoadSourceCodeNotification";
NSString *const HippyJavaScriptDidLoadNotification = @"HippyJavaScriptDidLoadNotification";
NSString *const HippyJavaScriptDidFailToLoadNotification = @"HippyJavaScriptDidFailToLoadNotification";
NSString *const HippyDidInitializeModuleNotification = @"HippyDidInitializeModuleNotification";

NSString *const kHippyNotiBridgeKey = @"bridge";
NSString *const kHippyNotiBundleUrlKey = @"bundleURL";
NSString *const kHippyNotiBundleTypeKey = @"bundleType";
NSString *const kHippyNotiErrorKey = @"error";

const NSUInteger HippyBridgeBundleTypeVendor = 1;
const NSUInteger HippyBridgeBundleTypeBusiness = 2;


static NSString *const HippyNativeGlobalKeyOS = @"OS";
static NSString *const HippyNativeGlobalKeyOSVersion = @"OSVersion";
static NSString *const HippyNativeGlobalKeyDevice = @"Device";
static NSString *const HippyNativeGlobalKeySDKVersion = @"SDKVersion";
static NSString *const HippyNativeGlobalKeyAppVersion = @"AppVersion";
static NSString *const HippyNativeGlobalKeyDimensions = @"Dimensions";
static NSString *const HippyNativeGlobalKeyLocalization = @"Localization";
static NSString *const HippyNativeGlobalKeyNightMode = @"NightMode";

// key of module config info for js side
static NSString *const kHippyRemoteModuleConfigKey = @"remoteModuleConfig";
static NSString *const kHippyBatchedBridgeConfigKey = @"__hpBatchedBridgeConfig";


typedef NS_ENUM(NSUInteger, HippyBridgeFields) {
    HippyBridgeFieldRequestModuleIDs = 0,
    HippyBridgeFieldMethodIDs,
    HippyBridgeFieldParams,
    HippyBridgeFieldCallID,
};

/// Set the log delegate for hippy core module
static inline void registerLogDelegateToHippyCore() {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        footstone::LogMessage::InitializeDelegate([](const std::ostringstream& stream, footstone::LogSeverity severity) {
            HippyLogLevel logLevel = HippyLogLevelInfo;
            
            switch (severity) {
                case footstone::TDF_LOG_INFO:
                    logLevel = HippyLogLevelInfo;
                    break;
                case footstone::TDF_LOG_WARNING:
                    logLevel = HippyLogLevelWarning;
                    break;
                case footstone::TDF_LOG_ERROR:
                    logLevel = HippyLogLevelError;
                    break;
                case footstone::TDF_LOG_FATAL:
                    logLevel = HippyLogLevelFatal;
                    break;
                default:
                    break;
            }
            HippyLogNativeInternal(logLevel, "tdf", 0, @"%s", stream.str().c_str());
        });
    });
}


@interface HippyBridge() {
    __weak id<HippyMethodInterceptorProtocol> _methodInterceptor;
    HippyModulesSetup *_moduleSetup;
    __weak NSOperation *_lastOperation;
    BOOL _wasBatchActive;
    HippyDisplayLink *_displayLink;
    HippyBridgeModuleProviderBlock _moduleProvider;
    BOOL _valid;
    HippyBundleOperationQueue *_bundlesQueue;
    NSMutableArray<NSURL *> *_bundleURLs;
    
    std::shared_ptr<VFSUriLoader> _uriLoader;
    std::shared_ptr<hippy::RootNode> _rootNode;
    
    // The C++ version of RenderManager instance, bridge holds,
    // One NativeRenderManager holds multiple UIManager instance.
    std::shared_ptr<NativeRenderManager> _renderManager;
    
    // 缓存的设备信息
    NSDictionary *_cachedDeviceInfo;
}

/// 用于标记bridge所使用的JS引擎的Key
///
/// 注意：传入相同值的bridge将共享底层JS引擎。
/// 在共享情况下，只有全部bridge实例均释放，JS引擎资源才会销毁。
/// 默认情况下对每个bridge使用独立JS引擎
@property (nonatomic, strong) NSString *engineKey;
/// 等待加载(Load)的 Vendor bundleURL
@property (nonatomic, strong) NSURL *pendingLoadingVendorBundleURL;

@property(readwrite, strong) dispatch_semaphore_t moduleSemaphore;
@property(readwrite, assign) NSInteger loadingCount;


/// 缓存的Dimensions信息，用于传递给JS Side
@property (atomic, strong) NSDictionary *cachedDimensionsInfo;

@end

@implementation HippyBridge

@synthesize imageLoader = _imageLoader;
@synthesize imageProviders = _imageProviders;
@synthesize startTime = _startTime;

dispatch_queue_t HippyJSThread;

dispatch_queue_t HippyBridgeQueue() {
    static dispatch_once_t onceToken;
    static dispatch_queue_t queue;
    dispatch_once(&onceToken, ^{
        dispatch_queue_attr_t attr =
            dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0);
        queue = dispatch_queue_create("com.hippy.bridge", attr);
    });
    return queue;
}

+ (void)initialize {
    [super initialize];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Set up JS thread
        HippyJSThread = (id)kCFNull;
    });
}

- (instancetype)initWithDelegate:(id<HippyBridgeDelegate>)delegate
                  moduleProvider:(HippyBridgeModuleProviderBlock)block
                   launchOptions:(NSDictionary *)launchOptions
                     executorKey:(nullable NSString *)executorKey {
    return [self initWithDelegate:delegate
                        bundleURL:nil
                   moduleProvider:block
                    launchOptions:launchOptions
                      executorKey:executorKey];
}

- (instancetype)initWithDelegate:(id<HippyBridgeDelegate>)delegate
                       bundleURL:(NSURL *)bundleURL
                  moduleProvider:(HippyBridgeModuleProviderBlock)block
                   launchOptions:(NSDictionary *)launchOptions
                     executorKey:(nullable NSString *)executorKey {
    if (self = [super init]) {
        _delegate = delegate;
        _moduleProvider = block;
        _pendingLoadingVendorBundleURL = bundleURL;
        _bundleURLs = [NSMutableArray array];
        _shareOptions = [NSMutableDictionary dictionary];
        _debugMode = [launchOptions[@"DebugMode"] boolValue];
        _enableTurbo = !!launchOptions[@"EnableTurbo"] ? [launchOptions[@"EnableTurbo"] boolValue] : YES;
        _engineKey = executorKey.length > 0 ? executorKey : [NSString stringWithFormat:@"%p", self];
        _bundlesQueue = [[HippyBundleOperationQueue alloc] init];
        
        HippyLogInfo(@"HippyBridge init begin, self:%p", self);
        
        // Set the log delegate for hippy core module
        registerLogDelegateToHippyCore();
        
        // Setup
        [self setUp];
        
        // Record bridge instance for RedBox (Debug Only)
        [HippyBridge setCurrentBridge:self];
        HippyLogInfo(@"HippyBridge init end, self:%p", self);
    }
    return self;
}

- (void)dealloc {
    HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],%@ dealloc %p", NSStringFromClass([self class]), self);
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    self.invalidateReason = HippyInvalidateReasonDealloc;
    [self invalidate];
    
    if (_uriLoader) {
        _uriLoader->Terminate();
    }
    if (_renderManager) {
        _renderManager->RemoveVSyncEventListener(_rootNode);
    }
    if (_rootNode) {
        _rootNode->ReleaseResources();
    }
}

- (std::shared_ptr<VFSUriLoader>)createURILoaderIfNeeded {
    if (!_uriLoader) {
        auto uriHandler = std::make_shared<VFSUriHandler>();
        auto uriLoader = std::make_shared<VFSUriLoader>();
        uriLoader->PushDefaultHandler(uriHandler);
        uriLoader->AddConvenientDefaultHandler(uriHandler);
        auto fileHandler = std::make_shared<HippyFileHandler>(self);
        auto base64DataHandler = std::make_shared<HippyBase64DataHandler>();
        uriLoader->RegisterConvenientUriHandler(@"file", fileHandler);
        uriLoader->RegisterConvenientUriHandler(@"hpfile", fileHandler);
        uriLoader->RegisterConvenientUriHandler(@"data", base64DataHandler);
        _uriLoader = uriLoader;
    }
    return _uriLoader;
}


#pragma mark - Module Management

- (NSArray<Class> *)moduleClasses {
    return _moduleSetup.moduleClasses;
}

- (id)moduleForName:(NSString *)moduleName {
    return [_moduleSetup moduleForName:moduleName];
}

- (id)moduleForClass:(Class)moduleClass {
    return [_moduleSetup moduleForClass:moduleClass];
}

- (HippyModuleData *)moduleDataForName:(NSString *)moduleName {
    if (moduleName) {
        return _moduleSetup.moduleDataByName[moduleName];
    }
    return nil;
}

- (NSArray *)modulesConformingToProtocol:(Protocol *)protocol {
    NSMutableArray *modules = [NSMutableArray new];
    for (Class moduleClass in self.moduleClasses) {
        if ([moduleClass conformsToProtocol:protocol]) {
            id module = [self moduleForClass:moduleClass];
            if (module) {
                [modules addObject:module];
            }
        }
    }
    return [modules copy];
}

- (BOOL)moduleIsInitialized:(Class)moduleClass {
    return [_moduleSetup isModuleInitialized:moduleClass];
}

- (BOOL)moduleSetupComplete {
    return _moduleSetup.isModuleSetupComplete;
}

- (NSDictionary *)nativeModuleConfig {
    NSMutableArray<NSArray *> *config = [NSMutableArray new];
    for (HippyModuleData *moduleData in [_moduleSetup moduleDataByID]) {
        NSArray *moduleDataConfig = [moduleData config];
        [config addObject:HippyNullIfNil(moduleDataConfig)];
    }
    return @{ kHippyRemoteModuleConfigKey : config };
}

- (NSArray *)configForModuleName:(NSString *)moduleName {
    HippyModuleData *moduleData = [_moduleSetup moduleDataByName][moduleName];
    return moduleData.config;
}

- (HippyOCTurboModule *)turboModuleWithName:(NSString *)name {
    if (!self.enableTurbo || name.length <= 0) {
        return nil;
    }
    
    if (!self.turboModuleManager) {
        self.turboModuleManager = [[HippyTurboModuleManager alloc] initWithBridge:self];
    }
    return [self.turboModuleManager turboModuleWithName:name];
}


#pragma mark - Image Config Related

- (id<HippyImageCustomLoaderProtocol>)imageLoader {
    @synchronized (self) {
        if (!_imageLoader) {
            // Only the last imageloader takes effect,
            // compatible with Hippy 2.x
            _imageLoader = [[self modulesConformingToProtocol:@protocol(HippyImageCustomLoaderProtocol)] lastObject];
        }
    }
    return _imageLoader;
}

- (void)setCustomImageLoader:(id<HippyImageCustomLoaderProtocol>)imageLoader {
    @synchronized (self) {
        if (imageLoader != _imageLoader) {
            if (_imageLoader) {
                HippyLogWarn(@"ImageLoader change from %@ to %@", _imageLoader, imageLoader);
            }
            _imageLoader = imageLoader;
        }
    }
}

- (NSArray<Class<HippyImageProviderProtocol>> *)imageProviders {
    @synchronized (self) {
        if (!_imageProviders) {
            NSMutableArray *moduleClasses = [NSMutableArray new];
            for (Class moduleClass in self.moduleClasses) {
                if ([moduleClass conformsToProtocol:@protocol(HippyImageProviderProtocol)]) {
                    [moduleClasses addObject:moduleClass];
                }
            }
            _imageProviders = moduleClasses;
        }
        return [_imageProviders copy];
    }
}

- (void)addImageProviderClass:(Class<HippyImageProviderProtocol>)cls {
    HippyAssertParam(cls);
    @synchronized (self) {
        _imageProviders = [self.imageProviders arrayByAddingObject:cls];
    }
}

#pragma mark - Reload

- (void)requestReload {
    [[NSNotificationCenter defaultCenter] postNotificationName:HippyReloadNotification object:nil];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.invalidateReason = HippyInvalidateReasonReload;
        [self invalidate];
        [self setUp];
    });
}

#pragma mark - Bridge SetUp

- (void)setUp {
    _valid = YES;
    _startTime = footstone::TimePoint::SystemNow();
    
    // Get global enviroment info
    HippyExecuteOnMainThread(^{
        self->_isOSNightMode = [HippyDeviceBaseInfo isUIScreenInOSDarkMode];
        self.cachedDimensionsInfo = hippyExportedDimensions(self);
    }, YES);
    
    self.moduleSemaphore = dispatch_semaphore_create(0);
    @try {
        __weak HippyBridge *weakSelf = self;
        _moduleSetup = [[HippyModulesSetup alloc] initWithBridge:self extraProviderModulesBlock:_moduleProvider];
        _javaScriptExecutor = [[HippyJSExecutor alloc] initWithEngineKey:self.engineKey bridge:self];
        
        _javaScriptExecutor.contextCreatedBlock = ^(){
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            dispatch_semaphore_t moduleSemaphore = strongSelf.moduleSemaphore;
            if (strongSelf.isValid && moduleSemaphore) {
                dispatch_semaphore_wait(moduleSemaphore, DISPATCH_TIME_FOREVER);
                NSDictionary *nativeModuleConfig = [strongSelf nativeModuleConfig];
                [strongSelf.javaScriptExecutor injectObjectSync:nativeModuleConfig
                                            asGlobalObjectNamed:kHippyBatchedBridgeConfigKey callback:nil];
#if HIPPY_DEV
                //default is yes when debug mode
                [strongSelf setInspectable:YES];
#endif //HIPPY_DEV
            }
        };
        [_javaScriptExecutor setup];
        if (_contextName) {
            _javaScriptExecutor.contextName = _contextName;
        }
        _displayLink = [[HippyDisplayLink alloc] init];
        
        // Setup all extra and internal modules
        [_moduleSetup setupModulesWithCompletionBlock:^{
            HippyBridge *strongSelf = weakSelf;
            if (strongSelf) {
                dispatch_semaphore_signal(strongSelf.moduleSemaphore);
            }
        }];
        
    } @catch (NSException *exception) {
        HippyBridgeHandleException(exception, self);
    }
    
    [self addImageProviderClass:[HippyDefaultImageProvider class]];
    [self setVfsUriLoader:[self createURILoaderIfNeeded]];
    
    // Load pending js bundles
    [self loadPendingVendorBundleURLIfNeeded];
    
    // Set the default sandbox directory
    NSString *sandboxDir = [HippyUtils getBaseDirFromResourcePath:_pendingLoadingVendorBundleURL];
    [self setSandboxDirectory:sandboxDir];

}

/// 加载初始化bridge时传入的Bundle URL
- (void)loadPendingVendorBundleURLIfNeeded {
    if (self.pendingLoadingVendorBundleURL) {
        [self loadBundleURL:self.pendingLoadingVendorBundleURL 
                 bundleType:HippyBridgeBundleTypeVendor
                 completion:^(NSURL * _Nullable bundleURL, NSError * _Nullable error) {
            if (error) {
                HippyLogError(@"[Hippy_OC_Log][HippyBridge], bundle loaded error:%@, %@", bundleURL, error.description);
            } else {
                HippyLogInfo(@"[Hippy_OC_Log][HippyBridge], bundle loaded success:%@", bundleURL);
            }
        }];
    }
}

#define BUNDLE_LOAD_NOTI_SUCCESS_USER_INFO \
    @{ kHippyNotiBridgeKey: strongSelf, \
       kHippyNotiBundleUrlKey: bundleURL, \
       kHippyNotiBundleTypeKey : @(bundleType) }

#define BUNDLE_LOAD_NOTI_ERROR_USER_INFO \
    @{ kHippyNotiBridgeKey: strongSelf, \
       kHippyNotiBundleUrlKey: bundleURL, \
       kHippyNotiBundleTypeKey : @(bundleType), \
       kHippyNotiErrorKey : error }

- (void)loadBundleURL:(NSURL *)bundleURL
           bundleType:(HippyBridgeBundleType)bundleType
           completion:(nonnull HippyBridgeBundleLoadCompletionBlock)completion {
    if (!bundleURL) {
        if (completion) {
            static NSString *bundleError = @"bundle url is nil";
            NSError *error = [NSError errorWithDomain:@"Bridge Bundle Loading Domain" 
                                                 code:1
                                             userInfo:@{NSLocalizedFailureReasonErrorKey: bundleError}];
            completion(nil, error);
        }
        return;
    }
    
    // bundleURL checking
    NSURLComponents *components = [NSURLComponents componentsWithURL:bundleURL resolvingAgainstBaseURL:NO];
    if (components.scheme == nil) {
        // If a given url has no scheme, it is considered a file url by default.
        components.scheme = @"file";
        bundleURL = components.URL;
    }
    
    HippyLogInfo(@"[HP PERF] Begin loading bundle(%s) at %s",
                 HP_CSTR_NOT_NULL(bundleURL.absoluteString.lastPathComponent.UTF8String),
                 HP_CSTR_NOT_NULL(bundleURL.absoluteString.UTF8String));
    [_bundleURLs addObject:bundleURL];
    
    __weak __typeof(self)weakSelf = self;
    dispatch_async(HippyBridgeQueue(), ^{
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        if (!strongSelf) {
            return;
        }
        NSDictionary *userInfo = BUNDLE_LOAD_NOTI_SUCCESS_USER_INFO;
        [[NSNotificationCenter defaultCenter] postNotificationName:HippyJavaScriptWillStartLoadingNotification
                                                            object:strongSelf
                                                          userInfo:userInfo];
        [strongSelf beginLoadingBundle:bundleURL bundleType:bundleType completion:completion];
    });
}

- (void)beginLoadingBundle:(NSURL *)bundleURL
                bundleType:(HippyBridgeBundleType)bundleType
                completion:(HippyBridgeBundleLoadCompletionBlock)completion {
    dispatch_group_t group = dispatch_group_create();
    __weak HippyBridge *weakSelf = self;
    __block NSData *script = nil;
    self.loadingCount++;
    dispatch_group_enter(group);
    NSOperationQueue *bundleQueue = [[NSOperationQueue alloc] init];
    bundleQueue.maxConcurrentOperationCount = 1;
    bundleQueue.name = @"com.hippy.bundleQueue";
    HippyBundleLoadOperation *fetchOp = [[HippyBundleLoadOperation alloc] initWithBridge:self
                                                                               bundleURL:bundleURL
                                                                                   queue:bundleQueue];
    fetchOp.onLoad = ^(NSData *source, NSError *error) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        if (!strongSelf) {
            dispatch_group_leave(group);
            return;
        }
        NSDictionary *userInfo;
        if (error) {
            HippyBridgeFatal(error, weakSelf);
            userInfo = BUNDLE_LOAD_NOTI_ERROR_USER_INFO;
        } else {
            script = source;
            userInfo = BUNDLE_LOAD_NOTI_SUCCESS_USER_INFO;
        }
        [[NSNotificationCenter defaultCenter] postNotificationName:HippyJavaScripDidLoadSourceCodeNotification
                                                            object:strongSelf
                                                          userInfo:userInfo];
        dispatch_group_leave(group);
    };
    
    dispatch_group_enter(group);
    HippyBundleExecutionOperation *executeOp = [[HippyBundleExecutionOperation alloc] initWithBlock:^{
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.valid) {
            dispatch_group_leave(group);
            return;
        }
        __weak __typeof(strongSelf)weakSelf = strongSelf;
        [strongSelf executeJSCode:script sourceURL:bundleURL onCompletion:^(id result, NSError *error) {
            __strong __typeof(weakSelf)strongSelf = weakSelf;
            HippyLogInfo(@"End loading bundle(%s) at %s",
                         HP_CSTR_NOT_NULL(bundleURL.absoluteString.lastPathComponent.UTF8String),
                         HP_CSTR_NOT_NULL(bundleURL.absoluteString.UTF8String));

            if (completion) {
                completion(bundleURL, error);
            }
            if (!strongSelf || !strongSelf.valid) {
                dispatch_group_leave(group);
                return;
            }
            if (error) {
                HippyBridgeFatal(error, strongSelf);
            }
            __weak __typeof(self)weakSelf = strongSelf;
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                NSNotificationName notiName;
                NSDictionary *userInfo;
                if (error) {
                    notiName = HippyJavaScriptDidFailToLoadNotification;
                    userInfo = BUNDLE_LOAD_NOTI_ERROR_USER_INFO;
                } else {
                    notiName = HippyJavaScriptDidLoadNotification;
                    userInfo = BUNDLE_LOAD_NOTI_SUCCESS_USER_INFO;
                }
                [[NSNotificationCenter defaultCenter] postNotificationName:notiName
                                                                    object:strongSelf
                                                                  userInfo:userInfo];
            });
            dispatch_group_leave(group);
        }];
    } queue:bundleQueue];
    
    //set dependency
    [executeOp addDependency:fetchOp];
    if (_lastOperation) {
        [executeOp addDependency:_lastOperation];
        _lastOperation = executeOp;
    } else {
        _lastOperation = executeOp;
    }
    [_bundlesQueue addOperations:@[fetchOp, executeOp]];
    dispatch_block_t completionBlock = ^(void){
        HippyBridge *strongSelf = weakSelf;
        if (strongSelf && strongSelf.isValid) {
            strongSelf.loadingCount--;
        }
    };
    dispatch_group_notify(group, HippyBridgeQueue(), completionBlock);
}

- (void)unloadInstanceForRootView:(NSNumber *)rootTag {
    if (rootTag) {
        NSDictionary *param = @{@"id": rootTag};
        footstone::value::HippyValue value = [param toHippyValue];
        std::shared_ptr<footstone::value::HippyValue> domValue = std::make_shared<footstone::value::HippyValue>(value);
        if (auto scope = self.javaScriptExecutor.pScope) {
            scope->UnloadInstance(domValue);
        }
        if (_renderManager) {
            _renderManager->UnregisterRootView([rootTag intValue]);
        }
        if (_rootNode) {
            _rootNode->ReleaseResources();
            _rootNode = nullptr;
        }
    }
}

- (void)loadInstanceForRootView:(NSNumber *)rootTag withProperties:(NSDictionary *)props {
    [self innerLoadInstanceForRootView:rootTag withProperties:props];
}

- (void)innerLoadInstanceForRootView:(NSNumber *)rootTag withProperties:(NSDictionary *)props {
    HippyAssert(_moduleName, @"module name must not be null");
    HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],Running application %@ (%@)", _moduleName, props);
    HippyLogInfo(@"[HP PERF] Begin loading instance for HippyBridge(%p)", self);
    NSDictionary *param = @{@"name": _moduleName,
                            @"id": rootTag,
                            @"params": props ?: @{},
                            @"version": _HippySDKVersion};
    footstone::value::HippyValue value = [param toHippyValue];
    std::shared_ptr<footstone::value::HippyValue> domValue = std::make_shared<footstone::value::HippyValue>(value);
    self.javaScriptExecutor.pScope->LoadInstance(domValue);
    HippyLogInfo(@"[HP PERF] End loading instance for HippyBridge(%p)", self);
}

- (void)setVfsUriLoader:(std::weak_ptr<VFSUriLoader>)uriLoader {
    [_javaScriptExecutor setUriLoader:uriLoader];
#ifdef ENABLE_INSPECTOR
    auto devtools_data_source = _javaScriptExecutor.pScope->GetDevtoolsDataSource();
    auto strongLoader = uriLoader.lock();
    if (devtools_data_source && strongLoader) {
        auto notification = devtools_data_source->GetNotificationCenter()->network_notification;
        auto devtools_handler = std::make_shared<hippy::devtools::DevtoolsHandler>();
        devtools_handler->SetNetworkNotification(notification);
        strongLoader->RegisterUriInterceptor(devtools_handler);
    }
#endif
}

- (std::weak_ptr<VFSUriLoader>)vfsUriLoader {
    return _uriLoader;
}

- (void)setInspectable:(BOOL)isInspectable {
    [self.javaScriptExecutor setInspecable:isInspectable];
}


#pragma mark - Private

/// Execute JS Bundle
- (void)executeJSCode:(NSData *)script
            sourceURL:(NSURL *)sourceURL
         onCompletion:(HippyJavaScriptCallback)completion {
    if (!script) {
        completion(nil, HippyErrorWithMessageAndModuleName(@"no valid data", _moduleName));
        return;
    }
    if (![self isValid] || !script || !sourceURL) {
        completion(nil, HippyErrorWithMessageAndModuleName(@"bridge is not valid", _moduleName));
        return;
    }
    HippyAssert(self.javaScriptExecutor, @"js executor must not be null");
    __weak __typeof(self)weakSelf = self;
    [self.javaScriptExecutor executeApplicationScript:script sourceURL:sourceURL onComplete:^(id result ,NSError *error) {
        __strong __typeof(weakSelf)strongSelf = weakSelf;
        if (!strongSelf || ![strongSelf isValid]) {
            completion(result, error);
            return;
        }
        if (error) {
            HippyLogError(@"ExecuteApplicationScript Error! %@", error.description);
            HippyExecuteOnMainQueue(^{
                __strong __typeof(weakSelf)strongSelf = weakSelf;
                [strongSelf stopLoadingWithError:error scriptSourceURL:sourceURL];
            });
        }
        completion(result, error);
    }];
}

- (void)stopLoadingWithError:(NSError *)error scriptSourceURL:(NSURL *)sourceURL {
    HippyAssertMainQueue();
    if (![self isValid]) {
        return;
    }
    __weak HippyBridge *weakSelf = self;
    [self.javaScriptExecutor executeBlockOnJavaScriptQueue:^{
        @autoreleasepool {
            HippyBridge *strongSelf = weakSelf;
            if (!strongSelf || ![strongSelf isValid]) {
                [strongSelf.javaScriptExecutor invalidate];
            }
        }
    }];
    if ([error userInfo][HippyJSStackTraceKey]) {
        [self.redBox showErrorMessage:[error localizedDescription] withStack:[error userInfo][HippyJSStackTraceKey]];
    }
}

- (void)enqueueJSCall:(NSString *)module method:(NSString *)method
                 args:(NSArray *)args completion:(dispatch_block_t)completion {
    /**
     * AnyThread
     */
    if (![self isValid]) {
        return;
    }
    [self actuallyInvokeAndProcessModule:module method:method arguments:args ?: @[]];
    if (completion) {
        completion();
    }
}

- (void)actuallyInvokeAndProcessModule:(NSString *)module method:(NSString *)method arguments:(NSArray *)args {
    __weak HippyBridge *weakSelf = self;
    [_javaScriptExecutor callFunctionOnModule:module method:method arguments:args callback:^(id json, NSError *error) {
        HippyBridge *strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf processResponse:json error:error];
        }
    }];
}

- (void)dispatchBlock:(dispatch_block_t)block queue:(dispatch_queue_t)queue {
    if (HippyJSThread == queue) {
        [_javaScriptExecutor executeBlockOnJavaScriptQueue:block];
    } else {
        dispatch_async(queue, block);
    }
}

- (void)processResponse:(id)json error:(NSError *)error {
    if (error) {
        if ([error userInfo][HippyJSStackTraceKey]) {
            if (error.localizedFailureReason) {
                [self.redBox
                    showErrorMessage:[NSString stringWithFormat:@"%@ 【reason】%@:", error.localizedDescription, error.localizedFailureReason]
                           withStack:[error userInfo][HippyJSStackTraceKey]];
            } else {
                [self.redBox showErrorMessage:[NSString stringWithFormat:@"%@", error.localizedDescription]
                                    withStack:[error userInfo][HippyJSStackTraceKey]];
            }
        }
        NSError *retError = HippyErrorFromErrorAndModuleName(error, self.moduleName);
        HippyBridgeFatal(retError, self);
    }

    if (![self isValid]) {
        return;
    }
    [self handleBuffer:json batchEnded:YES];
}

- (void)handleBuffer:(id)buffer batchEnded:(BOOL)batchEnded {
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

- (void)partialBatchDidFlush {
    NSArray<HippyModuleData *> *moduleDataByID = [_moduleSetup moduleDataByID];
    for (HippyModuleData *moduleData in moduleDataByID) {
        if (moduleData.hasInstance && moduleData.implementsPartialBatchDidFlush) {
            [self dispatchBlock:^{
                @autoreleasepool {
                    [moduleData.instance partialBatchDidFlush];
                }
            } queue:moduleData.methodQueue];
        }
    }
}

- (void)batchDidComplete {
    NSArray<HippyModuleData *> *moduleDataByID = [_moduleSetup moduleDataByID];
    for (HippyModuleData *moduleData in moduleDataByID) {
        if (moduleData.hasInstance && moduleData.implementsBatchDidComplete) {
            [self dispatchBlock:^{
                @autoreleasepool {
                    [moduleData.instance batchDidComplete];
                }
            } queue:moduleData.methodQueue];
        }
    }
}

- (void)handleBuffer:(NSArray *)buffer {
    NSArray *requestsArray = [HippyConvert NSArray:buffer];

    if (HIPPY_DEBUG && requestsArray.count <= HippyBridgeFieldParams) {
        HippyLogError(@"Buffer should contain at least %tu sub-arrays. Only found %tu", HippyBridgeFieldParams + 1, requestsArray.count);
        return;
    }

    NSArray<NSNumber *> *moduleIDs = [HippyConvert NSNumberArray:requestsArray[HippyBridgeFieldRequestModuleIDs]];
    NSArray<NSNumber *> *methodIDs = [HippyConvert NSNumberArray:requestsArray[HippyBridgeFieldMethodIDs]];
    NSArray<NSArray *> *paramsArrays = [HippyConvert NSArrayArray:requestsArray[HippyBridgeFieldParams]];

    int64_t callID = -1;

    if (requestsArray.count > 3) {
        callID = [requestsArray[HippyBridgeFieldCallID] longLongValue];
    }

    if (HIPPY_DEBUG && (moduleIDs.count != methodIDs.count || moduleIDs.count != paramsArrays.count)) {
        HippyLogError(@"Invalid data message - all must be length: %lu", (unsigned long)moduleIDs.count);
        return;
    }

    @autoreleasepool {
        NSDictionary<NSString *, HippyModuleData *> *moduleDataByName = [_moduleSetup moduleDataByName];
        NSArray<HippyModuleData *> *moduleDataById = [_moduleSetup moduleDataByID];
        NSMapTable *buckets =
            [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory
                                      valueOptions:NSPointerFunctionsStrongMemory
                                          capacity:[moduleDataByName count]];
        [moduleIDs enumerateObjectsUsingBlock:^(NSNumber *moduleID, NSUInteger i, __unused BOOL *stop) {
            HippyModuleData *moduleData = moduleDataById[moduleID.integerValue];
            dispatch_queue_t queue = moduleData.methodQueue;
            NSMutableOrderedSet<NSNumber *> *set = [buckets objectForKey:queue];
            if (!set) {
                set = [NSMutableOrderedSet new];
                [buckets setObject:set forKey:queue];
            }
            [set addObject:@(i)];
        }];

        for (dispatch_queue_t queue in buckets) {
            __weak id weakSelf = self;
            dispatch_block_t block = ^{
                @autoreleasepool {
                    id strongSelf = weakSelf;
                    if (!strongSelf) {
                        return;
                    }
                    NSOrderedSet *calls = [buckets objectForKey:queue];
                    for (NSNumber *indexObj in calls) {
                        NSUInteger index = indexObj.unsignedIntegerValue;
                        [strongSelf callNativeModule:[moduleIDs[index] integerValue]
                                              method:[methodIDs[index] integerValue]
                                              params:paramsArrays[index]];
                    }
                }
            };
            [self dispatchBlock:block queue:queue];
        }
    }
}

- (id)callNativeModule:(NSUInteger)moduleID method:(NSUInteger)methodID params:(NSArray *)params {
    // hippy will send 'destroyInstance' event to JS.
    // JS may call actions after that.
    // so HippyBatchBridge needs to be valid
    //    if (!_valid) {
    //        return nil;
    //    }
    BOOL isValid = [self isValid];
    NSArray<HippyModuleData *> *moduleDataByID = [_moduleSetup moduleDataByID];
    if (moduleID >= [moduleDataByID count]) {
        if (isValid) {
            HippyLogError(@"moduleID %lu exceed range of moduleDataByID %lu, bridge is valid %ld", moduleID, [moduleDataByID count], (long)isValid);
        }
        return nil;
    }
    HippyModuleData *moduleData = moduleDataByID[moduleID];
    if (HIPPY_DEBUG && !moduleData) {
        if (isValid) {
            HippyLogError(@"No module found for id '%lu'", (unsigned long)moduleID);
        }
        return nil;
    }
    // not for UI Actions if NO==_valid
    if (!isValid) {
        if ([[moduleData name] isEqualToString:@"UIManager"]) {
            return nil;
        }
    }
    NSArray<id<HippyBridgeMethod>> *methods = [moduleData.methods copy];
    if (methodID >= [methods count]) {
        if (isValid) {
            HippyLogError(@"methodID %lu exceed range of moduleData.methods %lu, bridge is valid %ld", moduleID, [methods count], (long)isValid);
        }
        return nil;
    }
    id<HippyBridgeMethod> method = methods[methodID];
    if (HIPPY_DEBUG && !method) {
        if (isValid) {
            HippyLogError(@"Unknown methodID: %lu for module: %lu (%@)", (unsigned long)methodID, (unsigned long)moduleID, moduleData.name);
        }
        return nil;
    }

    @try {
        BOOL shouldInvoked = YES;
        if ([self.methodInterceptor respondsToSelector:@selector(shouldInvokeWithModuleName:methodName:arguments:argumentsValues:containCallback:)]) {
            HippyFunctionType funcType = [method functionType];
            BOOL containCallback = (HippyFunctionTypeCallback == funcType|| HippyFunctionTypePromise == funcType);
            NSArray<id<HippyBridgeArgument>> *arguments = [method arguments];
            shouldInvoked = [self.methodInterceptor shouldInvokeWithModuleName:moduleData.name
                                                                    methodName:method.JSMethodName
                                                                     arguments:arguments
                                                               argumentsValues:params
                                                               containCallback:containCallback];
        }
        if (shouldInvoked) {
            return [method invokeWithBridge:self module:moduleData.instance arguments:params];
        }
        else {
            return nil;
        }
    } @catch (NSException *exception) {
        // Pass on JS exceptions
        if ([exception.name hasPrefix:HippyFatalExceptionName]) {
            @throw exception;
        }

        NSString *message = [NSString stringWithFormat:@"Exception '%@' was thrown while invoking %@ on target %@ with params %@", exception, method.JSMethodName, moduleData.name, params];
        NSError *error = HippyErrorWithMessageAndModuleName(message, self.moduleName);
        HippyBridgeFatal(error, self);
        return nil;
    }
}

- (id)callNativeModuleName:(NSString *)moduleName methodName:(NSString *)methodName params:(NSArray *)params {
    NSDictionary<NSString *, HippyModuleData *> *moduleByName = [_moduleSetup moduleDataByName];
    HippyModuleData *module = moduleByName[moduleName];
    if (!module) {
        return nil;
    }
    id<HippyBridgeMethod> method = module.methodsByName[methodName];
    if (!method) {
        return nil;
    }
    @try {
        return [method invokeWithBridge:self module:module.instance arguments:params];
    } @catch (NSException *exception) {
        if ([exception.name hasPrefix:HippyFatalExceptionName]) {
            @throw exception;
        }

        NSString *message = [NSString stringWithFormat:@"Exception '%@' was thrown while invoking %@ on target %@ with params %@", exception, method.JSMethodName, module.name, params];
        NSError *error = HippyErrorWithMessageAndModuleName(message, self.moduleName);
        HippyBridgeFatal(error, self);
        return nil;
    }
}

- (void)setMethodInterceptor:(id<HippyMethodInterceptorProtocol>)methodInterceptor {
    _methodInterceptor = methodInterceptor;
}

- (id<HippyMethodInterceptorProtocol>)methodInterceptor {
    return _methodInterceptor;
}

- (void)setupDomManager:(std::shared_ptr<hippy::DomManager>)domManager
                  rootNode:(std::weak_ptr<hippy::RootNode>)rootNode {
    HippyAssertParam(domManager);
    if (!domManager) {
        return;
    }
    self.javaScriptExecutor.pScope->SetDomManager(domManager);
    self.javaScriptExecutor.pScope->SetRootNode(rootNode);
#ifdef ENABLE_INSPECTOR
    auto devtools_data_source = self.javaScriptExecutor.pScope->GetDevtoolsDataSource();
    if (devtools_data_source) {
        self.javaScriptExecutor.pScope->GetDevtoolsDataSource()->Bind(domManager);
        devtools_data_source->SetRootNode(rootNode);
    }
#endif
}

- (BOOL)isValid {
    return _valid;
}

- (BOOL)isLoading {
    NSUInteger count = self.loadingCount;
    return 0 == count;
}

- (void)invalidate {
    HippyLogInfo(@"[Hippy_OC_Log][Life_Circle],%@ invalide %p", NSStringFromClass([self class]), self);
    if (![self isValid]) {
        return;
    }
    _valid = NO;
    [_bundleURLs removeAllObjects];
    if ([self.delegate respondsToSelector:@selector(invalidateForReason:bridge:)]) {
        [self.delegate invalidateForReason:self.invalidateReason bridge:self];
    }
    // Invalidate modules
    dispatch_group_t group = dispatch_group_create();
    for (HippyModuleData *moduleData in [_moduleSetup moduleDataByID]) {
        // Be careful when grabbing an instance here, we don't want to instantiate
        // any modules just to invalidate them.
        id<HippyBridgeModule> instance = nil;
        if ([moduleData hasInstance]) {
            instance = moduleData.instance;
        }
        if ([instance respondsToSelector:@selector(invalidate)]) {
            dispatch_group_enter(group);
            [self dispatchBlock:^{
                @autoreleasepool {
                    [(id<HippyInvalidating>)instance invalidate];
                }
                dispatch_group_leave(group);
            } queue:moduleData.methodQueue];
        }
        [moduleData invalidate];
    }
    id displayLink = _displayLink;
    id jsExecutor = _javaScriptExecutor;
    id moduleSetup = _moduleSetup;
    _displayLink = nil;
    _moduleSetup = nil;
    _startTime = footstone::TimePoint::SystemNow();
    
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        [jsExecutor executeBlockOnJavaScriptQueue:^{
            @autoreleasepool {
                [displayLink invalidate];
                [jsExecutor invalidate];
                [moduleSetup invalidate];
            }
        }];
    });
}

- (void)enqueueJSCall:(NSString *)moduleDotMethod args:(NSArray *)args {
    NSArray<NSString *> *ids = [moduleDotMethod componentsSeparatedByString:@"."];
    NSString *module = ids[0];
    NSString *method = ids[1];
    [self enqueueJSCall:module method:method args:args completion:NULL];
}

- (void)enqueueCallback:(NSNumber *)cbID args:(NSArray *)args {
    /**
     * AnyThread
     */
    if (!_valid) {
        return;
    }
    [self actuallyInvokeCallback:cbID arguments:args];
}

- (void)actuallyInvokeCallback:(NSNumber *)cbID arguments:(NSArray *)args {
    __weak __typeof(self) weakSelf = self;
    [_javaScriptExecutor invokeCallbackID:cbID arguments:args callback:^(id json, NSError *error) {
        [weakSelf processResponse:json error:error];
    }];
}


#pragma mark - DeviceInfo

- (NSDictionary *)genRawDeviceInfoDict {
    // This method may be called from a child thread
    NSString *iosVersion = [[UIDevice currentDevice] systemVersion];
    struct utsname systemInfo;
    uname(&systemInfo);
    NSString *deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    NSMutableDictionary *deviceInfo = [NSMutableDictionary dictionary];
    [deviceInfo setValue:@"ios" forKey:HippyNativeGlobalKeyOS];
    [deviceInfo setValue:iosVersion forKey:HippyNativeGlobalKeyOSVersion];
    [deviceInfo setValue:deviceModel forKey:HippyNativeGlobalKeyDevice];
    [deviceInfo setValue:_HippySDKVersion forKey:HippyNativeGlobalKeySDKVersion];
    
    NSString *appVer = [[NSBundle.mainBundle infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    if (appVer) {
        [deviceInfo setValue:appVer forKey:HippyNativeGlobalKeyAppVersion];
    }
    
    if (self.cachedDimensionsInfo) {
        [deviceInfo setValue:self.cachedDimensionsInfo forKey:HippyNativeGlobalKeyDimensions];
    }
    
    NSString *countryCode = [[HippyI18nUtils sharedInstance] currentCountryCode];
    NSString *lanCode = [[HippyI18nUtils sharedInstance] currentAppLanguageCode];
    NSWritingDirection direction = [[HippyI18nUtils sharedInstance] writingDirectionForCurrentAppLanguage];
    NSDictionary *localizaitionInfo = @{
        @"country" : countryCode?:@"unknown",
        @"language" : lanCode?:@"unknown",
        @"direction" : @(direction)
    };
    [deviceInfo setValue:localizaitionInfo forKey:HippyNativeGlobalKeyLocalization];
    [deviceInfo setValue:@([self isOSNightMode]) forKey:HippyNativeGlobalKeyNightMode];
    return deviceInfo;
}

- (NSDictionary *)deviceInfo {
    @synchronized (self) {
        if (!_cachedDeviceInfo) {
            _cachedDeviceInfo = [self genRawDeviceInfoDict];
        }
        return _cachedDeviceInfo;
    }
}


#pragma mark -

static NSString *const hippyOnNightModeChangedEvent = @"onNightModeChanged";
static NSString *const hippyOnNightModeChangedParam1 = @"NightMode";
static NSString *const hippyOnNightModeChangedParam2 = @"RootViewTag";

- (void)setOSNightMode:(BOOL)isOSNightMode withRootViewTag:(nonnull NSNumber *)rootViewTag {
    _isOSNightMode = isOSNightMode;
    // Notify to JS Driver Side
    // 1. Update global object
    [self.javaScriptExecutor updateNativeInfoToHippyGlobalObject:@{ HippyNativeGlobalKeyNightMode: @(isOSNightMode) }];
    
    // 2. Send event
    NSDictionary *args = @{@"eventName": hippyOnNightModeChangedEvent,
                           @"extra": @{ hippyOnNightModeChangedParam1 : @(isOSNightMode),
                                        hippyOnNightModeChangedParam2 : rootViewTag } };
    [self.eventDispatcher dispatchEvent:@"EventDispatcher"
                             methodName:@"receiveNativeEvent" args:args];
}


#pragma mark -

- (void)setRedBoxShowEnabled:(BOOL)enabled {
#if HIPPY_DEBUG
    HippyRedBox *redBox = [self redBox];
    redBox.showEnabled = enabled;
#endif  // HIPPY_DEBUG
}

- (void)registerModuleForFrameUpdates:(id<HippyBridgeModule>)module withModuleData:(HippyModuleData *)moduleData {
    [_displayLink registerModuleForFrameUpdates:module withModuleData:moduleData];
}

- (void)setSandboxDirectory:(NSString *)sandboxDirectory {
    if (![_sandboxDirectory isEqual:sandboxDirectory]) {
        _sandboxDirectory = sandboxDirectory;
        if (sandboxDirectory) {
            [self.javaScriptExecutor setSandboxDirectory:sandboxDirectory];
        }
    }
}

- (NSArray<NSURL *> *)bundleURLs {
    return [_bundleURLs copy];
}

- (void)setContextName:(NSString *)contextName {
    if (![_contextName isEqualToString:contextName]) {
        _contextName = [contextName copy];
        [self.javaScriptExecutor setContextName:contextName];
    }
}

- (void)sendEvent:(NSString *)eventName params:(NSDictionary *_Nullable)params {
    [self.eventDispatcher dispatchEvent:@"EventDispatcher"
                             methodName:@"receiveNativeEvent"
                                   args:@{@"eventName": eventName, @"extra": params ? : @{}}];
}

- (NSData *)snapShotData {
    auto rootNode = _javaScriptExecutor.pScope->GetRootNode().lock();
    if (!rootNode) {
        return nil;
    }
    std::string data = hippy::DomManager::GetSnapShot(rootNode);
    return [NSData dataWithBytes:reinterpret_cast<const void *>(data.c_str()) length:data.length()];
}

- (void)setSnapShotData:(NSData *)data {
    auto domManager = _javaScriptExecutor.pScope->GetDomManager().lock();
    if (!domManager) {
        return;
    }
    auto rootNode = _javaScriptExecutor.pScope->GetRootNode().lock();
    if (!rootNode) {
        return;
    }
    std::string string(reinterpret_cast<const char *>([data bytes]), [data length]);
    domManager->SetSnapShot(rootNode, string);
}


#pragma mark -

- (void)setRootView:(UIView *)rootView {
    auto engineResource = [[HippyJSEnginesMapper defaultInstance] JSEngineResourceForKey:self.engineKey];
    auto domManager = engineResource->GetDomManager();
    NSNumber *rootTag = [rootView hippyTag];
    //Create a RootNode instance with a root tag
    _rootNode = std::make_shared<hippy::RootNode>([rootTag unsignedIntValue]);
    //Set RootNode for AnimationManager in RootNode
    _rootNode->GetAnimationManager()->SetRootNode(_rootNode);
    //Set DomManager for RootNode
    _rootNode->SetDomManager(domManager);
    //Set screen scale factor and size for Layout system in RooNode
    _rootNode->GetLayoutNode()->SetScaleFactor([UIScreen mainScreen].scale);
    _rootNode->SetRootSize(rootView.frame.size.width, rootView.frame.size.height);
    _rootNode->SetRootOrigin(rootView.frame.origin.x, rootView.frame.origin.y);
    
    // Create NativeRenderManager if needed
    auto renderManager = domManager->GetRenderManager().lock();
    std::shared_ptr<NativeRenderManager> nativeRenderManager;
    if (!renderManager) {
        // Register RenderManager to DomManager
        nativeRenderManager = std::make_shared<NativeRenderManager>(self.moduleName.UTF8String);
        domManager->SetRenderManager(nativeRenderManager);
    } else {
#ifdef HIPPY_EXPERIMENT_LAYER_OPTIMIZATION
        auto opRenderManager = std::static_pointer_cast<hippy::LayerOptimizedRenderManager>(renderManager);
        nativeRenderManager = std::static_pointer_cast<NativeRenderManager>(opRenderManager->GetInternalNativeRenderManager());
#else
        nativeRenderManager = std::static_pointer_cast<NativeRenderManager>(renderManager);
#endif /* HIPPY_EXPERIMENT_LAYER_OPTIMIZATION */
    }
    _renderManager = nativeRenderManager;
    
    // Create UIManager if needed and register it to NativeRenderManager
    // Note that one NativeRenderManager may have multiple UIManager,
    // and one UIManager may have multiple rootViews,
    // But one HippyBridge can only have one UIManager.
    HippyUIManager *uiManager = self.uiManager;
    if (!uiManager) {
        uiManager = [[HippyUIManager alloc] init];
        [uiManager setDomManager:domManager];
        [uiManager setBridge:self];
        self.uiManager = uiManager;
    }
    
    //bind rootview and root node
    _renderManager->RegisterRootView(rootView, _rootNode, uiManager);
    
    //setup necessary params for bridge
    [self setupDomManager:domManager rootNode:_rootNode];
}

- (void)resetRootSize:(CGSize)size {
    auto engineResource = [[HippyJSEnginesMapper defaultInstance] JSEngineResourceForKey:self.engineKey];
    std::weak_ptr<hippy::RootNode> rootNode = _rootNode;
    auto domManager = engineResource->GetDomManager();
    std::weak_ptr<hippy::DomManager> weakDomManager = domManager;
    std::vector<std::function<void()>> ops = {[rootNode, weakDomManager, size](){
        auto strongRootNode = rootNode.lock();
        auto strongDomManager = weakDomManager.lock();
        if (strongRootNode && strongDomManager) {
            if (std::abs(std::get<0>(strongRootNode->GetRootSize()) - size.width) < DBL_EPSILON &&
                std::abs(std::get<1>(strongRootNode->GetRootSize()) - size.height) < DBL_EPSILON) {
                return;
            }
            strongRootNode->SetRootSize(size.width, size.height);
            strongDomManager->DoLayout(strongRootNode);
            strongDomManager->EndBatch(strongRootNode);
        }
    }};
    domManager->PostTask(hippy::dom::Scene(std::move(ops)));
}

@end

void HippyBridgeFatal(NSError *error, HippyBridge *bridge) {
    HippyFatal(error);
}

void HippyBridgeHandleException(NSException *exception, HippyBridge *bridge) {
    HippyHandleException(exception);
}

