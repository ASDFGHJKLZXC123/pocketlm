#import "PocketLMBridge.h"

#include "pocketlm_core.h"

#import <os/log.h>

#include <atomic>
#include <cmath>
#include <cstdint>
#include <exception>
#include <limits>
#include <new>
#include <string>
#include <vector>

NSErrorDomain const PocketLMBridgeErrorDomain = @"com.pocketlm.bridge";
NSString *const PocketLMBridgeErrorCodeKey = @"PocketLMBridgeErrorCode";

static const NSUInteger PLMTokenFlushByteThreshold = 4096;
static const uint64_t PLMTokenFlushNanoseconds = 16ull * NSEC_PER_MSEC;
static const int64_t PLMJavaScriptMaxSafeInteger = 9007199254740991LL;

static void *PLMLifecycleQueueKey = &PLMLifecycleQueueKey;
static void *PLMDeliveryQueueKey = &PLMDeliveryQueueKey;
static void *PLMTeardownQueueKey = &PLMTeardownQueueKey;

static os_log_t PLMBridgeLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.pocketlm", "bridge-v2");
    });
    return log;
}

static NSString *PLMCoreErrorCode(pocketlm_error_code code) {
    switch (code) {
        case POCKETLM_ERR_INVALID_ARGUMENT:       return @"INVALID_ARGUMENT";
        case POCKETLM_ERR_OOM:                    return @"OOM";
        case POCKETLM_ERR_MODEL_LOAD_FAILED:      return @"MODEL_LOAD_FAILED";
        case POCKETLM_ERR_CONTEXT_CREATE_FAILED:  return @"CONTEXT_CREATE_FAILED";
        case POCKETLM_ERR_METAL_UNAVAILABLE:      return @"METAL_UNAVAILABLE";
        case POCKETLM_ERR_CHAT_TEMPLATE_FAILED:   return @"CHAT_TEMPLATE_FAILED";
        case POCKETLM_ERR_TOKENIZE_FAILED:        return @"TOKENIZE_FAILED";
        case POCKETLM_ERR_PROMPT_TOO_LONG:        return @"PROMPT_TOO_LONG";
        case POCKETLM_ERR_DECODE_FAILED:          return @"DECODE_FAILED";
        case POCKETLM_ERR_INTERNAL:               return @"INTERNAL";
        case POCKETLM_OK:                         return @"INTERNAL";
    }
    return @"INTERNAL";
}

static NSString *PLMNativeErrorCode(PocketLMBridgeErrorCode code) {
    switch (code) {
        case PocketLMBridgeErrorSessionIDExhausted: return @"SESSION_ID_EXHAUSTED";
        case PocketLMBridgeErrorSessionNotFound:    return @"SESSION_NOT_FOUND";
        case PocketLMBridgeErrorBridgeInternal:     return @"INTERNAL";
        default: return PLMCoreErrorCode((pocketlm_error_code)code);
    }
}

static NSError *PLMError(PocketLMBridgeErrorCode code, NSString *message) {
    return [NSError errorWithDomain:PocketLMBridgeErrorDomain
                               code:code
                           userInfo:@{
                               PocketLMBridgeErrorCodeKey: PLMNativeErrorCode(code),
                               NSLocalizedDescriptionKey: message ?: @"PocketLM bridge failure",
                           }];
}

static NSError *PLMCoreNSError(pocketlm_error_code code, NSString *context) {
    NSString *coreMessage = nil;
    const char *rawMessage = pocketlm_error_code_string(code);
    if (rawMessage != nullptr) {
        coreMessage = [NSString stringWithUTF8String:rawMessage];
    }
    NSString *message = coreMessage.length > 0
        ? [NSString stringWithFormat:@"%@: %@", context, coreMessage]
        : context;
    PocketLMBridgeErrorCode bridgeCode = code >= POCKETLM_ERR_INVALID_ARGUMENT &&
                                                 code <= POCKETLM_ERR_INTERNAL
        ? (PocketLMBridgeErrorCode)code
        : PocketLMBridgeErrorBridgeInternal;
    return PLMError(bridgeCode, message);
}

static BOOL PLMReadInt32(id value, int32_t minimum, int32_t maximum, int32_t *output) {
    if (![value isKindOfClass:NSNumber.class]) {
        return NO;
    }
    double number = [value doubleValue];
    if (!std::isfinite(number) || std::floor(number) != number ||
        number < minimum || number > maximum) {
        return NO;
    }
    *output = (int32_t)number;
    return YES;
}

static BOOL PLMReadFiniteFloat(id value, double minimum, double maximum,
                               BOOL minimumExclusive, float *output) {
    if (![value isKindOfClass:NSNumber.class]) {
        return NO;
    }
    double number = [value doubleValue];
    if (!std::isfinite(number) ||
        (minimumExclusive ? number <= minimum : number < minimum) || number > maximum) {
        return NO;
    }
    *output = (float)number;
    return std::isfinite(*output);
}

static NSData *PLMStrictUTF8Data(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length == 0 ||
        [value rangeOfString:@"\0"].location != NSNotFound) {
        return nil;
    }
    return [value dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
}

static NSString *PLMAcceleratorString(pocketlm_accelerator accelerator) {
    switch (accelerator) {
        case POCKETLM_ACCELERATOR_AUTO:  return @"auto";
        case POCKETLM_ACCELERATOR_CPU:   return @"cpu";
        case POCKETLM_ACCELERATOR_METAL: return @"metal";
    }
    return nil;
}

static NSString *PLMFinishReasonString(pocketlm_finish_reason reason) {
    switch (reason) {
        case POCKETLM_FINISH_EOS:               return @"eos";
        case POCKETLM_FINISH_MAX_TOKENS:        return @"max_tokens";
        case POCKETLM_FINISH_CANCELLED:         return @"cancelled";
        case POCKETLM_FINISH_CONTEXT_EXHAUSTED: return @"context_exhausted";
    }
    return nil;
}

static BOOL PLMErrorCodeIsFrozen(pocketlm_error_code code) {
    return code >= POCKETLM_ERR_INVALID_ARGUMENT && code <= POCKETLM_ERR_INTERNAL;
}

class PLMCallbackContext;

@interface PLMSessionRecord : NSObject
@property(nonatomic, assign) pocketlm_session *nativeSession;
@property(nonatomic, assign) int32_t sessionId;
@property(nonatomic, assign) pocketlm_accelerator requestedAccelerator;
@property(nonatomic, assign) int32_t activeRequestId;
@property(nonatomic, assign, getter=isUnloading) BOOL unloading;
@property(nonatomic, assign, getter=isFaulted) BOOL faulted;
@property(nonatomic, assign) BOOL teardownStarted;
@property(nonatomic, assign) BOOL teardownJoined;
@property(nonatomic, assign) BOOL explicitUnloadRequested;
@property(nonatomic, assign) BOOL finalizationScheduled;
@property(nonatomic, assign) BOOL teardownBarrierScheduled;
@property(nonatomic, assign) BOOL gateAdmissionClosed;
@property(nonatomic, assign) int32_t faultRequestId;
@property(nonatomic, assign) PLMCallbackContext *faultContext;
@property(nonatomic, assign) PLMCallbackContext *activeContext;
@property(nonatomic, copy, nullable) PocketLMVoidCompletion unloadCompletion;
@end

@implementation PLMSessionRecord
@end

@interface PLMDeliveryState : NSObject
@property(nonatomic, assign) int32_t sessionId;
@property(nonatomic, assign) int32_t requestId;
@property(nonatomic, assign) int32_t nextIndex;
@property(nonatomic, assign) int32_t firstPendingIndex;
@property(nonatomic, assign) NSUInteger pendingTokenCount;
@property(nonatomic, assign) NSUInteger pendingByteCount;
@property(nonatomic, strong) NSMutableString *pendingText;
@property(nonatomic, assign) uint64_t timerGeneration;
@property(nonatomic, assign) BOOL timerArmed;
@property(nonatomic, assign) BOOL gateOpen;
@property(nonatomic, assign) BOOL terminalSeen;
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *deferredEvents;
@end

@implementation PLMDeliveryState
- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingText = [NSMutableString string];
        _deferredEvents = [NSMutableArray array];
    }
    return self;
}
@end

