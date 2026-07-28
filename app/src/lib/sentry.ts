/**
 * sentry.ts — Sentry initialisation wrapper
 *
 * All other modules should import `captureException` from here rather than
 * directly from `@sentry/react-native`.  This single import point ensures
 * the no-DSN guard is respected: when the DSN is not configured the calls
 * become safe no-ops.
 *
 * Usage:
 *   import { initSentry, captureException } from '../lib/sentry';
 *   initSentry(); // call once at app boot (module-load time in _layout.tsx)
 *
 * Environment variable:
 *   EXPO_PUBLIC_SENTRY_DSN — Sentry Data Source Name.
 *   Leave unset (or empty) to disable Sentry entirely.
 */

import * as Sentry from '@sentry/react-native';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

let _initialised = false;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * Initialise Sentry once at app boot.
 *
 * - If EXPO_PUBLIC_SENTRY_DSN is empty/undefined: logs once and returns.
 * - If already called: second call is silently ignored.
 */
export function initSentry(): void {
  if (_initialised) {
    return;
  }

  const rawDsn: string | undefined = process.env.EXPO_PUBLIC_SENTRY_DSN;

  if (!rawDsn || rawDsn.trim() === '') {
    // Explicitly narrow so the rest of the function never sees `undefined`.
    console.log('[Sentry] DSN not configured — skipping init');
    return;
  }

  // After the guard above `rawDsn` is a non-empty string.
  const dsn: string = rawDsn.trim();

  Sentry.init({
    dsn,
    // Keep performance-monitoring overhead and event volume modest.
    tracesSampleRate: 0.2,
    // Track app cold/warm start spans (requires RN perf monitoring integration).
    enableAppStartTracking: true,
    // Report native frame drops; useful for diagnosing the inference thread.
    enableNativeFramesTracking: true,
    // Environment tag — defaults to "development" if unset.
    environment: process.env.EXPO_PUBLIC_SENTRY_ENV ?? 'development',
  });

  _initialised = true;
}

/**
 * Thin wrapper around Sentry.captureException.
 *
 * Safe to call even when Sentry is not initialised (no DSN configured):
 * @sentry/react-native silently discards events when not initialised, so
 * this is a true no-op in that scenario.
 *
 * @param error  The error to capture. Pass a real Error object when possible.
 * @param context  Optional additional context object.
 */
export function captureException(
  error: unknown,
  context?: Parameters<typeof Sentry.captureException>[1],
): string {
  return Sentry.captureException(error, context);
}
