import React, { useCallback, useRef, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  KeyboardAvoidingView,
  Platform,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
  type ListRenderItem,
} from 'react-native';
import { Link } from 'expo-router';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import { useInstalledModel } from '../features/models/ModelContext';
import { useInference } from '../features/inference/hooks';
import {
  presentAssistantTerminal,
  presentBackend,
  presentInferenceError,
} from '../features/inference/presentation';
import type { Message } from '../features/inference/types';
import { useAppState } from '../state/AppContext';

const MessageBubble = React.memo(function MessageBubble({
  message,
}: {
  message: Message;
}) {
  const isUser = message.role === 'user';
  const terminal =
    message.role === 'assistant' ? presentAssistantTerminal(message) : null;
  const fallbackText =
    message.role === 'assistant' && message.content.length === 0 && !message.streaming
      ? terminal
      : null;

  return (
    <View
      style={[
        styles.bubbleWrapper,
        isUser ? styles.bubbleWrapperUser : styles.bubbleWrapperAssistant,
        message.role === 'assistant' &&
          message.outcome === 'superseded' &&
          styles.superseded,
      ]}
    >
      <View>
        <View
          style={[
            styles.bubble,
            isUser ? styles.bubbleUser : styles.bubbleAssistant,
          ]}
        >
          <Text style={[styles.bubbleText, isUser && styles.bubbleTextUser]}>
            {fallbackText ?? message.content}
            {message.streaming ? <Text style={styles.cursor}>{' ▌'}</Text> : null}
          </Text>
        </View>
        {!isUser && terminal !== null && fallbackText === null ? (
          <Text style={styles.terminalText}>{terminal}</Text>
        ) : null}
      </View>
    </View>
  );
});