@interface PLMGlobalState : NSObject
@property(nonatomic, strong) dispatch_queue_t lifecycleQueue;
@property(nonatomic, strong) dispatch_queue_t deliveryQueue;
@property(nonatomic, strong) dispatch_queue_t teardownQueue;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, PLMSessionRecord *> *sessions;
@property(nonatomic, strong) NSMutableDictionary<NSString *, PLMDeliveryState *> *deliveryStates;
@property(nonatomic, strong) NSMutableSet<NSString *> *openGates;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, NSNumber *> *lastTerminalRequestBySession;
@property(nonatomic, strong) NSMutableArray<NSDictionary<NSString *, id> *> *undeliveredEvents;
@property(nonatomic, copy, nullable) NSString *pendingTokenRequestKey;
@property(nonatomic, assign) int64_t nextSessionId;
@property(nonatomic, assign) uint64_t nextSubscriberToken;
@property(nonatomic, assign) uint64_t currentSubscriberToken;
@property(nonatomic, copy, nullable) PocketLMEventHandler eventHandler;
@property(nonatomic, assign) BOOL drainingUndeliveredEvents;
@end

@implementation PLMGlobalState
- (instancetype)init {
    self = [super init];
    if (self) {
        _lifecycleQueue = dispatch_queue_create("com.pocketlm.bridge.lifecycle", DISPATCH_QUEUE_SERIAL);
        _deliveryQueue = dispatch_queue_create("com.pocketlm.bridge.delivery", DISPATCH_QUEUE_SERIAL);
        _teardownQueue = dispatch_queue_create("com.pocketlm.bridge.teardown", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_lifecycleQueue, PLMLifecycleQueueKey,
                                    PLMLifecycleQueueKey, nullptr);
        dispatch_queue_set_specific(_deliveryQueue, PLMDeliveryQueueKey,
                                    PLMDeliveryQueueKey, nullptr);
        dispatch_queue_set_specific(_teardownQueue, PLMTeardownQueueKey,
                                    PLMTeardownQueueKey, nullptr);
        _sessions = [NSMutableDictionary dictionary];
        _deliveryStates = [NSMutableDictionary dictionary];
        _openGates = [NSMutableSet set];
        _lastTerminalRequestBySession = [NSMutableDictionary dictionary];
        _undeliveredEvents = [NSMutableArray array];
        _nextSessionId = 1;
        _nextSubscriberToken = 1;
    }
    return self;
}
@end

static PLMGlobalState *PLMState(void) {
    static PLMGlobalState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [[PLMGlobalState alloc] init];
    });
    return state;
}

static void PLMLifecycleSync(dispatch_block_t block) {
    if (dispatch_get_specific(PLMLifecycleQueueKey) != nullptr) {
        block();
    } else {
        dispatch_sync(PLMState().lifecycleQueue, block);
    }
}

static void PLMDeliverySync(dispatch_block_t block) {
    if (dispatch_get_specific(PLMDeliveryQueueKey) != nullptr) {
        block();
    } else {
        dispatch_sync(PLMState().deliveryQueue, block);
    }
}

#if defined(POCKETLM_BRIDGE_TESTING)
static void PLMTeardownSync(dispatch_block_t block) {
    if (dispatch_get_specific(PLMTeardownQueueKey) != nullptr) {
        block();
    } else {
        dispatch_sync(PLMState().teardownQueue, block);
    }
}
#endif

static void PLMDeliveryAsync(dispatch_block_t block) {
    dispatch_async(PLMState().deliveryQueue, block);
}

// The delivery queue owns each observable event until a subscriber returns
// successfully. Keeping the current event at index zero makes an exception
// non-dropping and preserves its order ahead of every later event.
static void PLMDrainUndeliveredEvents(void) {
    PLMGlobalState *state = PLMState();
    if (state.drainingUndeliveredEvents) {
        return;
    }

    state.drainingUndeliveredEvents = YES;
    BOOL retryWithReplacement = NO;
    @try {
        while (state.undeliveredEvents.count > 0 && state.eventHandler != nil) {
            PocketLMEventHandler handler = state.eventHandler;
            uint64_t token = state.currentSubscriberToken;
            NSDictionary<NSString *, id> *event = state.undeliveredEvents.firstObject;
            BOOL delivered = NO;
            BOOL handlerFailed = NO;
            try {
                @try {
                    handler(event);
                    delivered = YES;
                } @catch (NSException *exception) {
                    handlerFailed = YES;
                    os_log_error(PLMBridgeLog(), "event sink exception: %{public}@",
                                 exception.reason);
                }
            } catch (const std::exception &exception) {
                handlerFailed = YES;
                os_log_error(PLMBridgeLog(), "event sink C++ exception: %{public}s",
                             exception.what());
            } catch (...) {
                handlerFailed = YES;
                os_log_error(PLMBridgeLog(), "unknown event sink C++ exception");
            }
            if (handlerFailed) {
                if (state.currentSubscriberToken == token) {
                    state.currentSubscriberToken = 0;
                    state.eventHandler = nil;
                } else if (state.eventHandler != nil) {
                    // A handler may install its replacement reentrantly before
                    // throwing. Retry only after unwinding the current call.
                    retryWithReplacement = YES;
                }
            }
            if (!delivered) {
                break;
            }
            [state.undeliveredEvents removeObjectAtIndex:0];
        }
    } @finally {
        state.drainingUndeliveredEvents = NO;
    }

    if (retryWithReplacement) {
        dispatch_async(state.deliveryQueue, ^{
            PLMDrainUndeliveredEvents();
        });
    }
}

class PLMCallbackContext {
public:
    PLMCallbackContext();
    ~PLMCallbackContext();
    __unsafe_unretained PocketLMBridge *bridge = nil;
    int32_t sessionId = 0;
    std::atomic<int32_t> observedRequestId{0};
    std::atomic<int32_t> acceptedRequestId{0};
    std::atomic<uint32_t> references{2}; // generate owner + callback lifetime
    std::atomic<bool> callbackReferenceReleased{false};
    std::atomic<bool> faultScheduled{false};
};

#if defined(POCKETLM_BRIDGE_TESTING)
static std::atomic<uint64_t> PLMLiveCallbackContextCount{0};
static std::atomic<bool> PLMFailNextGenerateAllocation{false};
#endif

PLMCallbackContext::PLMCallbackContext() {
#if defined(POCKETLM_BRIDGE_TESTING)
    PLMLiveCallbackContextCount.fetch_add(1, std::memory_order_relaxed);
#endif
}

PLMCallbackContext::~PLMCallbackContext() {
#if defined(POCKETLM_BRIDGE_TESTING)
    PLMLiveCallbackContextCount.fetch_sub(1, std::memory_order_relaxed);
#endif
}

static void PLMRetainContext(PLMCallbackContext *context) {
    context->references.fetch_add(1, std::memory_order_relaxed);
}

static void PLMReleaseContext(PLMCallbackContext *context) {
    if (context->references.fetch_sub(1, std::memory_order_acq_rel) == 1) {
        delete context;
    }
}

static void PLMReleaseCallbackReference(PLMCallbackContext *context) {
    if (!context->callbackReferenceReleased.exchange(true, std::memory_order_acq_rel)) {
        PLMReleaseContext(context);
    }
}

static NSString *PLMRequestKey(int32_t sessionId, int32_t requestId) {
    return [NSString stringWithFormat:@"%d/%d", sessionId, requestId];
}

@interface PocketLMBridge ()
#if defined(POCKETLM_BRIDGE_TESTING)
+ (uint64_t)testingLiveCallbackContextCount;
+ (NSUInteger)testingDeliveryStateCount;
+ (NSUInteger)testingOpenGateCount;
+ (void)testingFailNextGenerateAllocation;
+ (void)testingSetNextSessionId:(int64_t)nextSessionId;
+ (void)testingDrainQueues;
#endif
- (void)handleTokenText:(NSString *)text
                  index:(int32_t)index
              sessionId:(int32_t)sessionId
              requestId:(int32_t)requestId
                context:(PLMCallbackContext *)context;
- (void)handleTerminalEvent:(NSDictionary<NSString *, id> *)event
                  sessionId:(int32_t)sessionId
                  requestId:(int32_t)requestId
                    context:(PLMCallbackContext *)context;
