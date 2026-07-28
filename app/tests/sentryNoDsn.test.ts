import { captureException, initSentry } from '../src/lib/sentry';

const mockInitCalls: unknown[] = [];
const mockCaptureCalls: unknown[][] = [];

jest.mock('@sentry/react-native', () => ({
  init: (options: unknown) => {
    mockInitCalls.push(options);
  },
  captureException: (...args: unknown[]) => {
    mockCaptureCalls.push(args);
    return 'test-event-id';
  },
}));

describe('Sentry without a DSN', () => {
  it('skips SDK initialization and remains safe to call', () => {
    const previousDsn = process.env.EXPO_PUBLIC_SENTRY_DSN;
    delete process.env.EXPO_PUBLIC_SENTRY_DSN;

    expect(() => initSentry()).not.toThrow();
    expect(mockInitCalls).toHaveLength(0);
    expect(() => captureException(new Error('offline'))).not.toThrow();
    expect(mockCaptureCalls).toHaveLength(1);

    if (previousDsn === undefined) {
      delete process.env.EXPO_PUBLIC_SENTRY_DSN;
    } else {
      process.env.EXPO_PUBLIC_SENTRY_DSN = previousDsn;
    }
  });
});