export default function ChatScreen() {
  const insets = useSafeAreaInsets();
  const state = useAppState();
  const { status: modelStatus } = useInstalledModel();
  const modelPath = modelStatus.kind === 'ready' ? modelStatus.path : undefined;
  const {
    submit,
    cancel,
    retry,
    regenerate,
    reset,
    activePhase,
    isBusy,
    isResetting,
    canRetry,
    canRegenerate,
  } = useInference({ modelPath });

  const [inputText, setInputText] = useState('');
  const inputRef = useRef<TextInput>(null);
  const isLoading = state.status.kind === 'loading';
  const isGenerating =
    state.status.kind === 'generating' || activePhase !== null;
  const isCancelling = activePhase === 'cancelling';
  const isIdle = state.status.kind === 'idle';
  const hasError = state.status.kind === 'error';
  const modelReady = modelStatus.kind === 'ready';
  const canSend =
    modelReady &&
    (isIdle || hasError) &&
    !isBusy &&
    inputText.trim().length > 0;
  const backend =
    state.diagnostics === null ? null : presentBackend(state.diagnostics);

  const handleSend = useCallback(() => {
    const text = inputText.trim();
    if (text.length === 0 || !submit(text)) return;
    setInputText('');
    inputRef.current?.blur();
  }, [inputText, submit]);

  const handleReset = useCallback(async () => {
    await reset();
    setInputText('');
  }, [reset]);

  const renderItem: ListRenderItem<Message> = useCallback(
    ({ item }) => <MessageBubble message={item} />,
    [],
  );

  const modelLabel =
    modelStatus.kind === 'checking'
      ? 'Checking model…'
      : modelStatus.kind === 'ready'
        ? 'Model verified'
        : modelStatus.kind === 'missing'
          ? 'Seed model to begin'
          : 'Model install invalid';

  return (
    <KeyboardAvoidingView
      style={styles.root}
      behavior={Platform.OS === 'ios' ? 'padding' : 'height'}
    >
      <View style={styles.runtimeBar}>
        <Link href="/models" asChild>
          <TouchableOpacity
            style={styles.runtimeIdentity}
            accessibilityRole="button"
            accessibilityLabel="Open model status"
          >
            {modelStatus.kind === 'checking' ? (
              <ActivityIndicator size="small" />
            ) : (
              <View
                style={[
                  styles.statusDot,
                  modelReady ? styles.statusDotReady : styles.statusDotBlocked,
                ]}
              />
            )}
            <Text style={styles.runtimeLabel}>{modelLabel}</Text>
          </TouchableOpacity>
        </Link>

        {backend !== null ? (
          <View
            style={[
              styles.backendBadge,
              backend.kind === 'metal'
                ? styles.backendMetal
                : backend.kind === 'fallback'
                  ? styles.backendFallback
                  : styles.backendCpu,
            ]}
            accessibilityLabel={`${backend.label}. ${backend.detail}`}
          >
            <Text style={styles.backendText}>{backend.label}</Text>
          </View>
        ) : null}

        {state.sessionId !== null && !isGenerating ? (
          <TouchableOpacity
            onPress={() => void handleReset()}
            disabled={isResetting}
            accessibilityRole="button"
            accessibilityLabel="Unload model and clear chat"
          >
            <Text style={styles.unloadText}>
              {isResetting ? 'Unloading…' : 'Unload'}
            </Text>
          </TouchableOpacity>
        ) : null}
      </View>

      {backend !== null ? (
        <Text style={styles.backendDetail}>{backend.detail}</Text>
      ) : null}

      {!modelReady && modelStatus.kind !== 'checking' ? (
        <View style={styles.modelBanner}>
          <Text style={styles.modelBannerText}>{modelStatus.reason}</Text>
          <Link href="/models" asChild>
            <TouchableOpacity accessibilityRole="button">
              <Text style={styles.modelBannerAction}>View model</Text>
            </TouchableOpacity>
          </Link>
        </View>
      ) : null}

      <FlatList
        data={[...state.messages].reverse()}
        renderItem={renderItem}
        keyExtractor={(item) => item.id}
        inverted
        contentContainerStyle={[
          styles.listContent,
          { paddingBottom: insets.bottom > 0 ? 0 : 8 },
        ]}
        keyboardDismissMode="interactive"
        keyboardShouldPersistTaps="handled"
        ListEmptyComponent={
          <View style={styles.emptyState}>
            <Text style={styles.emptyTitle}>Private, local chat</Text>
            <Text style={styles.emptyBody}>
              Conversation turns are formatted by the model&apos;s embedded GGUF
              chat template. No prompt markers are assembled in JavaScript.
            </Text>
          </View>
        }
      />

      {isLoading ? (
        <View style={styles.loadingOverlay}>
          <ActivityIndicator size="small" color="#007AFF" />
          <Text style={styles.loadingText}>Loading model and backend…</Text>
          <TouchableOpacity
            onPress={() => void handleReset()}
            disabled={isResetting}
            accessibilityLabel="Unload loading model"
            accessibilityRole="button"
          >
            <Text style={styles.inlineActionText}>
              {isResetting ? 'Unloading…' : 'Unload'}
            </Text>
          </TouchableOpacity>
        </View>
      ) : null}

      {hasError ? (
        <View style={styles.errorBanner}>
          <Text style={styles.errorText}>
            {state.status.kind === 'error'
              ? presentInferenceError(state.status.code, state.status.message)
              : ''}
          </Text>
          <View style={styles.errorActions}>
            <TouchableOpacity
              onPress={() => retry()}
              disabled={!canRetry}
              accessibilityLabel="Retry last message"
              accessibilityRole="button"
            >
              <Text
                style={[
                  styles.inlineActionText,
                  !canRetry && styles.actionDisabled,
                ]}
              >
                Retry
              </Text>
            </TouchableOpacity>
            <TouchableOpacity
              onPress={() => void handleReset()}
              disabled={isResetting}
              accessibilityLabel="Unload model and clear chat"
              accessibilityRole="button"
            >
              <Text style={styles.inlineActionText}>Unload &amp; clear</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : null}

      {!isGenerating && canRegenerate ? (
        <View style={styles.regenerateRow}>
          <TouchableOpacity
            onPress={() => regenerate()}
            disabled={!canRegenerate}
            accessibilityRole="button"
            accessibilityLabel="Regenerate latest answer"
          >
            <Text style={styles.regenerateText}>Regenerate latest answer</Text>
          </TouchableOpacity>
        </View>
      ) : null}

      <View
        style={[
          styles.inputRow,
          { paddingBottom: insets.bottom > 0 ? insets.bottom : 12 },
        ]}
      >
        <TextInput
          ref={inputRef}
          style={styles.textInput}
          value={inputText}
          onChangeText={setInputText}
          placeholder={modelReady ? 'Message' : 'Verify a model first'}
          placeholderTextColor="#999"
          multiline
          returnKeyType="send"
          blurOnSubmit
          onSubmitEditing={canSend ? handleSend : undefined}
          editable={modelReady && !isLoading && !isBusy}
        />

        {isGenerating ? (
          <>
            <TouchableOpacity
              style={[styles.actionButton, styles.resetButton]}
              onPress={() => void handleReset()}
              disabled={isResetting}
              accessibilityLabel="Unload model and clear chat"
              accessibilityRole="button"
            >
              <Text style={styles.resetButtonText}>
                {isResetting ? 'Unloading…' : 'Unload'}
              </Text>
            </TouchableOpacity>
            <TouchableOpacity
              style={[styles.actionButton, styles.cancelButton]}
              onPress={cancel}
              disabled={isCancelling}
              accessibilityLabel="Cancel generation"
              accessibilityRole="button"
            >
              <Text style={styles.actionButtonText}>
                {isCancelling ? 'Cancelling…' : 'Cancel'}
              </Text>
            </TouchableOpacity>
          </>
        ) : (
          <TouchableOpacity
            style={[
              styles.actionButton,
              styles.sendButton,
              !canSend && styles.sendButtonDisabled,
            ]}
            onPress={handleSend}
            disabled={!canSend}
            accessibilityLabel="Send message"
            accessibilityRole="button"
          >
            <Text style={styles.actionButtonText}>Send</Text>
          </TouchableOpacity>
        )}
      </View>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#F2F2F7' },
  runtimeBar: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderBottomColor: '#E5E7EB',
    borderBottomWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    gap: 10,
    minHeight: 42,
    paddingHorizontal: 12,
  },
  runtimeIdentity: { alignItems: 'center', flex: 1, flexDirection: 'row', gap: 7 },
  runtimeLabel: { color: '#374151', fontSize: 13, fontWeight: '600' },
  statusDot: { borderRadius: 5, height: 10, width: 10 },
  statusDotReady: { backgroundColor: '#10B981' },
  statusDotBlocked: { backgroundColor: '#F59E0B' },
  backendBadge: { borderRadius: 999, paddingHorizontal: 9, paddingVertical: 4 },
  backendMetal: { backgroundColor: '#DBEAFE' },
  backendFallback: { backgroundColor: '#FEF3C7' },
  backendCpu: { backgroundColor: '#E5E7EB' },
  backendText: { color: '#1F2937', fontSize: 11, fontWeight: '800' },
  backendDetail: {
    backgroundColor: '#FFFFFF',
    color: '#6B7280',
    fontSize: 11,
    paddingBottom: 6,
    paddingHorizontal: 12,
  },
  unloadText: { color: '#DC2626', fontSize: 13, fontWeight: '600' },
  modelBanner: {
    alignItems: 'center',
    backgroundColor: '#FFFBEB',
    flexDirection: 'row',
    gap: 10,
    paddingHorizontal: 12,
    paddingVertical: 9,
  },
  modelBannerText: { color: '#92400E', flex: 1, fontSize: 12 },
  modelBannerAction: { color: '#007AFF', fontSize: 13, fontWeight: '700' },
  listContent: { flexGrow: 1, justifyContent: 'flex-end', padding: 12 },
  emptyState: { alignItems: 'center', padding: 30, transform: [{ scaleY: -1 }] },
  emptyTitle: { color: '#1F2937', fontSize: 20, fontWeight: '700' },
  emptyBody: {
    color: '#6B7280',
    fontSize: 14,
    lineHeight: 20,
    marginTop: 8,
    maxWidth: 330,
    textAlign: 'center',
  },
  bubbleWrapper: { flexDirection: 'row', marginVertical: 4 },
  bubbleWrapperUser: { justifyContent: 'flex-end' },
  bubbleWrapperAssistant: { justifyContent: 'flex-start' },
  superseded: { opacity: 0.48 },
  bubble: { borderRadius: 18, maxWidth: '82%', paddingHorizontal: 14, paddingVertical: 8 },
  bubbleUser: { backgroundColor: '#007AFF' },
  bubbleAssistant: {
    backgroundColor: '#FFFFFF',
    elevation: 1,
    shadowColor: '#000000',
    shadowOffset: { width: 0, height: 1 },
    shadowOpacity: 0.06,
    shadowRadius: 2,
  },
  bubbleText: { color: '#1C1C1E', fontSize: 16, lineHeight: 22 },
  bubbleTextUser: { color: '#FFFFFF' },
  cursor: { color: '#007AFF', fontWeight: '200' },
  terminalText: { color: '#6B7280', fontSize: 10, marginLeft: 7, marginTop: 3 },
  loadingOverlay: {
    alignItems: 'center',
    backgroundColor: 'rgba(242,242,247,0.96)',
    flexDirection: 'row',
    gap: 8,
    justifyContent: 'center',
    paddingVertical: 8,
  },
  loadingText: { color: '#636366', fontSize: 14 },
  inlineActionText: { color: '#007AFF', fontSize: 14, fontWeight: '600' },
  actionDisabled: { opacity: 0.4 },
  errorBanner: {
    backgroundColor: '#FFF0F0',
    borderTopColor: '#FF3B30',
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 16,
    paddingVertical: 7,
  },
  errorText: { color: '#B91C1C', fontSize: 13 },
  errorActions: { flexDirection: 'row', gap: 16, justifyContent: 'flex-end', marginTop: 6 },
  regenerateRow: { alignItems: 'center', paddingVertical: 6 },
  regenerateText: { color: '#007AFF', fontSize: 13, fontWeight: '600' },
  inputRow: {
    alignItems: 'flex-end',
    backgroundColor: '#F2F2F7',
    borderTopColor: '#C6C6C8',
    borderTopWidth: StyleSheet.hairlineWidth,
    flexDirection: 'row',
    gap: 8,
    paddingHorizontal: 12,
    paddingTop: 8,
  },
  textInput: {
    backgroundColor: '#FFFFFF',
    borderColor: '#C6C6C8',
    borderRadius: 20,
    borderWidth: StyleSheet.hairlineWidth,
    color: '#1C1C1E',
    flex: 1,
    fontSize: 16,
    maxHeight: 120,
    minHeight: 40,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  actionButton: {
    alignItems: 'center',
    borderRadius: 20,
    height: 40,
    justifyContent: 'center',
    paddingHorizontal: 17,
  },
  sendButton: { backgroundColor: '#007AFF' },
  sendButtonDisabled: { backgroundColor: '#C7C7CC' },
  cancelButton: { backgroundColor: '#FF3B30' },
  resetButton: { backgroundColor: '#E5E5EA' },
  actionButtonText: { color: '#FFFFFF', fontSize: 15, fontWeight: '600' },
  resetButtonText: { color: '#3A3A3C', fontSize: 15, fontWeight: '600' },
});
