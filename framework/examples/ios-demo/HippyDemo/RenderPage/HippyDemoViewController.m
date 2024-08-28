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

#import "HippyDemoViewController.h"
#import "UIViewController+Title.h"
#import "HippyPageCache.h"
#import "DemoConfigs.h"

#import <hippy/HippyBridge.h>
#import <hippy/HippyRootView.h>
#import <hippy/HippyLog.h>
#import <hippy/HippyAssert.h>
#import <hippy/UIView+Hippy.h>
#import <hippy/HippyMethodInterceptorProtocol.h>


static NSString *formatLog(NSDate *timestamp, HippyLogLevel level, NSString *fileName, NSNumber *lineNumber, NSString *message) {
    static NSArray *logLevelMap;
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        logLevelMap = @[@"TRACE", @"INFO", @"WARN", @"ERROR", @"FATAL"];
        formatter = [NSDateFormatter new];
        formatter.dateFormat = formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    });

    NSString *levelStr = level < 0 || level > logLevelMap.count ? logLevelMap[1] : logLevelMap[level];

    if(fileName){
        return [[NSString alloc] initWithFormat:@"[%@][%@:%d][%@] %@",
                [formatter stringFromDate:timestamp],
                fileName.lastPathComponent,
                lineNumber.intValue,
                levelStr,
                message
        ];
    }else{
        return [[NSString alloc] initWithFormat:@"[%@]%@",
                [formatter stringFromDate:timestamp],
                message
        ];
    }
}

@interface HippyDemoViewController () <HippyMethodInterceptorProtocol, HippyBridgeDelegate, HippyRootViewDelegate> {
    DriverType _driverType;
    RenderType _renderType;
    BOOL _isDebugMode;
    NSURL *_debugURL;
    
    HippyBridge *_hippyBridge;
    HippyRootView *_hippyRootView;
    BOOL _fromCache;
}

@end

@implementation HippyDemoViewController

- (instancetype)initWithDriverType:(DriverType)driverType
                        renderType:(RenderType)renderType
                          debugURL:(NSURL *)debugURL
                       isDebugMode:(BOOL)isDebugMode {
    self = [super init];
    if (self) {
        _driverType = driverType;
        _renderType = renderType;
        _debugURL = debugURL;
        _isDebugMode = isDebugMode;
    }
    return self;
}

- (instancetype)initWithPageCache:(HippyPageCache *)pageCache {
    self = [super init];
    if (self) {
        _driverType = pageCache.driverType;
        _renderType = pageCache.renderType;
        _debugURL = pageCache.debugURL;
        _isDebugMode = pageCache.isDebugMode;
        _hippyRootView = pageCache.rootView;
        _hippyBridge = pageCache.hippyBridge;
        _fromCache = YES;
    }
    return self;
}

- (void)dealloc {
    [[HippyPageCacheManager defaultPageCacheManager] addPageCache:[self toPageCache]];
    NSLog(@"%@ dealloc", self.class);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setNavigationAreaBackground:[UIColor whiteColor]];
    [self setNavigationItemTitle:@"Demo"];
    
    [self registerLogFunction];
    
    if (_fromCache) {
        [self runHippyCache];
    } else {
        [self runHippyDemo];
    }
}

- (void)registerLogFunction {
    HippySetLogFunction(^(HippyLogLevel level, HippyLogSource source, NSString *fileName, NSNumber *lineNumber, NSString *message) {
        NSString *log = formatLog([NSDate date], level, fileName, lineNumber, message);
        if([log hasSuffix:@"\n"]){
            fprintf(stderr, "%s", log.UTF8String);
        }else{
            fprintf(stderr, "%s\n", log.UTF8String);
        }
    });
}

- (void)runHippyCache {
    _hippyRootView.frame = self.contentAreaView.bounds;
    [self.contentAreaView addSubview:_hippyRootView];
}