- (void)scheduleContractFaultForContext:(PLMCallbackContext *)context
                              requestId:(int32_t)requestId
                                  cause:(NSString *)cause;
- (void)emitOrDeferEvent:(NSDictionary<NSString *, id> *)event
                    state:(PLMDeliveryState *)delivery;
- (void)flushPendingTokensBeforeEventForSession:(int32_t)sessionId
                                       requestId:(int32_t)requestId;
- (void)retireTerminalDeliveryState:(PLMDeliveryState *)delivery;
- (void)beginTeardownForRecord:(PLMSessionRecord *)record;
- (void)markContractFaultForRecord:(PLMSessionRecord *)record
                              cause:(NSString *)cause;
- (void)scheduleJoinedTeardownBarrierForRecord:(PLMSessionRecord *)record;
- (void)ensureTrustedFaultTerminalForSession:(int32_t)sessionId
                                    requestId:(int32_t)requestId;
- (void)forceOpenDeliveryForSession:(int32_t)sessionId;
- (void)discardDeliveryForSession:(int32_t)sessionId
                     exceptRequest:(int32_t)requestId;
- (void)cleanupDeliveryMetadataForSession:(int32_t)sessionId;
@end

static void PLMEventCallback(void *userData,
                             pocketlm_request_id requestId,
                             pocketlm_event_type type,
                             const void *payload) {
    if (userData == nullptr) {
        return;
    }
    PLMCallbackContext *context = static_cast<PLMCallbackContext *>(userData);
    if (context->faultScheduled.load(std::memory_order_acquire)) {
        PLMReleaseCallbackReference(context);
        return;
    }
    PocketLMBridge *bridge = context->bridge;
    if (bridge == nil) {
        PLMReleaseCallbackReference(context);
        return;
    }

    @autoreleasepool {
        // Symmetric request-ID handshake with generateForSession:. Each side
        // publishes its ID before checking the other side. Sequential
        // consistency prevents the store-buffering outcome where both sides
        // publish but both one-time checks still observe zero.
        int32_t expected = 0;
        if (requestId <= POCKETLM_REQUEST_ID_INVALID ||
            (!context->observedRequestId.compare_exchange_strong(
                 expected, requestId, std::memory_order_seq_cst) && expected != requestId)) {
            [bridge scheduleContractFaultForContext:context
                                          requestId:requestId
                                              cause:@"invalid or unstable callback request ID"];
            return;
        }
        int32_t accepted =
            context->acceptedRequestId.load(std::memory_order_seq_cst);
        if (accepted != 0 && accepted != requestId) {
            [bridge scheduleContractFaultForContext:context
                                          requestId:requestId
                                              cause:@"callback request ID disagrees with generate result"];
            return;
        }

        try {
            @try {
                switch (type) {
                    case POCKETLM_EVT_TOKEN: {
                        const pocketlm_token_event *token =
                            static_cast<const pocketlm_token_event *>(payload);
                        if (token == nullptr || token->bytes == nullptr || token->length == 0 ||
                            token->index < 0) {
                            [bridge scheduleContractFaultForContext:context
                                                          requestId:requestId
                                                              cause:@"invalid token payload"];
                            return;
                        }
                        NSString *text = [[NSString alloc] initWithBytes:token->bytes
                                                                 length:token->length
                                                               encoding:NSUTF8StringEncoding];
                        if (text == nil || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] !=
                                               token->length) {
                            [bridge scheduleContractFaultForContext:context
                                                          requestId:requestId
                                                              cause:@"token payload is not strict UTF-8"];
                            return;
                        }
                        int32_t tokenIndex = token->index;
                        int32_t sessionId = context->sessionId;
                        PLMRetainContext(context);
                        dispatch_async(PLMState().deliveryQueue, ^{
                            [bridge handleTokenText:text
                                             index:tokenIndex
                                         sessionId:sessionId
                                         requestId:requestId
                                           context:context];
                            PLMReleaseContext(context);
                        });
                        return;
                    }

                    case POCKETLM_EVT_DONE: {
                        const pocketlm_stats *stats = static_cast<const pocketlm_stats *>(payload);
                        NSString *reason = stats == nullptr ? nil : PLMFinishReasonString(stats->reason);
                        if (stats == nullptr || reason == nil || stats->prefill_ms < 0 ||
                            stats->prefill_ms > PLMJavaScriptMaxSafeInteger ||
                            stats->decode_ms < 0 ||
                            stats->decode_ms > PLMJavaScriptMaxSafeInteger ||
                            stats->prompt_tokens < 0 || stats->generated_tokens < 0 ||
                            stats->peak_rss_bytes < 0 ||
                            stats->peak_rss_bytes > PLMJavaScriptMaxSafeInteger) {
                            [bridge scheduleContractFaultForContext:context
                                                          requestId:requestId
                                                              cause:@"invalid done payload"];
                            return;
                        }
                        NSDictionary *event = @{
                            @"type": @"done",
                            @"sessionId": @(context->sessionId),
                            @"requestId": @(requestId),
                            @"reason": reason,
                            @"stats": @{
                                @"prefillMs": @(stats->prefill_ms),
                                @"decodeMs": @(stats->decode_ms),
                                @"promptTokens": @(stats->prompt_tokens),
                                @"generatedTokens": @(stats->generated_tokens),
                                @"peakRssBytes": @(stats->peak_rss_bytes),
                            },
                        };
                        int32_t sessionId = context->sessionId;
                        PLMRetainContext(context);
                        dispatch_async(PLMState().deliveryQueue, ^{
                            [bridge handleTerminalEvent:event
                                                sessionId:sessionId
                                                requestId:requestId
                                                  context:context];
                            PLMReleaseContext(context);
                        });
                        PLMReleaseCallbackReference(context);
                        return;
                    }

                    case POCKETLM_EVT_ERROR: {
                        const pocketlm_error *error = static_cast<const pocketlm_error *>(payload);
                        if (error == nullptr || !PLMErrorCodeIsFrozen(error->code) ||
                            error->message == nullptr || error->message_length == 0) {
                            [bridge scheduleContractFaultForContext:context
                                                          requestId:requestId
                                                              cause:@"invalid error payload"];
                            return;
                        }
                        NSString *message = [[NSString alloc] initWithBytes:error->message
                                                                    length:error->message_length
                                                                  encoding:NSUTF8StringEncoding];
                        if (message.length == 0 ||
                            [message lengthOfBytesUsingEncoding:NSUTF8StringEncoding] !=
                                error->message_length) {
                            [bridge scheduleContractFaultForContext:context
                                                          requestId:requestId
                                                              cause:@"error message is not strict non-empty UTF-8"];
                            return;
                        }
                        NSDictionary *event = @{
                            @"type": @"error",
                            @"sessionId": @(context->sessionId),
                            @"requestId": @(requestId),
                            @"code": PLMCoreErrorCode(error->code),
                            @"message": message,
                        };
                        int32_t sessionId = context->sessionId;
                        PLMRetainContext(context);
                        dispatch_async(PLMState().deliveryQueue, ^{
                            [bridge handleTerminalEvent:event
                                                sessionId:sessionId
                                                requestId:requestId
                                                  context:context];
                            PLMReleaseContext(context);
                        });
                        PLMReleaseCallbackReference(context);
                        return;
                    }
                }

                [bridge scheduleContractFaultForContext:context
                                              requestId:requestId
                                                  cause:@"unknown callback event type"];
            } @catch (NSException *exception) {
                NSString *cause = [NSString stringWithFormat:@"callback exception: %@", exception.reason];
                [bridge scheduleContractFaultForContext:context requestId:requestId cause:cause];
            }
        } catch (...) {
            [bridge scheduleContractFaultForContext:context
                                          requestId:requestId
                                              cause:@"C++ exception at callback boundary"];
        }
    }
}

@implementation PocketLMBridge

+ (instancetype)sharedBridge {
    static PocketLMBridge *bridge;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        bridge = [[PocketLMBridge alloc] init];
        (void)PLMState();
    });
    return bridge;
}

