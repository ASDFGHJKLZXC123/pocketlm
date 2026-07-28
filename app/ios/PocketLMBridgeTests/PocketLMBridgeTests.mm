#define POCKETLM_BRIDGE_TESTING 1

#import <XCTest/XCTest.h>

extern int PocketLMRunBridgeHarness(void);

@interface PocketLMBridgeTests : XCTestCase
@end

@implementation PocketLMBridgeTests

- (void)testFrozenInferenceProtocolHarness {
    XCTAssertEqual(PocketLMRunBridgeHarness(), 0);
}

@end
