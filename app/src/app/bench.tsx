import Constants from 'expo-constants';
import { useLocalSearchParams } from 'expo-router';
import React, { useCallback, useEffect, useRef, useState } from 'react';
import {
  ActivityIndicator,
  NativeEventEmitter,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';
import { useInstalledModel } from '../features/models/ModelContext';
import {
  M4QualificationRunner,
  parseQualificationCollectorNonce,
  parseQualificationRcCommit,
  type QualificationProgress,
  type QualificationRunSummary,
  type QualificationSuite,
} from '../features/qualification/runner';
import { createQualificationArtifactSink } from '../features/qualification/storage';
import PocketLM, { INFERENCE_EVENT_NAME } from '../lib/native';
import { useAppState } from '../state/AppContext';

let qualificationRunActive = false;

function firstQueryValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

function safeMessage(error: unknown): string {
  const message =
    error instanceof Error && error.message.length > 0
      ? error.message
      : String(error);
  return message
    .replace(/file:\/\/\/[^\s]+/g, '[redacted-local-file-uri]')
    .replace(/\/(?:private|var)\/[^\s]+/g, '[redacted-local-path]');
}

function querySuite(value: string | undefined): QualificationSuite {
  return value === 'memory' ? 'memory' : 'all';
}

function progressLabel(progress: QualificationProgress | null): string {
  if (progress === null) return 'Waiting to start';
  const count = progress.total > 0
    ? ` (${String(progress.completed)}/${String(progress.total)})`
    : '';
  return `${progress.phase}${count}: ${progress.detail}`;
}

export default function BenchScreen() {
  const query = useLocalSearchParams<{
    autorun?: string | string[];
    collectorNonce?: string | string[];
    suite?: string | string[];
  }>();
  const requestedSuite = querySuite(firstQueryValue(query.suite));
  const autorun = firstQueryValue(query.autorun) === '1';
  const requestedCollectorNonce = parseQualificationCollectorNonce(
    firstQueryValue(query.collectorNonce),
  );
  const { status: modelStatus } = useInstalledModel();
  const appState = useAppState();
  const [running, setRunning] = useState(false);
  const [progress, setProgress] = useState<QualificationProgress | null>(null);
  const [activeRunId, setActiveRunId] = useState<string | null>(null);
  const [summary, setSummary] = useState<QualificationRunSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  const runningRef = useRef(false);
  const mountedRef = useRef(true);
  const autorunAttemptedRef = useRef(false);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const start = useCallback(
    async (
      suite: QualificationSuite,
      collectorNonce: string | null,
    ): Promise<void> => {
      if (runningRef.current) return;

      runningRef.current = true;
      setRunning(true);
      setSummary(null);
      setError(null);
      setActiveRunId(null);
      setProgress({
        phase: 'preparing',
        completed: 0,
        total: 1,
        detail: `Creating unique ${suite} run`,
      });
      let sink: ReturnType<typeof createQualificationArtifactSink> | null = null;
      let runnerEntered = false;
      let ownsQualificationLock = false;
      try {
        sink = createQualificationArtifactSink(suite, collectorNonce);
        setActiveRunId(sink.runId);
        if (qualificationRunActive) {
          throw new Error(
            'Another qualification run is already active in this app process.',
          );
        }
        qualificationRunActive = true;
        ownsQualificationLock = true;
        if (appState.sessionId !== null) {
          throw new Error(
            'Unload the interactive chat session before qualification so memory evidence starts clean.',
          );
        }
        if (modelStatus.kind !== 'ready') {
          throw new Error('Autorun requires the exact verified model in this app sandbox.');
        }
        const emitter = new NativeEventEmitter(PocketLM);
        const runner = new M4QualificationRunner({
          native: PocketLM,
          subscribe: (listener) =>
            emitter.addListener(INFERENCE_EVENT_NAME, listener),
          onProgress: (next) => {
            if (mountedRef.current) setProgress(next);
          },
        });
        runnerEntered = true;
        const result = await runner.run({
          model: modelStatus,
          sink,
          suite,
          collectorNonce,
          app: {
            platform: Platform.OS,
            platformVersion: String(Platform.Version),
            buildMode: __DEV__ ? 'debug' : 'release',
            appVersion: Constants.expoConfig?.version ?? null,
            jsEngine:
              (globalThis as { HermesInternal?: unknown }).HermesInternal === undefined
                ? null
                : 'Hermes',
            appCommit: parseQualificationRcCommit(
              process.env.EXPO_PUBLIC_POCKETLM_RC_COMMIT,
            ),
          },
        });
        if (mountedRef.current) setSummary(result);
      } catch (runError: unknown) {
        const message = safeMessage(runError);
        if (sink !== null && !runnerEntered) {
          try {
            await sink.writeJson('FAILED.json', {
              schemaVersion: 1,
              runId: sink.runId,
              suite,
              collectorNonce,
              failedAt: new Date().toISOString(),
              completedSuites: [],
              error: { message },
              phase: 'app-runner-setup',
            });
          } catch {
            // The visible error still releases the UI lock if storage itself failed.
          }
        }
        if (mountedRef.current) setError(message);
      } finally {
        runningRef.current = false;
        if (ownsQualificationLock) qualificationRunActive = false;
        if (mountedRef.current) setRunning(false);
      }
    }, [appState.sessionId, modelStatus],
  );

  useEffect(() => {
    if (!autorun || autorunAttemptedRef.current || runningRef.current) return;
    if (modelStatus.kind === 'checking') return;
    autorunAttemptedRef.current = true;
    if (requestedCollectorNonce === null) {
      setError('Autorun requires an exact 32-hex collector nonce.');
      return;
    }
    void start(requestedSuite, requestedCollectorNonce);
  }, [
    appState.sessionId,
    autorun,
    modelStatus,
    requestedCollectorNonce,
    requestedSuite,
    start,
  ]);

  const modelReady = modelStatus.kind === 'ready';
  const blockedByChat = appState.sessionId !== null;

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <Text style={styles.eyebrow}>MODEL QUALIFICATION</Text>
      <Text style={styles.title}>Simulator validation runner</Text>
      <Text style={styles.body}>
        Writes progressive JSON results to the app&apos;s Documents directory.
        COMPLETE.json appears only after every selected workload succeeds;
        FAILED.json marks a terminal failure.
      </Text>

      <View style={styles.card}>
        <Text style={styles.cardTitle}>Scope</Text>
        <Text style={styles.row}>iOS Simulator · CPU-only · fixed seed 424242 · 4 threads</Text>
        <Text style={styles.row}>
          Model: {modelReady ? modelStatus.model.displayName : modelStatus.kind}
        </Text>
        {modelReady ? (
          <Text style={styles.hash} numberOfLines={2}>
            SHA-256 {modelStatus.model.sha256}
          </Text>
        ) : null}
        {blockedByChat ? (
          <Text style={styles.warning}>
            Interactive chat owns a loaded session. Unload it before starting.
          </Text>
        ) : null}
      </View>

      <View style={styles.actions}>
        <TouchableOpacity
          accessibilityRole="button"
          accessibilityLabel="Start all qualification suites"
          disabled={!modelReady || running || blockedByChat}
          onPress={() => void start('all', null)}
          style={[
            styles.primaryButton,
            (!modelReady || running || blockedByChat) && styles.disabled,
          ]}
        >
          <Text style={styles.primaryButtonText}>Start all suites</Text>
        </TouchableOpacity>
        <TouchableOpacity
          accessibilityRole="button"
          accessibilityLabel="Start memory-only qualification suite"
          disabled={!modelReady || running || blockedByChat}
          onPress={() => void start('memory', null)}
          style={[
            styles.secondaryButton,
            (!modelReady || running || blockedByChat) && styles.disabled,
          ]}
        >
          <Text style={styles.secondaryButtonText}>Start memory-only</Text>
        </TouchableOpacity>
      </View>

      <View style={styles.card}>
        <View style={styles.statusHeader}>
          <Text style={styles.cardTitle}>Run status</Text>
          {running ? <ActivityIndicator size="small" color="#65d8a5" /> : null}
        </View>
        <Text accessibilityLabel="Qualification progress" style={styles.progress}>
          {progressLabel(progress)}
        </Text>
        {activeRunId !== null ? (
          <Text selectable style={styles.runId}>Run ID: {activeRunId}</Text>
        ) : null}
        {summary !== null ? (
          <View style={styles.successBox}>
            <Text style={styles.successTitle}>Qualification complete</Text>
            <Text style={styles.successText}>
              {summary.completedSuites.join(', ')}
            </Text>
            <Text selectable style={styles.path}>
              Results saved for run {summary.runId}
            </Text>
          </View>
        ) : null}
        {error !== null ? (
          <View style={styles.errorBox}>
            <Text style={styles.errorTitle}>Qualification failed</Text>
            <Text selectable style={styles.errorText}>{error}</Text>
          </View>
        ) : null}
      </View>

      <Text style={styles.footnote}>
        The app records lifecycle timestamps and native sampled peaks. A separate
        Instruments trace owns post-unload RSS and leak interpretation. Simulator
        timing is never presented as physical-device performance.
      </Text>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flexGrow: 1,
    backgroundColor: '#09110f',
    paddingHorizontal: 22,
    paddingTop: 28,
    paddingBottom: 44,
  },
  eyebrow: {
    color: '#65d8a5',
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 1.4,
    marginBottom: 8,
  },
  title: {
    color: '#f5fbf8',
    fontSize: 30,
    fontWeight: '700',
    marginBottom: 10,
  },
  body: {
    color: '#b7c6c0',
    fontSize: 15,
    lineHeight: 22,
    marginBottom: 22,
  },
  card: {
    backgroundColor: '#12201c',
    borderColor: '#29483d',
    borderRadius: 14,
    borderWidth: 1,
    padding: 16,
    marginBottom: 16,
  },
  cardTitle: {
    color: '#eff8f3',
    fontSize: 17,
    fontWeight: '700',
    marginBottom: 8,
  },
  row: {
    color: '#c9d8d2',
    fontSize: 14,
    lineHeight: 20,
    marginBottom: 4,
  },
  hash: {
    color: '#8ea59c',
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    fontSize: 11,
    lineHeight: 16,
    marginTop: 6,
  },
  warning: {
    color: '#ffd28a',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 10,
  },
  actions: {
    gap: 10,
    marginBottom: 18,
  },
  primaryButton: {
    alignItems: 'center',
    backgroundColor: '#65d8a5',
    borderRadius: 12,
    paddingVertical: 14,
  },
  primaryButtonText: {
    color: '#07110d',
    fontSize: 16,
    fontWeight: '700',
  },
  secondaryButton: {
    alignItems: 'center',
    borderColor: '#65d8a5',
    borderRadius: 12,
    borderWidth: 1,
    paddingVertical: 13,
  },
  secondaryButtonText: {
    color: '#8ce9bd',
    fontSize: 15,
    fontWeight: '600',
  },
  disabled: {
    opacity: 0.4,
  },
  statusHeader: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  progress: {
    color: '#dcebe4',
    fontSize: 14,
    lineHeight: 20,
  },
  runId: {
    color: '#8ea59c',
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    fontSize: 11,
    marginTop: 10,
  },
  successBox: {
    backgroundColor: '#153529',
    borderRadius: 10,
    marginTop: 14,
    padding: 12,
  },
  successTitle: {
    color: '#8ce9bd',
    fontSize: 15,
    fontWeight: '700',
  },
  successText: {
    color: '#d9f4e7',
    fontSize: 13,
    marginTop: 4,
  },
  path: {
    color: '#9ab9ac',
    fontFamily: Platform.OS === 'ios' ? 'Menlo' : 'monospace',
    fontSize: 10,
    marginTop: 8,
  },
  errorBox: {
    backgroundColor: '#3a1919',
    borderRadius: 10,
    marginTop: 14,
    padding: 12,
  },
  errorTitle: {
    color: '#ffaaa4',
    fontSize: 15,
    fontWeight: '700',
  },
  errorText: {
    color: '#ffd2ce',
    fontSize: 13,
    lineHeight: 18,
    marginTop: 5,
  },
  footnote: {
    color: '#81958c',
    fontSize: 12,
    lineHeight: 18,
  },
});