+ (NSString *)version {
    try {
        @try {
            const char *version = pocketlm_version();
            NSString *result = version == nullptr ? nil : [NSString stringWithUTF8String:version];
            return result ?: @"unknown";
        } @catch (__unused NSException *exception) {
            return @"unknown";
        }
    } catch (...) {
        return @"unknown";
    }
}

#if defined(POCKETLM_BRIDGE_TESTING)
+ (uint64_t)testingLiveCallbackContextCount {
    return PLMLiveCallbackContextCount.load(std::memory_order_acquire);
}

+ (NSUInteger)testingDeliveryStateCount {
    __block NSUInteger count = 0;
    PLMDeliverySync(^{
        count = PLMState().deliveryStates.count;
    });
    return count;
}

+ (NSUInteger)testingOpenGateCount {
    __block NSUInteger count = 0;
    PLMDeliverySync(^{
        count = PLMState().openGates.count;
    });
    return count;
}

+ (void)testingFailNextGenerateAllocation {
    PLMFailNextGenerateAllocation.store(true, std::memory_order_release);
}

+ (void)testingSetNextSessionId:(int64_t)nextSessionId {
    PLMLifecycleSync(^{
        PLMState().nextSessionId = nextSessionId;
    });
}

+ (void)testingDrainQueues {
    PLMLifecycleSync(^{});
    PLMTeardownSync(^{});
    PLMLifecycleSync(^{});
    PLMDeliverySync(^{});
    PLMLifecycleSync(^{});
    PLMDeliverySync(^{});
}
#endif

- (uint64_t)subscribeWithEventHandler:(PocketLMEventHandler)handler {
    if (handler == nil) {
        return 0;
    }
    __block uint64_t token = 0;
    PLMDeliverySync(^{
        PLMGlobalState *state = PLMState();
        if (state.nextSubscriberToken == 0) {
            os_log_fault(PLMBridgeLog(), "subscriber token space exhausted");
            return;
        }
        token = state.nextSubscriberToken++;
        state.currentSubscriberToken = token;
        state.eventHandler = handler;
        PLMDrainUndeliveredEvents();
    });
    return token;
}

- (void)unsubscribeEventHandlerWithToken:(uint64_t)token {
    if (token == 0) {
        return;
    }
    PLMDeliverySync(^{
        PLMGlobalState *state = PLMState();
        if (state.currentSubscriberToken == token) {
            state.currentSubscriberToken = 0;
            state.eventHandler = nil;
        }
    });
}

- (void)loadModelAtPath:(NSString *)path
                 config:(NSDictionary<NSString *, id> *)config
             completion:(PocketLMLoadCompletion)completion {
    NSString *pathCopy = [path copy];
    NSDictionary *configCopy = [config copy];
    PocketLMLoadCompletion completionCopy = [completion copy];
    dispatch_async(PLMState().lifecycleQueue, ^{
        @autoreleasepool {
            NSData *pathData = PLMStrictUTF8Data(pathCopy);
            int32_t contextSize = 0;
            int32_t gpuLayers = 0;
            NSString *acceleratorName = configCopy[@"accelerator"];
            pocketlm_accelerator accelerator;
            BOOL acceleratorValid = YES;
            if ([acceleratorName isEqualToString:@"auto"]) {
                accelerator = POCKETLM_ACCELERATOR_AUTO;
            } else if ([acceleratorName isEqualToString:@"cpu"]) {
                accelerator = POCKETLM_ACCELERATOR_CPU;
            } else if ([acceleratorName isEqualToString:@"metal"]) {
                accelerator = POCKETLM_ACCELERATOR_METAL;
            } else {
                acceleratorValid = NO;
                accelerator = POCKETLM_ACCELERATOR_AUTO;
            }
            if (pathData == nil || !pathCopy.isAbsolutePath ||
                !PLMReadInt32(configCopy[@"contextSize"], 1, INT32_MAX, &contextSize) ||
                !PLMReadInt32(configCopy[@"gpuLayers"], 0, INT32_MAX, &gpuLayers) ||
                !acceleratorValid) {
                NSError *error = PLMError(PocketLMBridgeErrorInvalidArgument,
                                          @"Invalid model path or session configuration");
                PLMDeliveryAsync(^{ completionCopy(nil, error); });
                return;
            }
            PLMGlobalState *state = PLMState();
            if (state.nextSessionId > INT32_MAX) {
                NSError *error = PLMError(PocketLMBridgeErrorSessionIDExhausted,
                                          @"Native session ID space is exhausted");
                PLMDeliveryAsync(^{ completionCopy(nil, error); });
                return;
            }

            pocketlm_session_config nativeConfig = {
                .context_size = contextSize,
                .accelerator = accelerator,
                .gpu_layers = gpuLayers,
            };
            pocketlm_session *nativeSession = nullptr;
            pocketlm_error_code result = POCKETLM_ERR_INTERNAL;
            try {
                @try {
                    std::string nativePath(static_cast<const char *>(pathData.bytes), pathData.length);
                    result = pocketlm_create_v2(nativePath.c_str(), &nativeConfig, &nativeSession);
                } @catch (__unused NSException *exception) {
                    result = POCKETLM_ERR_INTERNAL;
                }
            } catch (...) {
                result = POCKETLM_ERR_INTERNAL;
            }
            if (result != POCKETLM_OK || nativeSession == nullptr) {
                if (nativeSession != nullptr) {
                    pocketlm_destroy(nativeSession);
                }
                pocketlm_error_code errorCode = result == POCKETLM_OK ? POCKETLM_ERR_INTERNAL : result;
                NSError *error = PLMCoreNSError(errorCode, @"Could not create model session");
                PLMDeliveryAsync(^{ completionCopy(nil, error); });
                return;
            }

            int32_t sessionId = (int32_t)state.nextSessionId++;
            PLMSessionRecord *record = [[PLMSessionRecord alloc] init];
            record.nativeSession = nativeSession;
            record.sessionId = sessionId;
            record.requestedAccelerator = accelerator;
            record.activeRequestId = POCKETLM_REQUEST_ID_INVALID;
            state.sessions[@(sessionId)] = record;
            NSNumber *resolvedSessionId = @(sessionId);
            PLMDeliveryAsync(^{ completionCopy(resolvedSessionId, nil); });
        }
    });
}

- (void)unloadModel:(NSInteger)sessionId completion:(PocketLMVoidCompletion)completion {
    PocketLMVoidCompletion completionCopy = [completion copy];
    if (sessionId <= 0 || sessionId > INT32_MAX) {
        NSError *error = PLMError(PocketLMBridgeErrorSessionNotFound, @"Session was not found");
        PLMDeliveryAsync(^{ completionCopy(error); });
        return;
    }
    PLMLifecycleSync(^{
        PLMGlobalState *state = PLMState();
        PLMSessionRecord *record = state.sessions[@(sessionId)];
        if (record == nil) {
            NSError *error = PLMError(PocketLMBridgeErrorSessionNotFound,
                                      @"Session was not found");
            PLMDeliveryAsync(^{ completionCopy(error); });
            return;
        }

        if (record.isUnloading) {
            if (!record.isFaulted || record.explicitUnloadRequested) {
                NSError *error = PLMError(PocketLMBridgeErrorSessionNotFound,
                                          @"Session was not found");
                PLMDeliveryAsync(^{ completionCopy(error); });
                return;
            }
            record.explicitUnloadRequested = YES;
            record.gateAdmissionClosed = YES;
            record.unloadCompletion = completionCopy;
            if (record.teardownJoined) {
                [self scheduleJoinedTeardownBarrierForRecord:record];
            }
            return;
        }

        record.explicitUnloadRequested = YES;
        record.gateAdmissionClosed = YES;
        record.unloadCompletion = completionCopy;
        [self beginTeardownForRecord:record];
    });
}

