#define POCKETLM_BRIDGE_TESTING 1

#import <Foundation/Foundation.h>

#import "PocketLMBridge.h"
#import "FakePocketLMCoreControl.h"

#include "pocketlm_core.h"

#include <atomic>
#include <chrono>
#include <climits>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <string>

static int g_failures = 0;

static void PLMExpect(BOOL condition, NSString *message) {
    if (condition) {
        std::fprintf(stdout, "PASS  %s\n", message.UTF8String);
    } else {
        std::fprintf(stderr, "FAIL  %s\n", message.UTF8String);
        g_failures += 1;
    }
}

static BOOL PLMWait(dispatch_semaphore_t semaphore) {
    return dispatch_semaphore_wait(
        semaphore, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) == 0;
}

@interface PLMEventCollector : NSObject
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *events;
@property(nonatomic, strong) dispatch_semaphore_t tokenSemaphore;
@property(nonatomic, strong) dispatch_semaphore_t terminalSemaphore;
- (PocketLMEventHandler)handler;
- (NSArray<NSDictionary *> *)snapshot;
@end

@implementation PLMEventCollector
- (instancetype)init {
    self = [super init];
    if (self) {
        _events = [NSMutableArray array];
        _tokenSemaphore = dispatch_semaphore_create(0);
        _terminalSemaphore = dispatch_semaphore_create(0);
    }
    return self;
}
- (PocketLMEventHandler)handler {
    return ^(NSDictionary *event) {
        @synchronized (self) {
            [self.events addObject:event];
        }
        NSString *type = event[@"type"];
        if ([type isEqualToString:@"token"]) {
            dispatch_semaphore_signal(self.tokenSemaphore);
        } else if ([type isEqualToString:@"done"] || [type isEqualToString:@"error"]) {
            dispatch_semaphore_signal(self.terminalSemaphore);
        }
    };
}
- (NSArray<NSDictionary *> *)snapshot {
    @synchronized (self) {
        return [self.events copy];
    }
}
@end

@interface PLMThrowingCopyObject : NSObject <NSCopying>
@end

@implementation PLMThrowingCopyObject
- (id)copyWithZone:(__unused NSZone *)zone {
    @throw [NSException exceptionWithName:@"PLMThrowingCopy"
                                   reason:@"copy must not run while request is active"
                                 userInfo:nil];
}
@end

static NSDictionary *PLMConfig(NSString *accelerator) {
    return @{@"contextSize": @2048, @"accelerator": accelerator, @"gpuLayers": @12};
}

static NSDictionary *PLMParams(void) {
    return @{
        @"maxTokens": @256,
        @"temperature": @0.7,
        @"topK": @40,
        @"topP": @0.9,
        @"seed": @(-1),
        @"nThreads": @0,
    };
}

static NSArray *PLMMessages(NSString *mode) {
    return @[
        @{@"role": @"system", @"content": @"You are deterministic."},
        @{@"role": @"user", @"content": mode},
    ];
}

static NSNumber *PLMLoad(NSString *path, NSDictionary *config, NSError **outError) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSNumber *sessionId = nil;
    __block NSError *error = nil;
    [[PocketLMBridge sharedBridge] loadModelAtPath:path
                                           config:config
                                       completion:^(NSNumber *value, NSError *valueError) {
                                           sessionId = value;
                                           error = valueError;
                                           dispatch_semaphore_signal(semaphore);
                                       }];
    PLMExpect(PLMWait(semaphore), @"load completion does not deadlock");
    if (outError != nullptr) {
        *outError = error;
    }
    return sessionId;
}

static NSError *PLMUnload(NSInteger sessionId) {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSError *error = nil;
    [[PocketLMBridge sharedBridge] unloadModel:sessionId completion:^(NSError *value) {
        error = value;
        dispatch_semaphore_signal(semaphore);
    }];
    PLMExpect(PLMWait(semaphore), @"unload completion does not deadlock");
    [PocketLMBridge testingDrainQueues];
    return error;
}

static NSInteger PLMGenerate(PocketLMBridge *bridge, NSInteger sessionId,
                             NSArray *messages, NSDictionary *params) {
    NSInteger requestId = [bridge generateForSession:sessionId
                                            messages:messages
                                              params:params];
    if (requestId > 0) {
        [bridge openDeliveryGateForSession:sessionId requestId:requestId];
    }
    return requestId;
}

static void PLMExpectDiagnosticsContractFault(PocketLMBridge *bridge,
                                              NSString *path,
                                              NSString *accelerator,
                                              dispatch_block_t configureDiagnostics,
                                              NSString *label) {
    NSError *loadError = nil;
    NSNumber *sessionId = PLMLoad(path, PLMConfig(accelerator), &loadError);
    PLMExpect(sessionId != nil && loadError == nil,
              [NSString stringWithFormat:@"%@ loads an isolated session", label]);
    if (sessionId == nil) {
        pocketlm_fake_clear_diagnostics_override();
        return;
    }

    configureDiagnostics();
    int32_t destroysBeforeFault = pocketlm_fake_destroy_count();
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block NSDictionary *diagnostics = nil;
    __block NSError *diagnosticsError = nil;
    [bridge getDiagnosticsForSession:sessionId.integerValue
                          completion:^(NSDictionary *value, NSError *valueError) {
                              diagnostics = value;
                              diagnosticsError = valueError;
                              dispatch_semaphore_signal(semaphore);
                          }];
    PLMExpect(PLMWait(semaphore) && diagnostics == nil &&
              [diagnosticsError.userInfo[PocketLMBridgeErrorCodeKey]
                  isEqualToString:@"INTERNAL"],
              [NSString stringWithFormat:@"%@ rejects with INTERNAL", label]);
    pocketlm_fake_clear_diagnostics_override();

    [PocketLMBridge testingDrainQueues];
    PLMExpect(pocketlm_fake_destroy_count() == destroysBeforeFault + 1,
              [NSString stringWithFormat:@"%@ tears down the native session", label]);
    int32_t generateCallsBeforeFence = pocketlm_fake_generate_call_count();
    PLMExpect([bridge generateForSession:sessionId.integerValue
                                messages:PLMMessages(@"sync")
                                  params:PLMParams()] == POCKETLM_GENERATE_SHUTTING_DOWN &&
              pocketlm_fake_generate_call_count() == generateCallsBeforeFence,
              [NSString stringWithFormat:@"%@ retains a shutdown tombstone", label]);
    PLMExpect(PLMUnload(sessionId.integerValue) == nil,
              [NSString stringWithFormat:@"%@ explicit unload removes the tombstone", label]);
    PLMExpect([bridge generateForSession:sessionId.integerValue
                                messages:PLMMessages(@"sync")
                                  params:PLMParams()] == POCKETLM_GENERATE_INVALID_ARGUMENT,
              [NSString stringWithFormat:@"%@ becomes stale after awaited unload", label]);
}

static NSArray<NSDictionary *> *PLMRun(NSInteger sessionId, NSString *mode,
                                       NSInteger *outRequestId) {
    PLMEventCollector *collector = [[PLMEventCollector alloc] init];
    uint64_t token = [[PocketLMBridge sharedBridge]
        subscribeWithEventHandler:[collector handler]];
    NSInteger requestId = PLMGenerate([PocketLMBridge sharedBridge], sessionId,
                                      PLMMessages(mode), PLMParams());
    PLMExpect(requestId > 0, [NSString stringWithFormat:@"%@ request is accepted", mode]);
    PLMExpect(PLMWait(collector.terminalSemaphore),
              [NSString stringWithFormat:@"%@ reaches one terminal", mode]);
    [PocketLMBridge testingDrainQueues];
    [[PocketLMBridge sharedBridge] unsubscribeEventHandlerWithToken:token];
    if (outRequestId != nullptr) {
        *outRequestId = requestId;
    }
    return [collector snapshot];
}

static NSDictionary *PLMFirstEventOfType(NSArray<NSDictionary *> *events, NSString *type) {
    for (NSDictionary *event in events) {
        if ([event[@"type"] isEqualToString:type]) {
            return event;
        }
    }
    return nil;
}

static NSUInteger PLMTerminalCount(NSArray<NSDictionary *> *events) {
    NSUInteger count = 0;
    for (NSDictionary *event in events) {
        NSString *type = event[@"type"];
        if ([type isEqualToString:@"done"] || [type isEqualToString:@"error"]) {
            count += 1;
        }
    }
    return count;
}

static void PLMExpectTrustedContractFault(NSArray<NSDictionary *> *events,
                                          NSNumber *sessionId,
                                          NSInteger requestId,
                                          NSString *label) {
    NSDictionary *terminal = PLMFirstEventOfType(events, @"error");
    PLMExpect(events.count == 1 && PLMTerminalCount(events) == 1,
              [NSString stringWithFormat:@"%@ emits exactly one terminal event", label]);
    PLMExpect([terminal[@"sessionId"] isEqual:sessionId] &&
              [terminal[@"requestId"] integerValue] == requestId &&
              [terminal[@"code"] isEqualToString:@"INTERNAL"] &&
              [terminal[@"message"] isEqualToString:@"Native inference contract violation"],
              [NSString stringWithFormat:@"%@ emits only trusted bridge fault fields", label]);
}

static NSUInteger PLMSummedTokenCount(NSArray<NSDictionary *> *events) {
    NSUInteger total = 0;
    for (NSDictionary *event in events) {
        if ([event[@"type"] isEqualToString:@"token"]) {
            total += [event[@"tokenCount"] unsignedIntegerValue];
        }
    }
    return total;
}

