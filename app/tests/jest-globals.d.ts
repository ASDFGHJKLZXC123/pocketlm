interface PocketLMTestMatchers {
  not: PocketLMTestMatchers;
  toBe(expected: unknown): void;
  toEqual(expected: unknown): void;
  toContain(expected: unknown): void;
  toMatch(expected: string | RegExp): void;
  toHaveLength(expected: number): void;
  toBeNull(): void;
  toBeUndefined(): void;
  toBeTruthy(): void;
  toBeFalsy(): void;
  toThrow(expected?: string | RegExp): void;
}

declare function describe(name: string, testGroup: () => void): void;
declare function it(name: string, testCase: () => void | Promise<void>): void;
declare function beforeEach(setup: () => void | Promise<void>): void;
declare function afterEach(teardown: () => void | Promise<void>): void;
declare function expect(actual: unknown): PocketLMTestMatchers;

declare const jest: {
  mock(moduleName: string, factory: () => unknown): void;
  useFakeTimers(): void;
  useRealTimers(): void;
  advanceTimersByTime(milliseconds: number): void;
};
