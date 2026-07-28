import { useCallback } from 'react';
import {
  ActivityIndicator,
  Pressable,
  ScrollView,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { useFocusEffect } from 'expo-router';
import { useInstalledModel } from '../features/models/ModelContext';

function formatBytes(bytes: number): string {
  return `${(bytes / (1024 * 1024)).toFixed(1)} MiB`;
}

export default function ModelsScreen() {
  const { status, refresh } = useInstalledModel();

  useFocusEffect(
    useCallback(() => {
      void refresh();
    }, [refresh]),
  );

  const model = status.kind === 'checking' ? null : status.model;

  return (
    <ScrollView contentContainerStyle={styles.container}>
      <View style={styles.card}>
        <View style={styles.headingRow}>
          <View style={styles.headingCopy}>
            <Text style={styles.eyebrow}>LOCAL MODEL</Text>
            <Text style={styles.title}>
              {model?.displayName ?? 'Checking embedded catalog…'}
            </Text>
          </View>
          {status.kind === 'checking' ? (
            <ActivityIndicator accessibilityLabel="Checking model" />
          ) : (
            <View
              style={[
                styles.badge,
                status.kind === 'ready'
                  ? styles.badgeReady
                  : status.kind === 'missing'
                    ? styles.badgeMissing
                    : styles.badgeInvalid,
              ]}
            >
              <Text style={styles.badgeText}>
                {status.kind === 'ready'
                  ? 'VERIFIED'
                  : status.kind === 'missing'
                    ? 'NOT INSTALLED'
                    : 'INVALID'}
              </Text>
            </View>
          )}
        </View>

        {model !== null ? (
          <View style={styles.details}>
            <Text style={styles.detail}>Qwen2 · {model.quantization}</Text>
            <Text style={styles.detail}>
              {formatBytes(model.byteSize)} · {String(model.initialContextTokens)}-token context
            </Text>
            <Text style={styles.hash} numberOfLines={1} ellipsizeMode="middle">
              SHA-256 {model.sha256}
            </Text>
          </View>
        ) : null}

        {status.kind === 'ready' ? (
          <View style={styles.statusPanel}>
            <Text style={styles.statusTitle}>Ready for local inference</Text>
            <Text style={styles.statusBody}>
              Exact size, GGUF magic, manifest identity, and verified chat
              template match the pinned catalog. The atomic seed/import verified
              SHA-256 before and after installation.
            </Text>
            <Text style={styles.path} selectable>
              {status.path}
            </Text>
          </View>
        ) : status.kind === 'missing' || status.kind === 'invalid' ? (
          <View style={styles.statusPanel}>
            <Text style={styles.statusTitle}>{status.reason}</Text>
            <Text style={styles.statusBody}>
              With the Simulator booted and this development build installed,
              run ./scripts/seed-simulator-model.sh from the repository root.
              The script verifies before and after its atomic sandbox import.
            </Text>
          </View>
        ) : null}

        <Pressable
          style={({ pressed }) => [
            styles.refreshButton,
            pressed && styles.refreshButtonPressed,
          ]}
          onPress={() => void refresh()}
          disabled={status.kind === 'checking'}
          accessibilityRole="button"
          accessibilityLabel="Check installed model again"
        >
          <Text style={styles.refreshText}>
            {status.kind === 'checking' ? 'Checking…' : 'Check again'}
          </Text>
        </Pressable>
      </View>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flexGrow: 1,
    padding: 16,
    backgroundColor: '#F2F2F7',
  },
  card: {
    borderRadius: 20,
    padding: 20,
    backgroundColor: '#FFFFFF',
    shadowColor: '#000000',
    shadowOpacity: 0.06,
    shadowRadius: 12,
    shadowOffset: { width: 0, height: 4 },
  },
  headingRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    gap: 12,
  },
  headingCopy: { flex: 1 },
  eyebrow: {
    color: '#6B7280',
    fontSize: 11,
    fontWeight: '700',
    letterSpacing: 1.1,
    marginBottom: 5,
  },
  title: { color: '#111827', fontSize: 23, fontWeight: '700' },
  badge: { borderRadius: 999, paddingHorizontal: 9, paddingVertical: 6 },
  badgeReady: { backgroundColor: '#D1FAE5' },
  badgeMissing: { backgroundColor: '#FEF3C7' },
  badgeInvalid: { backgroundColor: '#FEE2E2' },
  badgeText: { color: '#1F2937', fontSize: 10, fontWeight: '800' },
  details: { gap: 4, marginTop: 18 },
  detail: { color: '#374151', fontSize: 14 },
  hash: { color: '#6B7280', fontFamily: 'Menlo', fontSize: 11, marginTop: 5 },
  statusPanel: {
    backgroundColor: '#F9FAFB',
    borderRadius: 14,
    marginTop: 20,
    padding: 14,
  },
  statusTitle: { color: '#111827', fontSize: 15, fontWeight: '700' },
  statusBody: { color: '#4B5563', fontSize: 14, lineHeight: 20, marginTop: 6 },
  path: { color: '#6B7280', fontFamily: 'Menlo', fontSize: 10, marginTop: 10 },
  refreshButton: {
    alignItems: 'center',
    backgroundColor: '#111827',
    borderRadius: 12,
    marginTop: 18,
    paddingVertical: 12,
  },
  refreshButtonPressed: { opacity: 0.78 },
  refreshText: { color: '#FFFFFF', fontSize: 15, fontWeight: '700' },
});