- (void)beginTeardownForRecord:(PLMSessionRecord *)record {
    if (record == nil || record.teardownStarted) {
        return;
    }

    record.unloading = YES;
    record.teardownStarted = YES;
    pocketlm_session *nativeSession = record.nativeSession;
    int32_t cancelRequestId = record.activeRequestId;
    record.nativeSession = nullptr; // owner fence: no later bridge call may admit this handle

    // A fault callback can re-enter while pocketlm_generate_v2 is still on the
    // lifecycle queue. This hop lets that admitted call unwind before destroy
    // begins, while keeping every later operation fenced by the detached handle.
    dispatch_async(PLMState().lifecycleQueue, ^{
        dispatch_async(PLMState().teardownQueue, ^{
            BOOL destroyJoined = nativeSession == nullptr;
            if (nativeSession != nullptr) {
                if (cancelRequestId > POCKETLM_REQUEST_ID_INVALID) {
                    try {
                        @try {
                            pocketlm_cancel(nativeSession, cancelRequestId);
                        } @catch (__unused NSException *exception) {
                            os_log_fault(PLMBridgeLog(),
                                         "Objective-C exception escaped native cancel");
                        }
                    } catch (...) {
                        os_log_fault(PLMBridgeLog(), "C++ exception escaped native cancel");
                    }
                }
                try {
                    @try {
                        pocketlm_destroy(nativeSession);
                        destroyJoined = YES;
                    } @catch (__unused NSException *exception) {
                        os_log_fault(PLMBridgeLog(),
                                     "Objective-C exception escaped native destroy");
                    }
                } catch (...) {
                    os_log_fault(PLMBridgeLog(), "C++ exception escaped native destroy");
                }
            }

            // Never claim a join, release callback tickets, or remove the
            // record when destroy failed to return. The detached handle remains
            // permanently fenced because its ownership is indeterminate.
            if (!destroyJoined) {
                return;
            }

            dispatch_async(PLMState().lifecycleQueue, ^{
                record.teardownJoined = YES;
                [self scheduleJoinedTeardownBarrierForRecord:record];
            });
        });
    });
}

- (void)markContractFaultForRecord:(PLMSessionRecord *)record
                              cause:(NSString *)cause {
    PLMGlobalState *state = PLMState();
    if (record == nil || state.sessions[@(record.sessionId)] != record || record.isFaulted) {
        return;
    }

    record.faulted = YES;
    // Preserve an admitted request's identity even if its terminal crosses the
    // delivery queue before destroy joins and clears activeRequestId.
    record.faultRequestId = record.activeRequestId;
    int32_t sessionId = record.sessionId;
    PLMCallbackContext *activeContext = record.activeContext;
    if (activeContext != nullptr) {
        // The session's active-request ticket keeps this pointer alive. Suppress
        // any cancel-induced native terminal; the joined teardown barrier owns
        // synthesis of the single trusted INTERNAL terminal and retires both
        // callback and active-request references even if the core never calls.
        activeContext->faultScheduled.store(true, std::memory_order_release);
    }
    os_log_fault(PLMBridgeLog(),
                 "native contract fault for session %d: %{public}@",
                 sessionId, cause);
    if (!record.teardownStarted) {
        [self beginTeardownForRecord:record];
    } else if (record.teardownJoined) {
        [self scheduleJoinedTeardownBarrierForRecord:record];
    }
}

static BOOL PLMBuildMessagesAndParams(
    NSArray<NSDictionary<NSString *, id> *> *messages,
    NSDictionary<NSString *, id> *params,
    std::vector<std::string> &contents,
    std::vector<pocketlm_message> &nativeMessages,
    pocketlm_params &nativeParams) {
    if (![messages isKindOfClass:NSArray.class] || messages.count == 0 ||
        ![params isKindOfClass:NSDictionary.class]) {
        return NO;
    }

    std::vector<pocketlm_role> roles;
    roles.reserve(messages.count);
    contents.reserve(messages.count);
    for (NSDictionary *message in messages) {
        if (![message isKindOfClass:NSDictionary.class]) {
            return NO;
        }
        NSString *roleName = message[@"role"];
        NSString *content = message[@"content"];
        NSData *contentData = PLMStrictUTF8Data(content);
        if (contentData == nil) {
            return NO;
        }
        pocketlm_role role;
        if ([roleName isEqualToString:@"system"]) {
            role = POCKETLM_ROLE_SYSTEM;
        } else if ([roleName isEqualToString:@"user"]) {
            role = POCKETLM_ROLE_USER;
        } else if ([roleName isEqualToString:@"assistant"]) {
            role = POCKETLM_ROLE_ASSISTANT;
        } else {
            return NO;
        }
        roles.push_back(role);
        contents.emplace_back(static_cast<const char *>(contentData.bytes), contentData.length);
    }

    size_t index = 0;
    if (roles[0] == POCKETLM_ROLE_SYSTEM) {
        index = 1;
    }
    bool expectUser = true;
    for (; index < roles.size(); ++index) {
        pocketlm_role expectedRole = expectUser ? POCKETLM_ROLE_USER : POCKETLM_ROLE_ASSISTANT;
        if (roles[index] != expectedRole) {
            return NO;
        }
        expectUser = !expectUser;
    }
    if (expectUser) { // The last non-system message was not a user message.
        return NO;
    }

    int32_t maxTokens = 0;
    int32_t topK = 0;
    int32_t seed = 0;
    int32_t nThreads = 0;
    float temperature = 0;
    float topP = 0;
    if (!PLMReadInt32(params[@"maxTokens"], 1, INT32_MAX, &maxTokens) ||
        !PLMReadFiniteFloat(params[@"temperature"], 0, std::numeric_limits<float>::max(),
                            NO, &temperature) ||
        !PLMReadInt32(params[@"topK"], 0, INT32_MAX, &topK) ||
        !PLMReadFiniteFloat(params[@"topP"], 0, 1, YES, &topP) ||
        !PLMReadInt32(params[@"seed"], INT32_MIN, INT32_MAX, &seed) ||
        !PLMReadInt32(params[@"nThreads"], 0, INT32_MAX, &nThreads)) {
        return NO;
    }

    nativeMessages.reserve(messages.count);
    for (size_t i = 0; i < roles.size(); ++i) {
        nativeMessages.push_back({roles[i], contents[i].c_str()});
    }
    nativeParams = {
        .max_tokens = maxTokens,
        .temperature = temperature,
        .top_k = topK,
        .top_p = topP,
        .seed = seed,
        .n_threads = nThreads,
    };
    return YES;
}

- (NSInteger)generateForSession:(NSInteger)sessionId
                       messages:(NSArray<NSDictionary<NSString *, id> *> *)messages
                         params:(NSDictionary<NSString *, id> *)params {
    if (sessionId <= 0 || sessionId > INT32_MAX) {
        return POCKETLM_GENERATE_INVALID_ARGUMENT;
    }
    __block NSInteger result = POCKETLM_GENERATE_INVALID_ARGUMENT;
    PLMLifecycleSync(^{
        PLMSessionRecord *record = PLMState().sessions[@(sessionId)];
        if (record == nil) {
            result = POCKETLM_GENERATE_INVALID_ARGUMENT;
            return;
        }
        if (record.isUnloading) {
            result = POCKETLM_GENERATE_SHUTTING_DOWN;
            return;
        }
        if (record.activeRequestId > POCKETLM_REQUEST_ID_INVALID) {
            // Keep a request active until its terminal crosses the delivery
            // gate. This prevents a later request from racing validation or
            // overtaking a deferred terminal for the same session.
            result = POCKETLM_GENERATE_BUSY;
            return;
        }

        NSArray *messagesCopy = nil;
        NSDictionary *paramsCopy = nil;
        @try {
            messagesCopy = [messages copy];
            paramsCopy = [params copy];
        } @catch (__unused NSException *exception) {
            result = POCKETLM_GENERATE_OOM;
            return;
        }

        PLMCallbackContext *context = nullptr;
        pocketlm_request_id requestId = POCKETLM_GENERATE_INVALID_ARGUMENT;
        @try {
            try {
#if defined(POCKETLM_BRIDGE_TESTING)
                if (PLMFailNextGenerateAllocation.exchange(false, std::memory_order_acq_rel)) {
                    throw std::bad_alloc();
                }
#endif
                std::vector<std::string> contents;
                std::vector<pocketlm_message> nativeMessages;
                pocketlm_params nativeParams = {};
                if (!PLMBuildMessagesAndParams(messagesCopy, paramsCopy, contents,
                                               nativeMessages, nativeParams)) {
                    result = POCKETLM_GENERATE_INVALID_ARGUMENT;
                    return;
                }

                context = new PLMCallbackContext();
                context->bridge = self;
                context->sessionId = (int32_t)sessionId;
                requestId = pocketlm_generate_v2(record.nativeSession,
                                                  nativeMessages.data(),
                                                  nativeMessages.size(),
                                                  &nativeParams,
                                                  PLMEventCallback,
                                                  context);
                // Publish before the matching observed-ID check. The callback
                // performs the same publish-then-check sequence in the other
                // direction, closing both pre-return and post-return races.
                context->acceptedRequestId.store(requestId, std::memory_order_seq_cst);
                result = requestId;
            } catch (const std::bad_alloc &) {
                if (context != nullptr) {
                    PLMReleaseCallbackReference(context);
                    PLMReleaseContext(context);
                }
                result = POCKETLM_GENERATE_OOM;
                return;
            } catch (...) {
                if (context != nullptr) {
                    PLMReleaseCallbackReference(context);
                    PLMReleaseContext(context);
                }
                result = POCKETLM_GENERATE_INVALID_ARGUMENT;
                return;
            }
        } @catch (__unused NSException *exception) {
            if (context != nullptr) {
                PLMReleaseCallbackReference(context);
                PLMReleaseContext(context);
            }
            result = POCKETLM_GENERATE_OOM;
            return;
        }

        int32_t observed = context->observedRequestId.load(std::memory_order_seq_cst);
        if (requestId > POCKETLM_REQUEST_ID_INVALID) {
            record.activeRequestId = requestId;
            PLMRetainContext(context);
            record.activeContext = context;
            if (observed != 0 && observed != requestId) {
                [self scheduleContractFaultForContext:context
                                            requestId:observed
                                                cause:@"callback request ID disagrees with generate result"];
            }
        } else {
            if (observed != 0) {
                [self scheduleContractFaultForContext:context
                                            requestId:observed
                                                cause:@"rejected generation invoked its callback"];
            }
            PLMReleaseCallbackReference(context);
        }
        PLMReleaseContext(context); // generate-call ownership
    });
    return result;
}

