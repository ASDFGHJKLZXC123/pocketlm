#import "PocketLMBridge.h"

#import <PocketLMSpec/PocketLMSpec.h>
#import <React/RCTEventEmitter.h>
#import <React/RCTLog.h>

#include <memory>

static NSString *const PLMInferenceEventName = @"onInferenceEvent";

static void PLMRejectPromise(RCTPromiseRejectBlock reject, NSError *error) {
    NSString *code = error.userInfo[PocketLMBridgeErrorCodeKey];
    reject(code ?: @"INTERNAL", error.localizedDescription, error);
}

@interface PocketLM : RCTEventEmitter <NativePocketLMSpec> {
    uint64_t _subscriberToken;
    std::shared_ptr<facebook::react::CallInvoker> _jsInvoker;
}
@end

@implementation PocketLM

RCT_EXPORT_MODULE(PocketLM)

+ (BOOL)requiresMainQueueSetup {
    return NO;
}

- (instancetype)init {
    self = [super init];
    return self;
}

- (NSArray<NSString *> *)supportedEvents {
    return @[ PLMInferenceEventName ];
}

- (void)startObserving {
    @synchronized (self) {
        if (_subscriberToken != 0) {
            return;
        }
        __weak PocketLM *weakSelf = self;
        _subscriberToken = [[PocketLMBridge sharedBridge]
            subscribeWithEventHandler:^(NSDictionary<NSString *, id> *event) {
                PocketLM *strongSelf = weakSelf;
                if (strongSelf != nil) {
                    [strongSelf sendEventWithName:PLMInferenceEventName body:event];
                }
            }];
    }
}

- (void)stopObserving {
    @synchronized (self) {
        uint64_t token = _subscriberToken;
        _subscriberToken = 0;
        [[PocketLMBridge sharedBridge] unsubscribeEventHandlerWithToken:token];
    }
}

- (void)invalidate {
    [self stopObserving];
    [super invalidate];
}

- (void)dealloc {
    if (_subscriberToken != 0) {
        [[PocketLMBridge sharedBridge] unsubscribeEventHandlerWithToken:_subscriberToken];
    }
}

- (void)loadModel:(NSString *)path
           config:(JS::NativePocketLM::SessionConfig &)config
          resolve:(RCTPromiseResolveBlock)resolve
           reject:(RCTPromiseRejectBlock)reject {
    NSDictionary *nativeConfig = @{
        @"contextSize": @(config.contextSize()),
        @"accelerator": config.accelerator(),
        @"gpuLayers": @(config.gpuLayers()),
    };
    [[PocketLMBridge sharedBridge]
        loadModelAtPath:path
                 config:nativeConfig
             completion:^(NSNumber *sessionId, NSError *error) {
                 if (error != nil) {
                     PLMRejectPromise(reject, error);
                 } else {
                     resolve(sessionId);
                 }
             }];
}

- (void)unloadModel:(NSInteger)sessionId
            resolve:(RCTPromiseResolveBlock)resolve
             reject:(RCTPromiseRejectBlock)reject {
    [[PocketLMBridge sharedBridge]
        unloadModel:sessionId
          completion:^(NSError *error) {
              if (error != nil) {
                  PLMRejectPromise(reject, error);
              } else {
                  resolve(nil);
              }
          }];
}

- (NSNumber *)generate:(NSInteger)sessionId
               messages:(NSArray *)messages
                 params:(JS::NativePocketLM::GenerationParams &)params {
    NSDictionary *nativeParams = @{
        @"maxTokens": @(params.maxTokens()),
        @"temperature": @(params.temperature()),
        @"topK": @(params.topK()),
        @"topP": @(params.topP()),
        @"seed": @(params.seed()),
        @"nThreads": @(params.nThreads()),
    };
    NSInteger requestId = [[PocketLMBridge sharedBridge]
        generateForSession:sessionId
                   messages:messages
                     params:nativeParams];
    if (requestId > 0) {
        std::shared_ptr<facebook::react::CallInvoker> jsInvoker;
        @synchronized (self) {
            jsInvoker = _jsInvoker;
        }
        if (jsInvoker != nullptr) {
            // generate() is a synchronous TurboModule call on this invoker's JS
            // executor. Async work cannot run until the native call unwinds and
            // JavaScript has received the request ID, so this is a structural
            // later-turn gate rather than a timing delay.
            jsInvoker->invokeAsync([sessionId, requestId] {
                @autoreleasepool {
                    [[PocketLMBridge sharedBridge] openDeliveryGateForSession:sessionId
                                                                    requestId:requestId];
                }
            });
        } else {
            RCTLogError(@"PocketLM generate accepted before its JS CallInvoker was installed");
        }
    }
    return @(requestId);
}

- (void)cancel:(NSInteger)sessionId requestId:(NSInteger)requestId {
    [[PocketLMBridge sharedBridge] cancelSession:sessionId requestId:requestId];
}

- (void)getDiagnostics:(NSInteger)sessionId
               resolve:(RCTPromiseResolveBlock)resolve
                reject:(RCTPromiseRejectBlock)reject {
    [[PocketLMBridge sharedBridge]
        getDiagnosticsForSession:sessionId
                       completion:^(NSDictionary<NSString *, id> *diagnostics, NSError *error) {
                           if (error != nil) {
                               PLMRejectPromise(reject, error);
                           } else {
                               resolve(diagnostics);
                           }
                       }];
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
    @synchronized (self) {
        _jsInvoker = params.jsInvoker;
    }
    return std::make_shared<facebook::react::NativePocketLMSpecJSI>(params);
}

@end