- (void)runHippyDemo {
    // Necessary configuration:
    NSString *moduleName = @"Demo";
    NSDictionary *launchOptions = @{ @"DebugMode": @(_isDebugMode) };
    NSDictionary *initialProperties = @{ @"isSimulator": @(TARGET_OS_SIMULATOR) };
    
    HippyBridge *bridge = nil;
    HippyRootView *rootView = nil;
    if (_isDebugMode) {
        bridge = [[HippyBridge alloc] initWithDelegate:self
                                             bundleURL:_debugURL
                                        moduleProvider:nil
                                         launchOptions:launchOptions
                                           executorKey:nil];
        rootView = [[HippyRootView alloc] initWithBridge:bridge
                                              moduleName:moduleName
                                       initialProperties:initialProperties
                                                delegate:self];
    } else {
        NSURL *vendorBundleURL = [self vendorBundleURL];
        NSURL *indexBundleURL = [self indexBundleURL];
        HippyBridge *bridge = [[HippyBridge alloc] initWithDelegate:self
                                                          bundleURL:vendorBundleURL
                                                     moduleProvider:nil
                                                      launchOptions:launchOptions
                                                        executorKey:nil];
        rootView = [[HippyRootView alloc] initWithBridge:bridge
                                             businessURL:indexBundleURL
                                              moduleName:moduleName
                                       initialProperties:initialProperties
                                                delegate:self];
    }
    
    bridge.methodInterceptor = self;
    [bridge setInspectable:YES];
    _hippyBridge = bridge;
    rootView.frame = self.contentAreaView.bounds;
    rootView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [self.contentAreaView addSubview:rootView];
    _hippyRootView = rootView;
}


#pragma mark -

- (NSURL *)vendorBundleURL {
    NSString *path = nil;
    if (DriverTypeReact == _driverType) {
        path = [[NSBundle mainBundle] pathForResource:@"vendor.ios" ofType:@"js" inDirectory:@"res/react"];
    }
    else if (DriverTypeVue == _driverType) {
        path = [[NSBundle mainBundle] pathForResource:@"vendor.ios" ofType:@"js" inDirectory:@"res/vue3"];
    }
    return [NSURL fileURLWithPath:path];
}

- (NSURL *)indexBundleURL {
    NSString *path = nil;
    if (DriverTypeReact == _driverType) {
        path = [[NSBundle mainBundle] pathForResource:@"index.ios" ofType:@"js" inDirectory:@"res/react"];
    }
    else if (DriverTypeVue == _driverType) {
        path = [[NSBundle mainBundle] pathForResource:@"index.ios" ofType:@"js" inDirectory:@"res/vue3"];
    }
    return [NSURL fileURLWithPath:path];
}

- (DriverType)driverType {
    return _driverType;
}

- (RenderType)renderType {
    return _renderType;
}

- (NSURL *)debugURL {
    return _debugURL;
}

- (BOOL)isDebugMode {
    return _isDebugMode;
}

- (void)removeRootView:(NSNumber *)rootTag bridge:(HippyBridge *)bridge {
    [[[self.contentAreaView subviews] firstObject] removeFromSuperview];
}

- (HippyPageCache *)toPageCache {
    HippyPageCache *pageCache = [[HippyPageCache alloc] init];
    pageCache.hippyBridge = _hippyBridge;
    pageCache.rootView = _hippyRootView;
    pageCache.driverType = _driverType;
    pageCache.renderType = _renderType;
    pageCache.debugURL = _debugURL;
    pageCache.debugMode = _isDebugMode;
    UIGraphicsBeginImageContextWithOptions(_hippyRootView.bounds.size, NO, [UIScreen mainScreen].scale);
    [_hippyRootView drawViewHierarchyInRect:_hippyRootView.bounds afterScreenUpdates:YES];
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    pageCache.snapshot = image;
    return pageCache;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskAllButUpsideDown;
}


#pragma mark - HippyBridgeDelegate

- (BOOL)shouldStartInspector:(HippyBridge *)bridge {
    return bridge.debugMode;
}


#pragma mark - HippyMethodInterceptorProtocol

- (BOOL)shouldInvokeWithModuleName:(NSString *)moduleName
                        methodName:(NSString *)methodName
                         arguments:(NSArray<id<HippyBridgeArgument>> *)arguments
                   argumentsValues:(NSArray *)argumentsValue
                   containCallback:(BOOL)containCallback {
    HippyAssert(moduleName, @"module name must not be null");
    HippyAssert(methodName, @"method name must not be null");
    return YES;
}

- (BOOL)shouldCallbackBeInvokedWithModuleName:(NSString *)moduleName
                                   methodName:(NSString *)methodName
                                   callbackId:(NSNumber *)cbId
                                    arguments:(id)arguments {
    HippyAssert(moduleName, @"module name must not be null");
    HippyAssert(methodName, @"method name must not be null");
    return YES;
}

@end