- (void)openDeliveryGateForSession:(NSInteger)sessionId requestId:(NSInteger)requestId {
    if (sessionId <= 0 || sessionId > INT32_MAX ||
        requestId <= POCKETLM_REQUEST_ID_INVALID || requestId > INT32_MAX) {
        return;
    }

    PLMLifecycleSync(^{
        PLMSessionRecord *record = PLMState().sessions[@(sessionId)];
        if (record == nil || record.gateAdmissionClosed) {
            return;
        }
        // Enqueue while lifecycle admission is still held. Any later lifecycle
        // close therefore queues its delivery cleanup strictly after this gate.
        dispatch_async(PLMState().deliveryQueue, ^{
            PLMGlobalState *state = PLMState();
            NSString *key = PLMRequestKey((int32_t)sessionId, (int32_t)requestId);
            NSNumber *lastTerminal = state.lastTerminalRequestBySession[@(sessionId)];
            if (lastTerminal != nil && requestId <= lastTerminal.integerValue) {
                return;
            }
            [state.openGates addObject:key];
            PLMDeliveryState *delivery = state.deliveryStates[key];
            if (delivery == nil || delivery.gateOpen) {
                return;
            }
            delivery.gateOpen = YES;
            NSArray<NSDictionary *> *events = [delivery.deferredEvents copy];
            [delivery.deferredEvents removeAllObjects];
            for (NSDictionary *event in events) {
                [self emitOrDeferEvent:event state:delivery];
            }
            [self retireTerminalDeliveryState:delivery];
        });
    });
}

- (void)cancelSession:(NSInteger)sessionId requestId:(NSInteger)requestId {
    if (sessionId <= 0 || sessionId > INT32_MAX ||
        requestId <= POCKETLM_REQUEST_ID_INVALID || requestId > INT32_MAX) {
        return;
    }
    dispatch_async(PLMState().lifecycleQueue, ^{
        PLMSessionRecord *record = PLMState().sessions[@(sessionId)];
        if (record != nil && record.nativeSession != nullptr) {
            try {
                @try {
                    pocketlm_cancel(record.nativeSession, (int32_t)requestId);
                } @catch (__unused NSException *exception) {
                    os_log_error(PLMBridgeLog(),
                                 "Objective-C exception escaped pocketlm_cancel");
                }
            } catch (...) {
                os_log_error(PLMBridgeLog(), "C++ exception escaped pocketlm_cancel");
            }
        }
    });
}

- (void)getDiagnosticsForSession:(NSInteger)sessionId
                       completion:(PocketLMDiagnosticsCompletion)completion {
    PocketLMDiagnosticsCompletion completionCopy = [completion copy];
    if (sessionId <= 0 || sessionId > INT32_MAX) {
        NSError *error = PLMError(PocketLMBridgeErrorSessionNotFound,
                                  @"Session was not found");
        PLMDeliveryAsync(^{ completionCopy(nil, error); });
        return;
    }
    dispatch_async(PLMState().lifecycleQueue, ^{
        PLMSessionRecord *record = PLMState().sessions[@(sessionId)];
        if (record == nil || record.isUnloading) {
            NSError *error = PLMError(PocketLMBridgeErrorSessionNotFound,
                                      @"Session was not found");
            PLMDeliveryAsync(^{ completionCopy(nil, error); });
            return;
        }
        pocketlm_session_diagnostics diagnostics = {};
        pocketlm_error_code result = POCKETLM_ERR_INTERNAL;
        try {
            @try {
                result = pocketlm_get_diagnostics(record.nativeSession, &diagnostics);
            } @catch (__unused NSException *exception) {
                result = POCKETLM_ERR_INTERNAL;
            }
        } catch (...) {
            result = POCKETLM_ERR_INTERNAL;
        }
        NSString *requested = PLMAcceleratorString(diagnostics.requested_accelerator);
        NSString *selected = PLMAcceleratorString(diagnostics.selected_accelerator);
        if (result != POCKETLM_OK) {
            if (!PLMErrorCodeIsFrozen(result)) {
                [self markContractFaultForRecord:record
                                           cause:@"diagnostics returned an invalid error enum"];
            }
            NSError *error = PLMCoreNSError(result, @"Could not read session diagnostics");
            PLMDeliveryAsync(^{ completionCopy(nil, error); });
            return;
        }
        BOOL requestedSelectionMismatch =
            diagnostics.requested_accelerator != record.requestedAccelerator ||
            (record.requestedAccelerator == POCKETLM_ACCELERATOR_METAL &&
             diagnostics.selected_accelerator != POCKETLM_ACCELERATOR_METAL) ||
            (record.requestedAccelerator == POCKETLM_ACCELERATOR_CPU &&
             diagnostics.selected_accelerator != POCKETLM_ACCELERATOR_CPU);
        BOOL selectedCPUOffloadMismatch =
            diagnostics.selected_accelerator == POCKETLM_ACCELERATOR_CPU &&
            (diagnostics.offloaded_layers > 0 || diagnostics.kqv_offloaded != 0);
        if (requested == nil || selected == nil ||
            diagnostics.selected_accelerator == POCKETLM_ACCELERATOR_AUTO ||
            requestedSelectionMismatch || selectedCPUOffloadMismatch ||
            diagnostics.context_size <= 0 ||
            diagnostics.batch_size < 0 || diagnostics.model_layers < 0 ||
            diagnostics.offloaded_layers < -1 ||
            (diagnostics.kqv_offloaded != 0 && diagnostics.kqv_offloaded != 1) ||
            diagnostics.peak_rss_bytes < 0 ||
            diagnostics.peak_rss_bytes > PLMJavaScriptMaxSafeInteger) {
            NSError *error = PLMError(PocketLMBridgeErrorBridgeInternal,
                                      @"Core returned invalid diagnostics");
            [self markContractFaultForRecord:record
                                       cause:@"core returned invalid diagnostics"];
            PLMDeliveryAsync(^{ completionCopy(nil, error); });
            return;
        }
        NSDictionary *resultDictionary = @{
            @"requestedAccelerator": requested,
            @"selectedAccelerator": selected,
            @"contextSize": @(diagnostics.context_size),
            @"batchSize": @(diagnostics.batch_size),
            @"modelLayers": @(diagnostics.model_layers),
            @"offloadedLayers": @(diagnostics.offloaded_layers),
            @"kqvOffloaded": @(diagnostics.kqv_offloaded != 0),
            @"peakRssBytes": @(diagnostics.peak_rss_bytes),
        };
        PLMDeliveryAsync(^{ completionCopy(resultDictionary, nil); });
    });
}