int PocketLMRunBridgeHarness(void) {
    @autoreleasepool {
        pocketlm_fake_reset_counters();
        PocketLMBridge *bridge = [PocketLMBridge sharedBridge];
        PLMExpect([[PocketLMBridge version] isEqualToString:@"fake-pocketlm-core/2.1"],
                  @"version crosses the C boundary");

        __block NSError *error = nil;
        NSNumber *sessionOne = PLMLoad(@"relative.gguf", PLMConfig(@"auto"), &error);
        PLMExpect(sessionOne == nil &&
                  [error.userInfo[PocketLMBridgeErrorCodeKey] isEqualToString:@"INVALID_ARGUMENT"],
                  @"relative model paths reject with INVALID_ARGUMENT");

        error = nil;
        PLMLoad(@"/tmp/load-fail.gguf", PLMConfig(@"auto"), &error);
        PLMExpect([error.userInfo[PocketLMBridgeErrorCodeKey]
                      isEqualToString:@"MODEL_LOAD_FAILED"],
                  @"create errors retain the frozen uppercase code");

        error = nil;
        sessionOne = PLMLoad(@"/tmp/one.gguf", PLMConfig(@"auto"), &error);
        NSNumber *sessionTwo = PLMLoad(@"/tmp/two.gguf", PLMConfig(@"cpu"), &error);
        PLMExpect(sessionOne.intValue == 1 && sessionTwo.intValue == 2,
                  @"session IDs are process-scoped monotonic values");

        dispatch_semaphore_t diagnosticsSemaphore = dispatch_semaphore_create(0);
        __block NSDictionary *diagnostics = nil;
        [bridge getDiagnosticsForSession:sessionOne.integerValue
                              completion:^(NSDictionary *value, NSError *valueError) {
                                  diagnostics = value;
                                  error = valueError;
                                  dispatch_semaphore_signal(diagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(diagnosticsSemaphore), @"diagnostics completion does not deadlock");
        PLMExpect(error == nil &&
                  [diagnostics[@"requestedAccelerator"] isEqualToString:@"auto"] &&
                  [diagnostics[@"selectedAccelerator"] isEqualToString:@"metal"] &&
                  [diagnostics[@"contextSize"] intValue] == 2048 &&
                  [diagnostics[@"kqvOffloaded"] boolValue],
                  @"diagnostics map every frozen backend field");

        pocketlm_fake_set_diagnostics_override(POCKETLM_ACCELERATOR_CPU, -1);
        pocketlm_fake_set_diagnostics_kqv(0);
        diagnosticsSemaphore = dispatch_semaphore_create(0);
        diagnostics = nil;
        error = nil;
        [bridge getDiagnosticsForSession:sessionOne.integerValue
                              completion:^(NSDictionary *value, NSError *valueError) {
                                  diagnostics = value;
                                  error = valueError;
                                  dispatch_semaphore_signal(diagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(diagnosticsSemaphore) && error == nil &&
                  [diagnostics[@"requestedAccelerator"] isEqualToString:@"auto"] &&
                  [diagnostics[@"selectedAccelerator"] isEqualToString:@"cpu"] &&
                  [diagnostics[@"offloadedLayers"] intValue] == -1 &&
                  ![diagnostics[@"kqvOffloaded"] boolValue],
                  @"AUTO diagnostics permit an honest CPU fallback with unknown offload");
        pocketlm_fake_clear_diagnostics_override();

        pocketlm_fake_set_diagnostics_peak_rss(9007199254740991LL);
        diagnosticsSemaphore = dispatch_semaphore_create(0);
        diagnostics = nil;
        error = nil;
        [bridge getDiagnosticsForSession:sessionOne.integerValue
                              completion:^(NSDictionary *value, NSError *valueError) {
                                  diagnostics = value;
                                  error = valueError;
                                  dispatch_semaphore_signal(diagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(diagnosticsSemaphore) && error == nil &&
                  [diagnostics[@"peakRssBytes"] longLongValue] == 9007199254740991LL,
                  @"diagnostics accept the JavaScript maximum safe integer");

        pocketlm_fake_clear_diagnostics_override();

        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-selected-auto.gguf", @"auto", ^{
                pocketlm_fake_set_diagnostics_override(POCKETLM_ACCELERATOR_AUTO, 0);
                pocketlm_fake_set_diagnostics_kqv(0);
            }, @"selected AUTO diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-kqv.gguf", @"auto", ^{
                pocketlm_fake_set_diagnostics_kqv(2);
            }, @"non-boolean KQV diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-peak-rss.gguf", @"auto", ^{
                pocketlm_fake_set_diagnostics_peak_rss(9007199254740992LL);
            }, @"out-of-range peak RSS diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-requested.gguf", @"auto", ^{
                pocketlm_fake_set_diagnostics_requested(POCKETLM_ACCELERATOR_METAL);
            }, @"changed requested accelerator diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-metal-fallback.gguf", @"metal", ^{
                pocketlm_fake_set_diagnostics_override(POCKETLM_ACCELERATOR_CPU, 0);
                pocketlm_fake_set_diagnostics_kqv(0);
            }, @"METAL-to-CPU diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-cpu-selection.gguf", @"cpu", ^{
                pocketlm_fake_set_diagnostics_override(POCKETLM_ACCELERATOR_METAL, 0);
            }, @"CPU-to-Metal diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-cpu-layers.gguf", @"auto", ^{
                pocketlm_fake_set_diagnostics_override(POCKETLM_ACCELERATOR_CPU, 1);
                pocketlm_fake_set_diagnostics_kqv(0);
            }, @"CPU positive-offload diagnostics fault");
        PLMExpectDiagnosticsContractFault(
            bridge, @"/tmp/diagnostics-cpu-kqv.gguf", @"auto", ^{
                pocketlm_fake_set_diagnostics_override(POCKETLM_ACCELERATOR_CPU, 0);
                pocketlm_fake_set_diagnostics_kqv(1);
            }, @"CPU KQV-offload diagnostics fault");

        NSNumber *activeDiagnosticsSession =
            PLMLoad(@"/tmp/diagnostics-active.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *activeDiagnosticsCollector = [[PLMEventCollector alloc] init];
        uint64_t activeDiagnosticsToken =
            [bridge subscribeWithEventHandler:[activeDiagnosticsCollector handler]];
        NSInteger activeDiagnosticsRequest =
            PLMGenerate(bridge, activeDiagnosticsSession.integerValue,
                        PLMMessages(@"hold"), PLMParams());
        PLMExpect(activeDiagnosticsRequest > 0,
                  @"active diagnostics-fault request is admitted");
        pocketlm_fake_set_diagnostics_kqv(2);
        diagnosticsSemaphore = dispatch_semaphore_create(0);
        diagnostics = nil;
        error = nil;
        [bridge getDiagnosticsForSession:activeDiagnosticsSession.integerValue
                              completion:^(NSDictionary *value, NSError *valueError) {
                                  diagnostics = value;
                                  error = valueError;
                                  dispatch_semaphore_signal(diagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(diagnosticsSemaphore) && diagnostics == nil &&
                  [error.userInfo[PocketLMBridgeErrorCodeKey] isEqualToString:@"INTERNAL"],
                  @"active malformed diagnostics reject with INTERNAL");
        pocketlm_fake_clear_diagnostics_override();
        PLMExpect(PLMWait(activeDiagnosticsCollector.terminalSemaphore),
                  @"active diagnostics fault reaches a trusted terminal");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([activeDiagnosticsCollector snapshot],
                                      activeDiagnosticsSession,
                                      activeDiagnosticsRequest,
                                      @"active diagnostics fault");
        int32_t activeDiagnosticsGenerateCalls = pocketlm_fake_generate_call_count();
        PLMExpect([bridge generateForSession:activeDiagnosticsSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] ==
                      POCKETLM_GENERATE_SHUTTING_DOWN &&
                  pocketlm_fake_generate_call_count() == activeDiagnosticsGenerateCalls,
                  @"active diagnostics fault retains its shutdown tombstone");
        PLMExpect(PLMUnload(activeDiagnosticsSession.integerValue) == nil,
                  @"active diagnostics tombstone unloads after its terminal");
        [bridge unsubscribeEventHandlerWithToken:activeDiagnosticsToken];

        NSNumber *silentDiagnosticsSession =
            PLMLoad(@"/tmp/diagnostics-no-terminal.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *silentDiagnosticsCollector = [[PLMEventCollector alloc] init];
        uint64_t silentDiagnosticsToken =
            [bridge subscribeWithEventHandler:[silentDiagnosticsCollector handler]];
        uint64_t contextsBeforeSilentDiagnostics =
            [PocketLMBridge testingLiveCallbackContextCount];
        NSInteger silentDiagnosticsRequest =
            PLMGenerate(bridge, silentDiagnosticsSession.integerValue,
                        PLMMessages(@"no-terminal"), PLMParams());
        PLMExpect(silentDiagnosticsRequest > 0 &&
                  [PocketLMBridge testingLiveCallbackContextCount] ==
                      contextsBeforeSilentDiagnostics + 1,
                  @"silent diagnostics-fault request retains its callback context");
        pocketlm_fake_set_diagnostics_peak_rss(9007199254740992LL);
        diagnosticsSemaphore = dispatch_semaphore_create(0);
        diagnostics = nil;
        error = nil;
        [bridge getDiagnosticsForSession:silentDiagnosticsSession.integerValue
                              completion:^(NSDictionary *value, NSError *valueError) {
                                  diagnostics = value;
                                  error = valueError;
                                  dispatch_semaphore_signal(diagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(diagnosticsSemaphore) && diagnostics == nil &&
                  [error.userInfo[PocketLMBridgeErrorCodeKey] isEqualToString:@"INTERNAL"],
                  @"silent malformed diagnostics reject with INTERNAL");
        pocketlm_fake_clear_diagnostics_override();
        PLMExpect(PLMWait(silentDiagnosticsCollector.terminalSemaphore),
                  @"silent diagnostics fault synthesizes a trusted terminal");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([silentDiagnosticsCollector snapshot],
                                      silentDiagnosticsSession,
                                      silentDiagnosticsRequest,
                                      @"silent diagnostics fault");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] ==
                      contextsBeforeSilentDiagnostics,
                  @"joined diagnostics teardown releases a missing callback lifetime");
        PLMExpect([bridge generateForSession:silentDiagnosticsSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] ==
                      POCKETLM_GENERATE_SHUTTING_DOWN,
                  @"silent diagnostics fault retains its shutdown tombstone");
        PLMExpect(PLMUnload(silentDiagnosticsSession.integerValue) == nil,
                  @"silent diagnostics tombstone unloads after its terminal");
        [bridge unsubscribeEventHandlerWithToken:silentDiagnosticsToken];

        NSMutableDictionary *invalidParams = [PLMParams() mutableCopy];
        invalidParams[@"temperature"] = @(NAN);
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:invalidParams] == -1,
                  @"non-finite generation input rejects synchronously");
        invalidParams = [PLMParams() mutableCopy];
        invalidParams[@"maxTokens"] = @1.5;
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:invalidParams] == -1,
                  @"fractional Int32 generation input rejects synchronously");
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:@[@{@"role": @"assistant", @"content": @"bad"}]
                                      params:PLMParams()] == -1,
                  @"invalid chat shape rejects before the C callback boundary");
        unichar embeddedNulCharacters[] = {'a', 0, 'b'};
        NSString *embeddedNul = [NSString stringWithCharacters:embeddedNulCharacters length:3];
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:@[@{@"role": @"user", @"content": embeddedNul}]
                                      params:PLMParams()] == -1,
                  @"embedded NUL content rejects before the C string boundary");

        int32_t callbacksBeforeReject = pocketlm_fake_callback_count();
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:PLMMessages(@"reject")
                                      params:PLMParams()] == -2,
                  @"C rejection value passes through unchanged");
        [PocketLMBridge testingDrainQueues];
        PLMExpect(pocketlm_fake_callback_count() == callbacksBeforeReject &&
                  [PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"rejected generation neither calls back nor retains context");

        int32_t callbacksBeforeOOM = pocketlm_fake_callback_count();
        [PocketLMBridge testingFailNextGenerateAllocation];
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == -4,
                  @"request-copy allocation failure rejects synchronously with OOM");
        [PocketLMBridge testingDrainQueues];
        PLMExpect(pocketlm_fake_callback_count() == callbacksBeforeOOM &&
                  [PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"allocation rejection neither calls back nor leaks callback context");

        // A native destroy may block while joining a worker. The lifecycle queue
        // must remain available to fence the target and serve unrelated sessions.
        NSNumber *blockedUnloadSession =
            PLMLoad(@"/tmp/blocked-unload.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *blockedUnloadCollector = [[PLMEventCollector alloc] init];
        uint64_t blockedUnloadToken =
            [bridge subscribeWithEventHandler:[blockedUnloadCollector handler]];
        NSInteger blockedUnloadRequest =
            PLMGenerate(bridge, blockedUnloadSession.integerValue,
                        PLMMessages(@"hold"), PLMParams());
        PLMExpect(blockedUnloadRequest > 0,
                  @"blocked-destroy session starts an active request");
        int32_t destroyStartedBefore = pocketlm_fake_destroy_started_count();
        pocketlm_fake_set_destroy_blocked(1);
        dispatch_semaphore_t blockedUnloadCompletion = dispatch_semaphore_create(0);
        __block NSError *blockedUnloadError = nil;
        auto blockedUnloadResolved = std::make_shared<std::atomic<bool>>(false);
        [bridge unloadModel:blockedUnloadSession.integerValue completion:^(NSError *value) {
            blockedUnloadError = value;
            blockedUnloadResolved->store(true, std::memory_order_release);
            dispatch_semaphore_signal(blockedUnloadCompletion);
        }];
        PLMExpect(pocketlm_fake_wait_for_destroy_started(destroyStartedBefore + 1, 3000) == 1,
                  @"teardown reaches the dedicated destroy queue");
        BOOL blockedTerminalArrived = PLMWait(blockedUnloadCollector.terminalSemaphore);
        NSDictionary *blockedDone =
            PLMFirstEventOfType([blockedUnloadCollector snapshot], @"done");
        PLMExpect(blockedTerminalArrived &&
                  [blockedDone[@"reason"] isEqualToString:@"cancelled"],
                  @"teardown cancellation reaches terminal while destroy is blocked");
        [bridge unsubscribeEventHandlerWithToken:blockedUnloadToken];

        int32_t generateCallsBeforeFence = pocketlm_fake_generate_call_count();
        NSInteger fencedGenerate = [bridge generateForSession:blockedUnloadSession.integerValue
                                                      messages:PLMMessages(@"sync")
                                                        params:PLMParams()];
        PLMExpect(fencedGenerate == POCKETLM_GENERATE_SHUTTING_DOWN &&
                  pocketlm_fake_generate_call_count() == generateCallsBeforeFence,
                  @"generate returns SHUTTING_DOWN without touching a detached handle");

        int32_t cancelCallsBeforeFence = pocketlm_fake_cancel_call_count();
        int32_t diagnosticsCallsBeforeFence = pocketlm_fake_diagnostics_call_count();
        [bridge cancelSession:blockedUnloadSession.integerValue requestId:1];
        dispatch_semaphore_t fencedDiagnosticsSemaphore = dispatch_semaphore_create(0);
        __block NSDictionary *fencedDiagnostics = nil;
        __block NSError *fencedDiagnosticsError = nil;
        [bridge getDiagnosticsForSession:blockedUnloadSession.integerValue
                              completion:^(NSDictionary *value, NSError *valueError) {
                                  fencedDiagnostics = value;
                                  fencedDiagnosticsError = valueError;
                                  dispatch_semaphore_signal(fencedDiagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(fencedDiagnosticsSemaphore) && fencedDiagnostics == nil &&
                  [fencedDiagnosticsError.userInfo[PocketLMBridgeErrorCodeKey]
                      isEqualToString:@"SESSION_NOT_FOUND"] &&
                  pocketlm_fake_cancel_call_count() == cancelCallsBeforeFence &&
                  pocketlm_fake_diagnostics_call_count() == diagnosticsCallsBeforeFence,
                  @"cancel and diagnostics fence the handle while destroy is blocked");

        PLMEventCollector *unrelatedCollector = [[PLMEventCollector alloc] init];
        uint64_t unrelatedToken =
            [bridge subscribeWithEventHandler:[unrelatedCollector handler]];
        NSInteger unrelatedRequest = PLMGenerate(bridge, sessionOne.integerValue,
                                                 PLMMessages(@"sync"), PLMParams());
        PLMExpect(unrelatedRequest > 0 && PLMWait(unrelatedCollector.terminalSemaphore) &&
                  PLMFirstEventOfType([unrelatedCollector snapshot], @"done") != nil,
                  @"an unrelated session progresses while destroy is blocked");
        [bridge unsubscribeEventHandlerWithToken:unrelatedToken];
        PLMExpect(!blockedUnloadResolved->load(std::memory_order_acquire),
                  @"unload remains pending until native destroy joins");

        pocketlm_fake_set_destroy_blocked(0);
        PLMExpect(PLMWait(blockedUnloadCompletion) && blockedUnloadError == nil,
                  @"unload resolves after the destroy barrier is released");
        [PocketLMBridge testingDrainQueues];
        PLMExpect([bridge generateForSession:blockedUnloadSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_INVALID_ARGUMENT,
                  @"generate returns INVALID_ARGUMENT after unload removes the record");

        NSNumber *cancelExceptionSession =
            PLMLoad(@"/tmp/cancel-exception.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *cancelExceptionCollector = [[PLMEventCollector alloc] init];
        uint64_t cancelExceptionToken =
            [bridge subscribeWithEventHandler:[cancelExceptionCollector handler]];
        NSInteger cancelExceptionRequest =
            PLMGenerate(bridge, cancelExceptionSession.integerValue,
                        PLMMessages(@"hold"), PLMParams());
        int32_t destroysBeforeCancelException = pocketlm_fake_destroy_count();
        int32_t cancelsBeforeCancelException = pocketlm_fake_cancel_call_count();
        pocketlm_fake_throw_next_cancel();
        NSError *cancelExceptionUnloadError = PLMUnload(cancelExceptionSession.integerValue);
        NSDictionary *cancelExceptionDone =
            PLMFirstEventOfType([cancelExceptionCollector snapshot], @"done");
        PLMExpect(cancelExceptionRequest > 0 && cancelExceptionUnloadError == nil &&
                  PLMWait(cancelExceptionCollector.terminalSemaphore) &&
                  [cancelExceptionDone[@"reason"] isEqualToString:@"cancelled"] &&
                  pocketlm_fake_cancel_call_count() == cancelsBeforeCancelException + 1 &&
                  pocketlm_fake_destroy_count() == destroysBeforeCancelException + 1,
                  @"cancel exception is isolated and cannot skip destroy/join");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"cancel exception teardown releases its callback context");
        [bridge unsubscribeEventHandlerWithToken:cancelExceptionToken];

        // A malformed synchronous terminal must be converted only after destroy
        // joins, and remain behind the same explicit return gate as valid events.
        NSNumber *malformedGateSession =
            PLMLoad(@"/tmp/malformed-gated.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *malformedGateCollector = [[PLMEventCollector alloc] init];
        uint64_t malformedGateToken =
            [bridge subscribeWithEventHandler:[malformedGateCollector handler]];
        NSInteger malformedGateRequest =
            [bridge generateForSession:malformedGateSession.integerValue
                              messages:PLMMessages(@"malformed-done-null")
                                params:PLMParams()];
        PLMExpect(malformedGateRequest > 0,
                  @"malformed synchronous DONE still returns its accepted request ID");
        [PocketLMBridge testingDrainQueues];
        PLMExpect([malformedGateCollector snapshot].count == 0,
                  @"trusted replacement terminal remains behind the return gate");
        [bridge openDeliveryGateForSession:malformedGateSession.integerValue
                                  requestId:malformedGateRequest];
        PLMExpect(PLMWait(malformedGateCollector.terminalSemaphore),
                  @"opening the gate releases the trusted replacement terminal");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([malformedGateCollector snapshot], malformedGateSession,
                                      malformedGateRequest, @"malformed DONE");
        PLMExpect([bridge generateForSession:malformedGateSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_SHUTTING_DOWN,
                  @"fault tombstone rejects generate with SHUTTING_DOWN");

        int32_t cancelCallsBeforeFault = pocketlm_fake_cancel_call_count();
        int32_t diagnosticsCallsBeforeFault = pocketlm_fake_diagnostics_call_count();
        [bridge cancelSession:malformedGateSession.integerValue
                    requestId:malformedGateRequest];
        dispatch_semaphore_t faultDiagnosticsSemaphore = dispatch_semaphore_create(0);
        __block NSError *faultDiagnosticsError = nil;
        [bridge getDiagnosticsForSession:malformedGateSession.integerValue
                              completion:^(__unused NSDictionary *value, NSError *valueError) {
                                  faultDiagnosticsError = valueError;
                                  dispatch_semaphore_signal(faultDiagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(faultDiagnosticsSemaphore) &&
                  [faultDiagnosticsError.userInfo[PocketLMBridgeErrorCodeKey]
                      isEqualToString:@"SESSION_NOT_FOUND"] &&
                  pocketlm_fake_cancel_call_count() == cancelCallsBeforeFault &&
                  pocketlm_fake_diagnostics_call_count() == diagnosticsCallsBeforeFault,
                  @"fault tombstone rejects diagnostics and makes cancel a native no-op");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0 &&
                  [PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"gated fault retires callback, delivery state, and gate exactly once");
        [bridge unsubscribeEventHandlerWithToken:malformedGateToken];
        PLMExpect(PLMUnload(malformedGateSession.integerValue) == nil,
                  @"explicit unload removes the retained fault tombstone");
        PLMExpect([bridge generateForSession:malformedGateSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_INVALID_ARGUMENT,
                  @"fault tombstone becomes stale only after explicit unload resolves");

        // Explicit unload is also a legal gate opener. Its completion must wait
        // until the bridge-generated terminal has been delivered.
        NSNumber *malformedAwaitedSession =
            PLMLoad(@"/tmp/malformed-awaited.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *malformedAwaitedCollector = [[PLMEventCollector alloc] init];
        auto awaitedTerminalSeen = std::make_shared<std::atomic<bool>>(false);
        PocketLMEventHandler awaitedCollectorHandler = [malformedAwaitedCollector handler];
        uint64_t malformedAwaitedToken = [bridge subscribeWithEventHandler:^(NSDictionary *event) {
            awaitedCollectorHandler(event);
            NSString *type = event[@"type"];
            if ([type isEqualToString:@"done"] || [type isEqualToString:@"error"]) {
                awaitedTerminalSeen->store(true, std::memory_order_release);
            }
        }];
        NSInteger malformedAwaitedRequest =
            [bridge generateForSession:malformedAwaitedSession.integerValue
                              messages:PLMMessages(@"malformed-error-null")
                                params:PLMParams()];
        dispatch_semaphore_t malformedAwaitedUnload = dispatch_semaphore_create(0);
        auto awaitedTerminalBeforeUnload = std::make_shared<std::atomic<bool>>(false);
        __block NSError *malformedAwaitedUnloadError = nil;
        [bridge unloadModel:malformedAwaitedSession.integerValue completion:^(NSError *value) {
            malformedAwaitedUnloadError = value;
            awaitedTerminalBeforeUnload->store(
                awaitedTerminalSeen->load(std::memory_order_acquire),
                std::memory_order_release);
            dispatch_semaphore_signal(malformedAwaitedUnload);
        }];
        PLMExpect(malformedAwaitedRequest > 0 && PLMWait(malformedAwaitedUnload) &&
                  malformedAwaitedUnloadError == nil &&
                  awaitedTerminalBeforeUnload->load(std::memory_order_acquire),
                  @"awaited unload delivers a trusted terminal before resolving");
        PLMExpect(PLMWait(malformedAwaitedCollector.terminalSemaphore),
                  @"awaited unload emits one observable terminal");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([malformedAwaitedCollector snapshot],
                                      malformedAwaitedSession, malformedAwaitedRequest,
                                      @"malformed ERROR");
        [bridge unsubscribeEventHandlerWithToken:malformedAwaitedToken];
        PLMExpect([bridge generateForSession:malformedAwaitedSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_INVALID_ARGUMENT,
                  @"awaited unload removes the malformed ERROR session");

        // If destroy joins without any terminal callback, the accepted request's
        // record-owned context still provides safe correlation and cleanup.
        NSNumber *noTerminalSession =
            PLMLoad(@"/tmp/no-terminal.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *noTerminalCollector = [[PLMEventCollector alloc] init];
        PocketLMEventHandler noTerminalCollectorHandler = [noTerminalCollector handler];
        auto noTerminalObserved = std::make_shared<std::atomic<bool>>(false);
        uint64_t noTerminalToken = [bridge subscribeWithEventHandler:^(NSDictionary *event) {
            NSString *type = event[@"type"];
            if ([type isEqualToString:@"done"] || [type isEqualToString:@"error"]) {
                noTerminalObserved->store(true, std::memory_order_release);
            }
            noTerminalCollectorHandler(event);
        }];
        NSInteger noTerminalRequest = PLMGenerate(bridge, noTerminalSession.integerValue,
                                                 PLMMessages(@"no-terminal"), PLMParams());
        dispatch_semaphore_t noTerminalUnloadCompletion = dispatch_semaphore_create(0);
        auto noTerminalBeforeUnload = std::make_shared<std::atomic<bool>>(false);
        __block NSError *noTerminalUnloadError = nil;
        [bridge unloadModel:noTerminalSession.integerValue completion:^(NSError *value) {
            noTerminalUnloadError = value;
            noTerminalBeforeUnload->store(
                noTerminalObserved->load(std::memory_order_acquire),
                std::memory_order_release);
            dispatch_semaphore_signal(noTerminalUnloadCompletion);
        }];
        PLMExpect(noTerminalRequest > 0 && PLMWait(noTerminalCollector.terminalSemaphore) &&
                  PLMWait(noTerminalUnloadCompletion) && noTerminalUnloadError == nil &&
                  noTerminalBeforeUnload->load(std::memory_order_acquire),
                  @"missing core terminal is synthesized before unload resolves");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([noTerminalCollector snapshot], noTerminalSession,
                                      noTerminalRequest, @"missing terminal callback");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"missing terminal callback releases its active context after join");
        [bridge unsubscribeEventHandlerWithToken:noTerminalToken];
        PLMExpect([bridge generateForSession:noTerminalSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_INVALID_ARGUMENT,
                  @"missing-terminal unload removes the session record");

        NSNumber *invalidRequestSession =
            PLMLoad(@"/tmp/invalid-request.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *invalidRequestCollector = [[PLMEventCollector alloc] init];
        PocketLMEventHandler invalidRequestCollectorHandler = [invalidRequestCollector handler];
        dispatch_semaphore_t invalidRequestUnloadCompletion = dispatch_semaphore_create(0);
        __block NSError *invalidRequestUnloadError = nil;
        auto invalidUnloadRequested = std::make_shared<std::atomic<bool>>(false);
        auto invalidCompletionReenteredDelivery =
            std::make_shared<std::atomic<bool>>(false);
        uint64_t invalidRequestToken = [bridge subscribeWithEventHandler:^(NSDictionary *event) {
            invalidRequestCollectorHandler(event);
            NSString *type = event[@"type"];
            if (([type isEqualToString:@"done"] || [type isEqualToString:@"error"]) &&
                !invalidUnloadRequested->exchange(true, std::memory_order_acq_rel)) {
                [bridge unloadModel:invalidRequestSession.integerValue
                         completion:^(NSError *value) {
                             invalidRequestUnloadError = value;
                             uint64_t reentryToken = [bridge
                                 subscribeWithEventHandler:^(__unused NSDictionary *unused) {}];
                             [bridge unsubscribeEventHandlerWithToken:reentryToken];
                             invalidCompletionReenteredDelivery->store(
                                 reentryToken != 0, std::memory_order_release);
                             dispatch_semaphore_signal(invalidRequestUnloadCompletion);
                         }];
                // This call occurs after explicit unload closes gate admission.
                // It must not enqueue an orphan gate behind final cleanup.
                [bridge openDeliveryGateForSession:invalidRequestSession.integerValue
                                          requestId:[event[@"requestId"] integerValue]];
            }
        }];
        NSInteger acceptedRequest = PLMGenerate(bridge, invalidRequestSession.integerValue,
                                                PLMMessages(@"invalid-request-id"), PLMParams());
        PLMExpect(acceptedRequest > 0 && PLMWait(invalidRequestCollector.terminalSemaphore),
                  @"invalid callback ID faults without losing the accepted request ID");
        PLMExpect(PLMWait(invalidRequestUnloadCompletion) &&
                  invalidRequestUnloadError == nil &&
                  invalidCompletionReenteredDelivery->load(std::memory_order_acquire),
                  @"explicit unload during fault delivery finalizes without reentry deadlock");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([invalidRequestCollector snapshot], invalidRequestSession,
                                      acceptedRequest, @"invalid callback request ID");
        [bridge unsubscribeEventHandlerWithToken:invalidRequestToken];
        PLMExpect([bridge generateForSession:invalidRequestSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_INVALID_ARGUMENT &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"finalization removes the session without an orphan post-close gate");

        // Request-ID validation is a two-sided handshake. First prove the
        // callback-publishes-first side with a wrong positive ID emitted before
        // pocketlm_generate_v2 returns.
        NSNumber *wrongSyncSession =
            PLMLoad(@"/tmp/wrong-sync-id.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *wrongSyncCollector = [[PLMEventCollector alloc] init];
        uint64_t wrongSyncToken =
            [bridge subscribeWithEventHandler:[wrongSyncCollector handler]];
        NSInteger wrongSyncRequest =
            PLMGenerate(bridge, wrongSyncSession.integerValue,
                        PLMMessages(@"wrong-request-id-sync"), PLMParams());
        PLMExpect(wrongSyncRequest > 0 && PLMWait(wrongSyncCollector.terminalSemaphore),
                  @"pre-return wrong positive callback ID reaches a trusted terminal");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([wrongSyncCollector snapshot], wrongSyncSession,
                                      wrongSyncRequest, @"pre-return wrong callback ID");
        PLMExpect([bridge generateForSession:wrongSyncSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_SHUTTING_DOWN,
                  @"pre-return wrong ID retires the accepted request without BUSY");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0 &&
                  [PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"pre-return wrong ID drains context, delivery state, and gate");
        [bridge unsubscribeEventHandlerWithToken:wrongSyncToken];
        PLMExpect(PLMUnload(wrongSyncSession.integerValue) == nil,
                  @"pre-return wrong-ID tombstone unloads explicitly");

        // Now prove generate-publishes-first. The fake returns the accepted ID;
        // PLMGenerate opens its delivery gate; only an explicit latch release
        // then permits a delayed worker to emit a different positive ID.
        NSNumber *wrongDelayedSession =
            PLMLoad(@"/tmp/wrong-delayed-id.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *wrongDelayedCollector = [[PLMEventCollector alloc] init];
        uint64_t wrongDelayedToken =
            [bridge subscribeWithEventHandler:[wrongDelayedCollector handler]];
        NSInteger wrongDelayedRequest =
            PLMGenerate(bridge, wrongDelayedSession.integerValue,
                        PLMMessages(@"wrong-request-id-delayed"), PLMParams());
        [PocketLMBridge testingDrainQueues];
        PLMExpect(wrongDelayedRequest > 0 &&
                  [wrongDelayedCollector snapshot].count == 0,
                  @"delayed wrong ID waits until generate returned and its gate opened");
        pocketlm_fake_release_held_requests();
        PLMExpect(PLMWait(wrongDelayedCollector.terminalSemaphore),
                  @"post-return wrong positive callback ID reaches a trusted terminal");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([wrongDelayedCollector snapshot], wrongDelayedSession,
                                      wrongDelayedRequest, @"post-return wrong callback ID");
        PLMExpect([bridge generateForSession:wrongDelayedSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_SHUTTING_DOWN,
                  @"post-return wrong ID retires the accepted request without BUSY");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0 &&
                  [PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"post-return wrong ID drains context, delivery state, and gate");
        [bridge unsubscribeEventHandlerWithToken:wrongDelayedToken];
        PLMExpect(PLMUnload(wrongDelayedSession.integerValue) == nil,
                  @"post-return wrong-ID tombstone unloads explicitly");

        NSNumber *queuedTerminalSession =
            PLMLoad(@"/tmp/queued-terminal.gguf", PLMConfig(@"auto"), &error);
        PLMEventCollector *queuedTerminalCollector = [[PLMEventCollector alloc] init];
        uint64_t queuedTerminalToken =
            [bridge subscribeWithEventHandler:[queuedTerminalCollector handler]];
        NSInteger queuedTerminalRequest =
            PLMGenerate(bridge, queuedTerminalSession.integerValue,
                        PLMMessages(@"gap-then-done"), PLMParams());
        PLMExpect(queuedTerminalRequest > 0 &&
                  PLMWait(queuedTerminalCollector.terminalSemaphore),
                  @"token-gap fault reaches one terminal despite a queued valid DONE");
        [PocketLMBridge testingDrainQueues];
        PLMExpectTrustedContractFault([queuedTerminalCollector snapshot], queuedTerminalSession,
                                      queuedTerminalRequest, @"queued terminal race");
        [bridge unsubscribeEventHandlerWithToken:queuedTerminalToken];
        PLMExpect(PLMUnload(queuedTerminalSession.integerValue) == nil,
                  @"queued terminal race session explicitly unloads");

        NSArray<NSString *> *unsafeStatModes = @[
            @"over-safe-prefill", @"over-safe-decode", @"over-safe-peak-rss",
        ];
        for (NSString *mode in unsafeStatModes) {
            NSNumber *unsafeStatSession =
                PLMLoad([NSString stringWithFormat:@"/tmp/%@.gguf", mode],
                        PLMConfig(@"auto"), &error);
            PLMEventCollector *unsafeStatCollector = [[PLMEventCollector alloc] init];
            uint64_t unsafeStatToken =
                [bridge subscribeWithEventHandler:[unsafeStatCollector handler]];
            NSInteger unsafeStatRequest =
                PLMGenerate(bridge, unsafeStatSession.integerValue,
                            PLMMessages(mode), PLMParams());
            PLMExpect(unsafeStatRequest > 0 && PLMWait(unsafeStatCollector.terminalSemaphore),
                      [NSString stringWithFormat:@"%@ reaches a trusted terminal", mode]);
            [PocketLMBridge testingDrainQueues];
            PLMExpectTrustedContractFault([unsafeStatCollector snapshot], unsafeStatSession,
                                          unsafeStatRequest, mode);
            [bridge unsubscribeEventHandlerWithToken:unsafeStatToken];
            PLMExpect([bridge generateForSession:unsafeStatSession.integerValue
                                        messages:PLMMessages(@"sync")
                                          params:PLMParams()] ==
                          POCKETLM_GENERATE_SHUTTING_DOWN,
                      [NSString stringWithFormat:@"%@ faults its session", mode]);
            PLMExpect(PLMUnload(unsafeStatSession.integerValue) == nil,
                      [NSString stringWithFormat:@"%@ session explicitly unloads", mode]);
        }
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0 &&
                  [PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"contract-fault regressions leave no callback, state, or gate leaks");

        auto insideGenerate = std::make_shared<std::atomic<bool>>(true);
        auto deliveredInside = std::make_shared<std::atomic<bool>>(false);
        PLMEventCollector *gateCollector = [[PLMEventCollector alloc] init];
        uint64_t gateToken = [bridge subscribeWithEventHandler:^(NSDictionary *event) {
            if (insideGenerate->load(std::memory_order_acquire)) {
                deliveredInside->store(true, std::memory_order_release);
            }
            @synchronized (gateCollector) {
                [gateCollector.events addObject:event];
            }
            NSString *type = event[@"type"];
            if ([type isEqualToString:@"done"] || [type isEqualToString:@"error"]) {
                dispatch_semaphore_signal(gateCollector.terminalSemaphore);
            }
        }];
        NSInteger syncRequest = [bridge generateForSession:sessionOne.integerValue
                                                   messages:PLMMessages(@"sync")
                                                     params:PLMParams()];
        insideGenerate->store(false, std::memory_order_release);
        [PocketLMBridge testingDrainQueues];
        PLMExpect([gateCollector snapshot].count == 0 &&
                  !deliveredInside->load(std::memory_order_acquire),
                  @"copied early callbacks remain behind the explicit return gate");
        int32_t generateCallsBeforeDeferredTerminal = pocketlm_fake_generate_call_count();
        PLMExpect([bridge generateForSession:sessionOne.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == POCKETLM_GENERATE_BUSY &&
                  pocketlm_fake_generate_call_count() ==
                      generateCallsBeforeDeferredTerminal,
                  @"same-session generation stays BUSY until terminal crosses its gate");
        [bridge openDeliveryGateForSession:sessionOne.integerValue requestId:syncRequest];
        PLMExpect(syncRequest > 0 && PLMWait(gateCollector.terminalSemaphore),
                  @"early synchronous callbacks are eventually delivered");
        [PocketLMBridge testingDrainQueues];
        PLMExpect(!deliveredInside->load(std::memory_order_acquire),
                  @"event delivery is barred until generate returns");
        NSArray *syncEvents = [gateCollector snapshot];
        NSDictionary *syncToken = PLMFirstEventOfType(syncEvents, @"token");
        NSDictionary *syncDone = PLMFirstEventOfType(syncEvents, @"done");
        PLMExpect([syncToken[@"sessionId"] isEqual:sessionOne] &&
                  [syncToken[@"requestId"] integerValue] == syncRequest &&
                  [syncToken[@"index"] intValue] == 0 &&
                  [syncToken[@"tokenCount"] intValue] == 3 &&
                  [syncToken[@"text"] isEqualToString:@"abc"],
                  @"adjacent fragments coalesce with authoritative identity and count");
        PLMExpect([syncDone[@"reason"] isEqualToString:@"eos"] &&
                  [syncDone[@"stats"][@"promptTokens"] intValue] == 7 &&
                  [syncDone[@"stats"][@"generatedTokens"] intValue] == 3,
                  @"done payload maps the frozen stats and reason fields");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"accepted early-terminal callback context releases exactly once");
        PLMExpect([PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"terminal delivery retires its gate and per-request state");
        [bridge unsubscribeEventHandlerWithToken:gateToken];

        NSInteger secondRequest = 0;
        NSArray *secondEvents = PLMRun(sessionTwo.integerValue, @"sync", &secondRequest);
        NSDictionary *secondToken = PLMFirstEventOfType(secondEvents, @"token");
        PLMExpect([secondToken[@"sessionId"] isEqual:sessionTwo] &&
                  [secondToken[@"requestId"] integerValue] == secondRequest,
                  @"multiple sessions preserve their own session/request tuple");

        PLMEventCollector *interleaveCollector = [[PLMEventCollector alloc] init];
        uint64_t interleaveToken =
            [bridge subscribeWithEventHandler:[interleaveCollector handler]];
        NSInteger interleaveRequestA =
            PLMGenerate(bridge, sessionOne.integerValue,
                        PLMMessages(@"interleave-a"), PLMParams());
        NSInteger interleaveRequestB =
            PLMGenerate(bridge, sessionTwo.integerValue,
                        PLMMessages(@"interleave-b"), PLMParams());
        [PocketLMBridge testingDrainQueues];
        PLMExpect(interleaveRequestA > 0 && interleaveRequestB > 0 &&
                  pocketlm_fake_emit_interleaved_requests() == 1,
                  @"two-session interleave starts only after both return gates open");
        PLMExpect(PLMWait(interleaveCollector.terminalSemaphore) &&
                  PLMWait(interleaveCollector.terminalSemaphore),
                  @"two-session interleave reaches both terminals");
        [PocketLMBridge testingDrainQueues];
        NSArray<NSDictionary *> *interleavedEvents = [interleaveCollector snapshot];
        NSDictionary *interleaveA0 = interleavedEvents.count > 0 ? interleavedEvents[0] : nil;
        NSDictionary *interleaveB0 = interleavedEvents.count > 1 ? interleavedEvents[1] : nil;
        NSDictionary *interleaveA1 = interleavedEvents.count > 2 ? interleavedEvents[2] : nil;
        NSDictionary *interleaveBDone = interleavedEvents.count > 3 ? interleavedEvents[3] : nil;
        NSDictionary *interleaveADone = interleavedEvents.count > 4 ? interleavedEvents[4] : nil;
        PLMExpect(interleavedEvents.count == 5 &&
                  [interleaveA0[@"type"] isEqualToString:@"token"] &&
                  [interleaveA0[@"sessionId"] isEqual:sessionOne] &&
                  [interleaveA0[@"requestId"] integerValue] == interleaveRequestA &&
                  [interleaveA0[@"index"] intValue] == 0 &&
                  [interleaveA0[@"tokenCount"] intValue] == 1 &&
                  [interleaveA0[@"text"] isEqualToString:@"a0"] &&
                  [interleaveB0[@"type"] isEqualToString:@"token"] &&
                  [interleaveB0[@"sessionId"] isEqual:sessionTwo] &&
                  [interleaveB0[@"requestId"] integerValue] == interleaveRequestB &&
                  [interleaveB0[@"text"] isEqualToString:@"b0"] &&
                  [interleaveA1[@"type"] isEqualToString:@"token"] &&
                  [interleaveA1[@"sessionId"] isEqual:sessionOne] &&
                  [interleaveA1[@"requestId"] integerValue] == interleaveRequestA &&
                  [interleaveA1[@"index"] intValue] == 1 &&
                  [interleaveA1[@"tokenCount"] intValue] == 1 &&
                  [interleaveA1[@"text"] isEqualToString:@"a1"],
                  @"A0, B0, A1 remain separate and preserve serial callback order");
        PLMExpect([interleaveBDone[@"type"] isEqualToString:@"done"] &&
                  [interleaveBDone[@"sessionId"] isEqual:sessionTwo] &&
                  [interleaveADone[@"type"] isEqualToString:@"done"] &&
                  [interleaveADone[@"sessionId"] isEqual:sessionOne],
                  @"B terminal flushes A1 before A's timer and both terminals retain order");
        [bridge unsubscribeEventHandlerWithToken:interleaveToken];

        PLMEventCollector *faultInterleaveCollector = [[PLMEventCollector alloc] init];
        uint64_t faultInterleaveToken =
            [bridge subscribeWithEventHandler:[faultInterleaveCollector handler]];
        NSInteger faultInterleaveRequestA =
            PLMGenerate(bridge, sessionOne.integerValue,
                        PLMMessages(@"interleave-fault-a"), PLMParams());
        NSInteger faultInterleaveRequestB =
            PLMGenerate(bridge, sessionTwo.integerValue,
                        PLMMessages(@"interleave-fault-b"), PLMParams());
        [PocketLMBridge testingDrainQueues];
        PLMExpect(faultInterleaveRequestA > 0 && faultInterleaveRequestB > 0 &&
                  pocketlm_fake_begin_interleaved_fault_requests() == 1,
                  @"cross-session fault interleave starts with A0 before B's malformed terminal");
        PLMExpect(PLMWait(faultInterleaveCollector.terminalSemaphore),
                  @"B's trusted fault terminal arrives before A1 is released");
        [PocketLMBridge testingDrainQueues];
        PLMExpect(pocketlm_fake_finish_interleaved_fault_request() == 1 &&
                  PLMWait(faultInterleaveCollector.terminalSemaphore),
                  @"A1 and A's terminal arrive only after B's trusted fault terminal");
        [PocketLMBridge testingDrainQueues];
        NSArray<NSDictionary *> *faultInterleavedEvents =
            [faultInterleaveCollector snapshot];
        NSDictionary *faultInterleaveA0 =
            faultInterleavedEvents.count > 0 ? faultInterleavedEvents[0] : nil;
        NSDictionary *faultInterleaveBError =
            faultInterleavedEvents.count > 1 ? faultInterleavedEvents[1] : nil;
        NSDictionary *faultInterleaveA1 =
            faultInterleavedEvents.count > 2 ? faultInterleavedEvents[2] : nil;
        NSDictionary *faultInterleaveADone =
            faultInterleavedEvents.count > 3 ? faultInterleavedEvents[3] : nil;
        PLMExpect(faultInterleavedEvents.count == 4 &&
                  [faultInterleaveA0[@"type"] isEqualToString:@"token"] &&
                  [faultInterleaveA0[@"sessionId"] isEqual:sessionOne] &&
                  [faultInterleaveA0[@"requestId"] integerValue] ==
                      faultInterleaveRequestA &&
                  [faultInterleaveA0[@"tokenCount"] intValue] == 1 &&
                  [faultInterleaveA0[@"text"] isEqualToString:@"fault-a0"] &&
                  [faultInterleaveBError[@"type"] isEqualToString:@"error"] &&
                  [faultInterleaveBError[@"sessionId"] isEqual:sessionTwo] &&
                  [faultInterleaveBError[@"requestId"] integerValue] ==
                      faultInterleaveRequestB &&
                  [faultInterleaveBError[@"code"] isEqualToString:@"INTERNAL"] &&
                  [faultInterleaveA1[@"type"] isEqualToString:@"token"] &&
                  [faultInterleaveA1[@"sessionId"] isEqual:sessionOne] &&
                  [faultInterleaveA1[@"requestId"] integerValue] ==
                      faultInterleaveRequestA &&
                  [faultInterleaveA1[@"index"] intValue] == 1 &&
                  [faultInterleaveA1[@"tokenCount"] intValue] == 1 &&
                  [faultInterleaveA1[@"text"] isEqualToString:@"fault-a1"] &&
                  [faultInterleaveADone[@"type"] isEqualToString:@"done"] &&
                  [faultInterleaveADone[@"sessionId"] isEqual:sessionOne],
                  @"trusted B fault flushes A0 and prevents A0+A1 coalescing across it");
        [bridge unsubscribeEventHandlerWithToken:faultInterleaveToken];

        NSArray *burstEvents = PLMRun(sessionOne.integerValue, @"burst", nullptr);
        PLMExpect(PLMSummedTokenCount(burstEvents) == 1000,
                  @"serial coalescing loses none of a 1,000-fragment burst");
        NSArray *byteEvents = PLMRun(sessionOne.integerValue, @"byte-threshold", nullptr);
        NSDictionary *byteToken = PLMFirstEventOfType(byteEvents, @"token");
        PLMExpect([byteToken[@"text"] lengthOfBytesUsingEncoding:NSUTF8StringEncoding] == 5000 &&
                  [byteToken[@"tokenCount"] intValue] == 1,
                  @"byte threshold flushes a complete token without truncation");

        NSArray<NSString *> *errorNames = @[
            @"INVALID_ARGUMENT", @"OOM", @"MODEL_LOAD_FAILED", @"CONTEXT_CREATE_FAILED",
            @"METAL_UNAVAILABLE", @"CHAT_TEMPLATE_FAILED", @"TOKENIZE_FAILED",
            @"PROMPT_TOO_LONG", @"DECODE_FAILED", @"INTERNAL",
        ];
        for (NSInteger code = 1; code <= 10; ++code) {
            NSArray *events = PLMRun(sessionOne.integerValue,
                                     [NSString stringWithFormat:@"error:%ld", (long)code], nullptr);
            NSDictionary *terminal = PLMFirstEventOfType(events, @"error");
            PLMExpect([terminal[@"code"] isEqualToString:errorNames[code - 1]] &&
                      [terminal[@"message"] length] > 0,
                      [NSString stringWithFormat:@"error code %ld maps exactly", (long)code]);
        }
        NSArray<NSString *> *reasonNames = @[
            @"eos", @"max_tokens", @"cancelled", @"context_exhausted",
        ];
        for (NSInteger reason = 1; reason <= 4; ++reason) {
            NSArray *events = PLMRun(sessionOne.integerValue,
                                     [NSString stringWithFormat:@"done:%ld", (long)reason], nullptr);
            NSDictionary *terminal = PLMFirstEventOfType(events, @"done");
            PLMExpect([terminal[@"reason"] isEqualToString:reasonNames[reason - 1]],
                      [NSString stringWithFormat:@"finish reason %ld maps exactly", (long)reason]);
        }
        PLMExpect([PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"repeated terminals do not accumulate request delivery state");

        NSNumber *timerSession = PLMLoad(@"/tmp/timer.gguf", PLMConfig(@"metal"), &error);
        NSArray *timerEvents = PLMRun(timerSession.integerValue, @"timer", nullptr);
        PLMExpect(timerEvents.count == 2 &&
                  [timerEvents[0][@"type"] isEqualToString:@"token"] &&
                  [timerEvents[1][@"type"] isEqualToString:@"done"],
                  @"16 ms timer flush precedes the later terminal");
        PLMExpect(PLMUnload(timerSession.integerValue) == nil,
                  @"timer session unloads after worker join");

        NSNumber *reloadSession = PLMLoad(@"/tmp/reload.gguf", PLMConfig(@"auto"), &error);
        auto staleCalls = std::make_shared<std::atomic<int>>(0);
        uint64_t staleToken = [bridge subscribeWithEventHandler:^(__unused NSDictionary *event) {
            staleCalls->fetch_add(1, std::memory_order_relaxed);
        }];
        NSInteger heldRequest = PLMGenerate(bridge, reloadSession.integerValue,
                                            PLMMessages(@"hold"), PLMParams());
        PLMExpect(heldRequest > 0 && [PocketLMBridge testingLiveCallbackContextCount] == 1,
                  @"accepted async request retains its callback context");
        int32_t generateCallsBeforeHeldBusy = pocketlm_fake_generate_call_count();
        PLMThrowingCopyObject *throwingCopy = [[PLMThrowingCopyObject alloc] init];
        PLMExpect([bridge generateForSession:reloadSession.integerValue
                                    messages:(NSArray *)throwingCopy
                                      params:PLMParams()] == POCKETLM_GENERATE_BUSY &&
                  pocketlm_fake_generate_call_count() == generateCallsBeforeHeldBusy,
                  @"active held request returns BUSY before copy, validation, or C admission");
        PLMEventCollector *replacement = [[PLMEventCollector alloc] init];
        uint64_t replacementToken = [bridge subscribeWithEventHandler:[replacement handler]];
        [bridge unsubscribeEventHandlerWithToken:staleToken];
        pocketlm_fake_release_held_requests();
        PLMExpect(PLMWait(replacement.terminalSemaphore),
                  @"replacement subscriber receives an old native request");
        [PocketLMBridge testingDrainQueues];
        NSDictionary *oldToken = PLMFirstEventOfType([replacement snapshot], @"token");
        PLMExpect(staleCalls->load(std::memory_order_relaxed) == 0 &&
                  [oldToken[@"sessionId"] isEqual:reloadSession] &&
                  [oldToken[@"requestId"] integerValue] == heldRequest,
                  @"stale invalidation compare-clears without detaching the new subscriber");
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"async terminal releases callback context");
        [bridge unsubscribeEventHandlerWithToken:replacementToken];

        auto throwingSinkCalls = std::make_shared<std::atomic<int>>(0);
        uint64_t throwingSinkToken = [bridge subscribeWithEventHandler:^(NSDictionary *event) {
            (void)event;
            throwingSinkCalls->fetch_add(1, std::memory_order_relaxed);
            @throw [NSException exceptionWithName:@"PLMThrowingEventSink"
                                           reason:@"deterministic sink failure"
                                         userInfo:nil];
        }];
        NSInteger throwingSinkRequest =
            PLMGenerate(bridge, reloadSession.integerValue,
                        PLMMessages(@"sync"), PLMParams());
        [PocketLMBridge testingDrainQueues];
        PLMExpect(throwingSinkRequest > 0 &&
                  throwingSinkCalls->load(std::memory_order_relaxed) == 1,
                  @"throwing subscriber fails once without dropping its event");

        PLMEventCollector *throwingSinkReplacement = [[PLMEventCollector alloc] init];
        uint64_t throwingSinkReplacementToken =
            [bridge subscribeWithEventHandler:[throwingSinkReplacement handler]];
        [bridge unsubscribeEventHandlerWithToken:throwingSinkToken];
        PLMExpect(PLMWait(throwingSinkReplacement.terminalSemaphore),
                  @"replacement subscriber receives the buffered terminal");
        [PocketLMBridge testingDrainQueues];
        NSArray<NSDictionary *> *replayedEvents = [throwingSinkReplacement snapshot];
        NSDictionary *replayedToken = PLMFirstEventOfType(replayedEvents, @"token");
        NSDictionary *replayedDone = PLMFirstEventOfType(replayedEvents, @"done");
        PLMExpect(replayedEvents.count == 2 &&
                  [replayedEvents[0][@"type"] isEqualToString:@"token"] &&
                  [replayedEvents[1][@"type"] isEqualToString:@"done"] &&
                  [replayedToken[@"requestId"] integerValue] == throwingSinkRequest &&
                  [replayedToken[@"text"] isEqualToString:@"abc"] &&
                  [replayedToken[@"tokenCount"] intValue] == 3 &&
                  [replayedDone[@"requestId"] integerValue] == throwingSinkRequest &&
                  PLMTerminalCount(replayedEvents) == 1,
                  @"failed current and remaining events replay once in original order");
        PLMExpect([PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"unseen terminal still retires request state without losing delivery");
        [bridge unsubscribeEventHandlerWithToken:throwingSinkReplacementToken];

        auto cppThrowingSinkCalls = std::make_shared<std::atomic<int>>(0);
        uint64_t cppThrowingSinkToken =
            [bridge subscribeWithEventHandler:^(NSDictionary *event) {
                (void)event;
                cppThrowingSinkCalls->fetch_add(1, std::memory_order_relaxed);
                throw std::runtime_error("deterministic C++ sink failure");
            }];
        NSInteger cppThrowingSinkRequest =
            PLMGenerate(bridge, reloadSession.integerValue,
                        PLMMessages(@"sync"), PLMParams());
        [PocketLMBridge testingDrainQueues];
        PLMExpect(cppThrowingSinkRequest > 0 &&
                  cppThrowingSinkCalls->load(std::memory_order_relaxed) == 1,
                  @"C++-throwing subscriber fails once without dropping its event");

        PLMEventCollector *cppThrowingSinkReplacement = [[PLMEventCollector alloc] init];
        uint64_t cppThrowingSinkReplacementToken =
            [bridge subscribeWithEventHandler:[cppThrowingSinkReplacement handler]];
        [bridge unsubscribeEventHandlerWithToken:cppThrowingSinkToken];
        PLMExpect(PLMWait(cppThrowingSinkReplacement.terminalSemaphore),
                  @"replacement subscriber receives events after a C++ exception");
        [PocketLMBridge testingDrainQueues];
        NSArray<NSDictionary *> *cppReplayedEvents = [cppThrowingSinkReplacement snapshot];
        NSDictionary *cppReplayedToken = PLMFirstEventOfType(cppReplayedEvents, @"token");
        NSDictionary *cppReplayedDone = PLMFirstEventOfType(cppReplayedEvents, @"done");
        PLMExpect(cppReplayedEvents.count == 2 &&
                  [cppReplayedEvents[0][@"type"] isEqualToString:@"token"] &&
                  [cppReplayedEvents[1][@"type"] isEqualToString:@"done"] &&
                  [cppReplayedToken[@"requestId"] integerValue] == cppThrowingSinkRequest &&
                  [cppReplayedToken[@"text"] isEqualToString:@"abc"] &&
                  [cppReplayedToken[@"tokenCount"] intValue] == 3 &&
                  [cppReplayedDone[@"requestId"] integerValue] == cppThrowingSinkRequest &&
                  PLMTerminalCount(cppReplayedEvents) == 1,
                  @"C++ failure replays current and remaining events once in order");
        PLMExpect([PocketLMBridge testingDeliveryStateCount] == 0 &&
                  [PocketLMBridge testingOpenGateCount] == 0,
                  @"C++ sink failure leaves terminal delivery state retired");
        [bridge unsubscribeEventHandlerWithToken:cppThrowingSinkReplacementToken];

        NSInteger gapRequest = PLMGenerate(bridge, reloadSession.integerValue,
                                           PLMMessages(@"sync"), PLMParams());
        PLMExpect(gapRequest > 0, @"request can complete during a subscriber gap");
        [PocketLMBridge testingDrainQueues];
        PLMEventCollector *afterGap = [[PLMEventCollector alloc] init];
        uint64_t afterGapToken = [bridge subscribeWithEventHandler:[afterGap handler]];
        PLMExpect(PLMWait(afterGap.terminalSemaphore),
                  @"new subscriber receives events queued during the reload gap");
        NSDictionary *gapToken = PLMFirstEventOfType([afterGap snapshot], @"token");
        PLMExpect([gapToken[@"requestId"] integerValue] == gapRequest &&
                  [gapToken[@"text"] isEqualToString:@"abc"],
                  @"subscriber-gap buffering is non-dropping and request-scoped");
        [bridge unsubscribeEventHandlerWithToken:afterGapToken];
        PLMExpect(PLMUnload(reloadSession.integerValue) == nil,
                  @"Fast Refresh test session unloads cleanly");

        // Cross-layer cancellation check: each fake request emits
        // a real bridge TOKEN, then blocks until Cancel. Measure from the public
        // bridge cancel call through delivery of its sole terminal event.
        NSNumber *cancelSession =
            PLMLoad(@"/tmp/g1-cancel-regenerate.gguf", PLMConfig(@"auto"), &error);
        NSInteger previousCancelRequest = 0;
        for (NSInteger trial = 1; trial <= 5; ++trial) {
            PLMEventCollector *cancelCollector = [[PLMEventCollector alloc] init];
            uint64_t cancelToken =
                [bridge subscribeWithEventHandler:[cancelCollector handler]];
            NSInteger cancelRequest =
                PLMGenerate(bridge, cancelSession.integerValue,
                            PLMMessages(@"stream-hold"), PLMParams());
            BOOL tokenArrived =
                cancelRequest > 0 && PLMWait(cancelCollector.tokenSemaphore);
            PLMExpect(tokenArrived &&
                      cancelRequest == previousCancelRequest + 1,
                      [NSString stringWithFormat:
                          @"Cancel trial %ld streams before Cancel with request ID %ld",
                          (long)trial, (long)cancelRequest]);
            previousCancelRequest = cancelRequest;

            auto cancelStarted = std::chrono::steady_clock::now();
            if (cancelRequest > 0) {
                [bridge cancelSession:cancelSession.integerValue requestId:cancelRequest];
            }
            BOOL terminalArrived = PLMWait(cancelCollector.terminalSemaphore);
            auto cancelLatencyUs = std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - cancelStarted).count();
            BOOL workerIdle =
                pocketlm_fake_wait_for_all_requests_idle(3000) == 1;
            [PocketLMBridge testingDrainQueues];
            NSArray<NSDictionary *> *cancelEvents = [cancelCollector snapshot];
            NSDictionary *cancelTokenEvent = PLMFirstEventOfType(cancelEvents, @"token");
            NSDictionary *cancelDone = PLMFirstEventOfType(cancelEvents, @"done");
            BOOL qualified = tokenArrived && terminalArrived && cancelLatencyUs < 200000 &&
                cancelEvents.count == 2 && PLMTerminalCount(cancelEvents) == 1 &&
                [cancelTokenEvent[@"sessionId"] isEqual:cancelSession] &&
                [cancelTokenEvent[@"requestId"] integerValue] == cancelRequest &&
                [cancelTokenEvent[@"index"] intValue] == 0 &&
                [cancelTokenEvent[@"tokenCount"] intValue] == 1 &&
                [cancelTokenEvent[@"text"] isEqualToString:@"stream"] &&
                [cancelDone[@"sessionId"] isEqual:cancelSession] &&
                [cancelDone[@"requestId"] integerValue] == cancelRequest &&
                [cancelDone[@"reason"] isEqualToString:@"cancelled"];
            PLMExpect(qualified,
                      [NSString stringWithFormat:
                          @"Cancel trial %ld reaches one CANCELLED terminal in %lld us (<200 ms)",
                          (long)trial, (long long)cancelLatencyUs]);
            PLMExpect(workerIdle &&
                      [PocketLMBridge testingLiveCallbackContextCount] == 0 &&
                      [PocketLMBridge testingDeliveryStateCount] == 0 &&
                      [PocketLMBridge testingOpenGateCount] == 0,
                      [NSString stringWithFormat:
                          @"Cancel trial %ld reaches Idle with no bridge ownership leak",
                          (long)trial]);
            [bridge unsubscribeEventHandlerWithToken:cancelToken];
        }
        PLMExpect(PLMUnload(cancelSession.integerValue) == nil,
                  @"Repeated cancellation session unload joins after regeneration");

        NSNumber *unloadSession = PLMLoad(@"/tmp/unload.gguf", PLMConfig(@"auto"), &error);
        dispatch_semaphore_t unloadTerminal = dispatch_semaphore_create(0);
        dispatch_semaphore_t unloadCompletion = dispatch_semaphore_create(0);
        auto terminalObserved = std::make_shared<std::atomic<bool>>(false);
        auto terminalBeforeCompletion = std::make_shared<std::atomic<bool>>(false);
        uint64_t unloadToken = [bridge subscribeWithEventHandler:^(NSDictionary *event) {
            if ([event[@"type"] isEqualToString:@"done"] ||
                [event[@"type"] isEqualToString:@"error"]) {
                terminalObserved->store(true, std::memory_order_release);
                dispatch_semaphore_signal(unloadTerminal);
            }
        }];
        NSInteger unloadRequest = PLMGenerate(bridge, unloadSession.integerValue,
                                              PLMMessages(@"hold"), PLMParams());
        PLMExpect(unloadRequest > 0, @"active unload request is accepted");
        [bridge unloadModel:unloadSession.integerValue completion:^(NSError *value) {
            terminalBeforeCompletion->store(
                value == nil && terminalObserved->load(std::memory_order_acquire),
                std::memory_order_release);
            dispatch_semaphore_signal(unloadCompletion);
        }];
        PLMExpect(PLMWait(unloadTerminal) && PLMWait(unloadCompletion),
                  @"destroy barrier yields terminal and unload completion");
        PLMExpect(terminalBeforeCompletion->load(std::memory_order_acquire),
                  @"copied terminal emits before unload resolves");
        [bridge unsubscribeEventHandlerWithToken:unloadToken];
        PLMExpect([bridge generateForSession:unloadSession.integerValue
                                    messages:PLMMessages(@"sync")
                                      params:PLMParams()] == -1,
                  @"removed session is stale for synchronous generate");
        diagnosticsSemaphore = dispatch_semaphore_create(0);
        [bridge getDiagnosticsForSession:unloadSession.integerValue
                              completion:^(__unused NSDictionary *value, NSError *valueError) {
                                  error = valueError;
                                  dispatch_semaphore_signal(diagnosticsSemaphore);
                              }];
        PLMExpect(PLMWait(diagnosticsSemaphore) &&
                  [error.userInfo[PocketLMBridgeErrorCodeKey] isEqualToString:@"SESSION_NOT_FOUND"],
                  @"removed session diagnostics reject with SESSION_NOT_FOUND");

        PLMExpect(PLMUnload(sessionOne.integerValue) == nil &&
                  PLMUnload(sessionTwo.integerValue) == nil,
                  @"multiple live sessions unload independently");
        PLMExpect(pocketlm_fake_create_count() == pocketlm_fake_destroy_count(),
                  @"every successfully created fake session is destroyed");

        [PocketLMBridge testingSetNextSessionId:INT32_MAX];
        NSNumber *lastSession = PLMLoad(@"/tmp/last.gguf", PLMConfig(@"auto"), &error);
        PLMExpect(lastSession.longLongValue == INT32_MAX,
                  @"last positive Int32 session ID is allocatable");
        PLMExpect(PLMUnload(lastSession.integerValue) == nil,
                  @"last session ID unloads without reuse");
        error = nil;
        NSNumber *exhausted = PLMLoad(@"/tmp/exhausted.gguf", PLMConfig(@"auto"), &error);
        PLMExpect(exhausted == nil &&
                  [error.userInfo[PocketLMBridgeErrorCodeKey]
                      isEqualToString:@"SESSION_ID_EXHAUSTED"],
                  @"session ID exhaustion rejects without wrapping or reuse");

        [PocketLMBridge testingDrainQueues];
        PLMExpect([PocketLMBridge testingLiveCallbackContextCount] == 0,
                  @"harness exits with no live callback contexts");
        PLMExpect(pocketlm_fake_create_count() == pocketlm_fake_destroy_count(),
                  @"harness exits with balanced create/destroy counts");

        if (g_failures == 0) {
            std::fprintf(stdout, "RESULT PASS PocketLMBridgeHarness\n");
            return 0;
        }
        std::fprintf(stderr, "RESULT FAIL PocketLMBridgeHarness failures=%d\n", g_failures);
        return 1;
    }
}

#if !defined(POCKETLM_BRIDGE_XCTEST)
int main(void) {
    return PocketLMRunBridgeHarness();
}
#endif
