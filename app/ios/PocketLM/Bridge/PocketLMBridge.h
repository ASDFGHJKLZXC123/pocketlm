#ifndef PocketLMBridge_h
#define PocketLMBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const PocketLMBridgeErrorDomain;
FOUNDATION_EXPORT NSString *const PocketLMBridgeErrorCodeKey;

/** Core error values remain numerically aligned with pocketlm_error_code. */
typedef NS_ERROR_ENUM(PocketLMBridgeErrorDomain, PocketLMBridgeErrorCode) {
    PocketLMBridgeErrorInvalidArgument = 1,
    PocketLMBridgeErrorOOM = 2,
    PocketLMBridgeErrorModelLoadFailed = 3,
    PocketLMBridgeErrorContextCreateFailed = 4,
    PocketLMBridgeErrorMetalUnavailable = 5,
    PocketLMBridgeErrorChatTemplateFailed = 6,
    PocketLMBridgeErrorTokenizeFailed = 7,
    PocketLMBridgeErrorPromptTooLong = 8,
    PocketLMBridgeErrorDecodeFailed = 9,
    PocketLMBridgeErrorInternal = 10,

    PocketLMBridgeErrorSessionIDExhausted = 1001,
    PocketLMBridgeErrorSessionNotFound = 1002,
    PocketLMBridgeErrorBridgeInternal = 1003,
};

typedef void (^PocketLMEventHandler)(NSDictionary<NSString *, id> *event);
typedef void (^PocketLMLoadCompletion)(NSNumber *_Nullable sessionId,
                                       NSError *_Nullable error);
typedef void (^PocketLMVoidCompletion)(NSError *_Nullable error);
typedef void (^PocketLMDiagnosticsCompletion)(NSDictionary<NSString *, id> *_Nullable diagnostics,
                                              NSError *_Nullable error);

/**
 * Process-scoped owner for native inference sessions.
 *
 * The implementation has a lifecycle queue, an event-delivery queue, and a
 * dedicated teardown queue. Unload synchronously detaches the native handle as
 * an owner fence; its potentially blocking cancel/destroy/join work then runs
 * on teardown without stalling other sessions. No C++ type crosses this
 * Objective-C header, which also keeps the deterministic native harness
 * independent of React Native.
 */
@interface PocketLMBridge : NSObject

+ (instancetype)sharedBridge;

/**
 * Installs the current event sink and returns its monotonically increasing token.
 * An unsubscribe only clears the sink when its token is still current, so a stale
 * React Native invalidation cannot detach a newer fast-reload instance.
 */
- (uint64_t)subscribeWithEventHandler:(PocketLMEventHandler)handler;
- (void)unsubscribeEventHandlerWithToken:(uint64_t)token;

- (void)loadModelAtPath:(NSString *)path
                 config:(NSDictionary<NSString *, id> *)config
             completion:(PocketLMLoadCompletion)completion;

- (void)unloadModel:(NSInteger)sessionId
          completion:(PocketLMVoidCompletion)completion;

/** Returns the frozen synchronous request result (-1...-5 or a positive ID). */
- (NSInteger)generateForSession:(NSInteger)sessionId
                       messages:(NSArray<NSDictionary<NSString *, id> *> *)messages
                         params:(NSDictionary<NSString *, id> *)params;

/**
 * Opens EventEmitter delivery for an accepted request. Production calls this
 * from the JS CallInvoker on the turn after generate() returns.
 */
- (void)openDeliveryGateForSession:(NSInteger)sessionId requestId:(NSInteger)requestId;

- (void)cancelSession:(NSInteger)sessionId requestId:(NSInteger)requestId;

- (void)getDiagnosticsForSession:(NSInteger)sessionId
                       completion:(PocketLMDiagnosticsCompletion)completion;

+ (NSString *)version;

#if defined(POCKETLM_BRIDGE_TESTING)
+ (uint64_t)testingLiveCallbackContextCount;
+ (NSUInteger)testingDeliveryStateCount;
+ (NSUInteger)testingOpenGateCount;
+ (void)testingFailNextGenerateAllocation;
+ (void)testingSetNextSessionId:(int64_t)nextSessionId;
+ (void)testingDrainQueues;
#endif

@end

NS_ASSUME_NONNULL_END

#endif /* PocketLMBridge_h */