- (PLMDeliveryState *)deliveryStateForSession:(int32_t)sessionId
                                    requestId:(int32_t)requestId {
    PLMGlobalState *state = PLMState();
    NSString *key = PLMRequestKey(sessionId, requestId);
    PLMDeliveryState *delivery = state.deliveryStates[key];
    if (delivery == nil) {
        delivery = [[PLMDeliveryState alloc] init];
        delivery.sessionId = sessionId;
        delivery.requestId = requestId;
        delivery.gateOpen = [state.openGates containsObject:key];
        state.deliveryStates[key] = delivery;
    }
    return delivery;
}

- (void)emitOrDeferEvent:(NSDictionary<NSString *, id> *)event
                    state:(PLMDeliveryState *)delivery {
    if (!delivery.gateOpen) {
        [delivery.deferredEvents addObject:event];
        return;
    }
    [PLMState().undeliveredEvents addObject:event];
    PLMDrainUndeliveredEvents();
}

- (void)retireTerminalDeliveryState:(PLMDeliveryState *)delivery {
    if (delivery == nil || !delivery.terminalSeen || !delivery.gateOpen) {
        return;
    }
    PLMGlobalState *state = PLMState();
    NSString *requestKey = PLMRequestKey(delivery.sessionId, delivery.requestId);
    if (state.deliveryStates[requestKey] != delivery) {
        return;
    }
    NSNumber *sessionKey = @(delivery.sessionId);
    NSNumber *previous = state.lastTerminalRequestBySession[sessionKey];
    if (previous == nil || delivery.requestId > previous.intValue) {
        state.lastTerminalRequestBySession[sessionKey] = @(delivery.requestId);
    }
    [state.deliveryStates removeObjectForKey:requestKey];
    [state.openGates removeObject:requestKey];

    int32_t sessionId = delivery.sessionId;
    int32_t requestId = delivery.requestId;
    dispatch_async(state.lifecycleQueue, ^{
        PLMSessionRecord *record = PLMState().sessions[@(sessionId)];
        if (record.activeRequestId != requestId) {
            return;
        }
        record.activeRequestId = POCKETLM_REQUEST_ID_INVALID;
        PLMCallbackContext *context = record.activeContext;
        record.activeContext = nullptr;
        if (context != nullptr) {
            PLMReleaseContext(context); // session's active-request ticket
        }
    });
}

- (void)flushPendingTokens:(PLMDeliveryState *)delivery {
    PLMGlobalState *state = PLMState();
    NSString *requestKey = PLMRequestKey(delivery.sessionId, delivery.requestId);
    if ([state.pendingTokenRequestKey isEqualToString:requestKey]) {
        state.pendingTokenRequestKey = nil;
    }
    if (delivery.pendingTokenCount == 0) {
        return;
    }
    NSDictionary *event = @{
        @"type": @"token",
        @"sessionId": @(delivery.sessionId),
        @"requestId": @(delivery.requestId),
        @"index": @(delivery.firstPendingIndex),
        @"tokenCount": @(delivery.pendingTokenCount),
        @"text": [delivery.pendingText copy],
    };
    [self emitOrDeferEvent:event state:delivery];
    [delivery.pendingText setString:@""];
    delivery.pendingTokenCount = 0;
    delivery.pendingByteCount = 0;
    delivery.timerArmed = NO;
    delivery.timerGeneration += 1;
}

- (void)flushPendingTokensBeforeEventForSession:(int32_t)sessionId
                                       requestId:(int32_t)requestId {
    PLMGlobalState *state = PLMState();
    NSString *currentKey = PLMRequestKey(sessionId, requestId);
    NSString *pendingKey = state.pendingTokenRequestKey;
    if (pendingKey == nil || [pendingKey isEqualToString:currentKey]) {
        return;
    }

    PLMDeliveryState *previous = state.deliveryStates[pendingKey];
    if (previous != nil) {
        [self flushPendingTokens:previous];
    } else {
        // Defensive cleanup if a fault teardown removed the old per-request
        // state before its pending-key marker.
        state.pendingTokenRequestKey = nil;
    }
}

- (void)handleTokenText:(NSString *)text
                  index:(int32_t)index
              sessionId:(int32_t)sessionId
              requestId:(int32_t)requestId
                context:(PLMCallbackContext *)context {
    [self flushPendingTokensBeforeEventForSession:sessionId requestId:requestId];
    if (context == nullptr || context->faultScheduled.load(std::memory_order_acquire)) {
        return;
    }
    NSNumber *lastTerminal = PLMState().lastTerminalRequestBySession[@(sessionId)];
    if (lastTerminal != nil && requestId <= lastTerminal.intValue) {
        [self scheduleContractFaultForContext:context
                                    requestId:requestId
                                        cause:@"token arrived for a retired request"];
        return;
    }
    PLMDeliveryState *delivery = [self deliveryStateForSession:sessionId requestId:requestId];
    if (delivery.terminalSeen || index != delivery.nextIndex) {
        [self scheduleContractFaultForContext:context
                                    requestId:requestId
                                        cause:delivery.terminalSeen
                                            ? @"token arrived after terminal"
                                            : @"token index is not contiguous"];
        return;
    }
    if (delivery.pendingTokenCount == 0) {
        delivery.firstPendingIndex = index;
    }
    [delivery.pendingText appendString:text];
    delivery.pendingTokenCount += 1;
    delivery.pendingByteCount += [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    delivery.nextIndex += 1;
    PLMState().pendingTokenRequestKey = PLMRequestKey(sessionId, requestId);

    if (delivery.pendingByteCount >= PLMTokenFlushByteThreshold) {
        [self flushPendingTokens:delivery];
        return;
    }
    if (!delivery.timerArmed) {
        delivery.timerArmed = YES;
        uint64_t generation = ++delivery.timerGeneration;
        NSString *key = PLMRequestKey(sessionId, requestId);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)PLMTokenFlushNanoseconds),
                       PLMState().deliveryQueue, ^{
            PLMDeliveryState *current = PLMState().deliveryStates[key];
            if (current != nil && current.timerArmed &&
                current.timerGeneration == generation && !current.terminalSeen) {
                [self flushPendingTokens:current];
            }
        });
    }
}

- (void)handleTerminalEvent:(NSDictionary<NSString *, id> *)event
                  sessionId:(int32_t)sessionId
                  requestId:(int32_t)requestId
                    context:(PLMCallbackContext *)context {
    [self flushPendingTokensBeforeEventForSession:sessionId requestId:requestId];
    if (context == nullptr || context->faultScheduled.load(std::memory_order_acquire)) {
        return;
    }
    NSNumber *lastTerminal = PLMState().lastTerminalRequestBySession[@(sessionId)];
    if (lastTerminal != nil && requestId <= lastTerminal.intValue) {
        [self scheduleContractFaultForContext:context
                                    requestId:requestId
                                        cause:@"terminal arrived for a retired request"];
        return;
    }
    PLMDeliveryState *delivery = [self deliveryStateForSession:sessionId requestId:requestId];
    if (delivery.terminalSeen) {
        [self scheduleContractFaultForContext:context
                                    requestId:requestId
                                        cause:@"more than one terminal event"];
        return;
    }
    [self flushPendingTokens:delivery];
    delivery.terminalSeen = YES;
    delivery.timerArmed = NO;
    delivery.timerGeneration += 1;
    [self emitOrDeferEvent:event state:delivery];
    [self retireTerminalDeliveryState:delivery];
}

- (void)ensureTrustedFaultTerminalForSession:(int32_t)sessionId
                                    requestId:(int32_t)requestId {
    if (requestId <= POCKETLM_REQUEST_ID_INVALID) {
        return;
    }
    [self flushPendingTokensBeforeEventForSession:sessionId requestId:requestId];
    PLMGlobalState *state = PLMState();
    NSNumber *lastTerminal = state.lastTerminalRequestBySession[@(sessionId)];
    if (lastTerminal != nil && requestId <= lastTerminal.intValue) {
        return;
    }

    PLMDeliveryState *delivery = [self deliveryStateForSession:sessionId requestId:requestId];
    if (delivery.terminalSeen) {
        return;
    }

    [self flushPendingTokens:delivery];
    delivery.terminalSeen = YES;
    delivery.timerArmed = NO;
    delivery.timerGeneration += 1;
    NSDictionary *event = @{
        @"type": @"error",
        @"sessionId": @(sessionId),
        @"requestId": @(requestId),
        @"code": @"INTERNAL",
        @"message": @"Native inference contract violation",
    };
    [self emitOrDeferEvent:event state:delivery];
    [self retireTerminalDeliveryState:delivery];
}

- (void)discardDeliveryForSession:(int32_t)sessionId
                     exceptRequest:(int32_t)requestId {
    PLMGlobalState *state = PLMState();
    NSString *prefix = [NSString stringWithFormat:@"%d/", sessionId];
    NSString *trustedKey = requestId > POCKETLM_REQUEST_ID_INVALID
        ? PLMRequestKey(sessionId, requestId)
        : nil;
    NSString *pendingKey = state.pendingTokenRequestKey;
    if ([pendingKey hasPrefix:prefix] && ![pendingKey isEqualToString:trustedKey]) {
        state.pendingTokenRequestKey = nil;
    }
    for (NSString *key in [state.deliveryStates.allKeys copy]) {
        if ([key hasPrefix:prefix] && ![key isEqualToString:trustedKey]) {
            [state.deliveryStates removeObjectForKey:key];
        }
    }
    for (NSString *key in [state.openGates.allObjects copy]) {
        if ([key hasPrefix:prefix] && ![key isEqualToString:trustedKey]) {
            [state.openGates removeObject:key];
        }
    }
}

- (void)forceOpenDeliveryForSession:(int32_t)sessionId {
    PLMGlobalState *state = PLMState();
    NSString *prefix = [NSString stringWithFormat:@"%d/", sessionId];
    for (NSString *key in [state.deliveryStates.allKeys copy]) {
        if (![key hasPrefix:prefix]) {
            continue;
        }
        PLMDeliveryState *delivery = state.deliveryStates[key];
        delivery.gateOpen = YES;
        [state.openGates addObject:key];
        NSArray<NSDictionary *> *events = [delivery.deferredEvents copy];
        [delivery.deferredEvents removeAllObjects];
        for (NSDictionary *event in events) {
            [self emitOrDeferEvent:event state:delivery];
        }
        [self retireTerminalDeliveryState:delivery];
    }
}

- (void)cleanupDeliveryMetadataForSession:(int32_t)sessionId {
    PLMGlobalState *state = PLMState();
    NSString *prefix = [NSString stringWithFormat:@"%d/", sessionId];
    if ([state.pendingTokenRequestKey hasPrefix:prefix]) {
        state.pendingTokenRequestKey = nil;
    }
    for (NSString *key in [state.deliveryStates.allKeys copy]) {
        if ([key hasPrefix:prefix]) {
            [state.deliveryStates removeObjectForKey:key];
        }
    }
    for (NSString *key in [state.openGates.allObjects copy]) {
        if ([key hasPrefix:prefix]) {
            [state.openGates removeObject:key];
        }
    }
    [state.lastTerminalRequestBySession removeObjectForKey:@(sessionId)];
}

- (void)scheduleJoinedTeardownBarrierForRecord:(PLMSessionRecord *)record {
    // This method is lifecycle-queue-only. It snapshots and claims every piece
    // of lifecycle-owned state before enqueueing a one-way delivery barrier, so
    // delivery never synchronously waits on lifecycle.
    PLMGlobalState *state = PLMState();
    PLMSessionRecord *current = state.sessions[@(record.sessionId)];
    if (current != record || !record.teardownJoined ||
        record.teardownBarrierScheduled || record.finalizationScheduled) {
        return;
    }

    record.teardownBarrierScheduled = YES;
    BOOL faulted = record.isFaulted;
    BOOL forceGate = record.explicitUnloadRequested || !faulted;
    if (forceGate) {
        // Gate admission and the cleanup barrier are ordered by lifecycle. A
        // gate admitted earlier is already ahead of this barrier on delivery;
        // no gate can be admitted after this point.
        record.gateAdmissionClosed = YES;
        record.finalizationScheduled = YES;
    }

    PLMCallbackContext *faultContext = record.faultContext;
    record.faultContext = nullptr;
    if (faultContext != nullptr) {
        int32_t accepted =
            faultContext->acceptedRequestId.load(std::memory_order_acquire);
        if (accepted > POCKETLM_REQUEST_ID_INVALID) {
            record.faultRequestId = accepted;
        }
    }
    PLMCallbackContext *activeContext = record.activeContext;
    record.activeContext = nullptr;
    int32_t requestId = faulted ? record.faultRequestId : record.activeRequestId;
    int32_t sessionId = record.sessionId;

    dispatch_async(state.deliveryQueue, ^{
        if (faulted) {
            [self discardDeliveryForSession:sessionId exceptRequest:requestId];
        }
        if (requestId > POCKETLM_REQUEST_ID_INVALID) {
            [self ensureTrustedFaultTerminalForSession:sessionId requestId:requestId];
        }

        // Destroy has joined, so callback lifetime ownership can be retired even
        // if the core violated its promise to emit a terminal callback.
        if (faultContext != nullptr) {
            PLMReleaseCallbackReference(faultContext);
            PLMReleaseContext(faultContext); // fault-ticket ownership
        }
        if (activeContext != nullptr) {
            PLMReleaseCallbackReference(activeContext);
            PLMReleaseContext(activeContext); // session active-request ownership
        }

        if (forceGate) {
            [self forceOpenDeliveryForSession:sessionId];
            [self cleanupDeliveryMetadataForSession:sessionId];
        }

        dispatch_async(PLMState().lifecycleQueue, ^{
            PLMGlobalState *lifecycleState = PLMState();
            PLMSessionRecord *latest = lifecycleState.sessions[@(sessionId)];
            if (latest != record) {
                return;
            }
            record.teardownBarrierScheduled = NO;
            if (forceGate) {
                PocketLMVoidCompletion completion = record.unloadCompletion;
                record.unloadCompletion = nil;
                [lifecycleState.sessions removeObjectForKey:@(sessionId)];
                if (completion != nil) {
                    PLMDeliveryAsync(^{ completion(nil); });
                }
                return;
            }

            // Explicit unload may have arrived while the implicit fault barrier
            // was in flight. Its lifecycle close is retained above; schedule a
            // guaranteed follow-up barrier to force delivery and finalize.
            if (record.explicitUnloadRequested) {
                [self scheduleJoinedTeardownBarrierForRecord:record];
            }
        });
    });
}

- (void)scheduleContractFaultForContext:(PLMCallbackContext *)context
                              requestId:(int32_t)requestId
                                  cause:(NSString *)cause {
    if (context == nullptr) {
        return;
    }
    // Acquire the fault-ticket reference before publishing faultScheduled. A
    // concurrent callback that observes the flag may release the callback's
    // lifetime reference immediately, so the ticket must already be visible.
    PLMRetainContext(context);
    if (context->faultScheduled.exchange(true, std::memory_order_acq_rel)) {
        PLMReleaseContext(context);
        return;
    }
    os_log_fault(PLMBridgeLog(), "core callback contract fault for session %d request %d: %{public}@",
                 context->sessionId, requestId, cause);
    int32_t sessionId = context->sessionId;
    // The fault ticket owns the context through destroy + the delivery barrier.
    dispatch_async(PLMState().lifecycleQueue, ^{
        PLMSessionRecord *record = PLMState().sessions[@(sessionId)];
        if (record == nil || record.faultContext != nullptr) {
            PLMReleaseCallbackReference(context);
            PLMReleaseContext(context);
            return;
        }
        record.faulted = YES;
        record.faultContext = context;
        if (!record.teardownStarted) {
            [self beginTeardownForRecord:record];
        } else if (record.teardownJoined) {
            [self scheduleJoinedTeardownBarrierForRecord:record];
        }
    });
}

@end
