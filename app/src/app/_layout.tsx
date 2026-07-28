import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { AppProvider } from '../state/AppContext';
import { ModelProvider } from '../features/models/ModelContext';
import { initSentry } from '../lib/sentry';

// Initialise Sentry at module-load time so crashes during provider setup are
// captured before any React tree is mounted.  See app/src/lib/sentry.ts for
// the no-op behaviour when EXPO_PUBLIC_SENTRY_DSN is unset.
initSentry();

export default function RootLayout() {
  return (
    <ModelProvider>
      <AppProvider>
        <StatusBar style="auto" />
        <Stack>
          <Stack.Screen
            name="index"
            options={{ title: 'PocketLM' }}
          />
          <Stack.Screen
            name="bench"
            options={{ title: 'Qualification' }}
          />
          <Stack.Screen
            name="models"
            options={{ title: 'Models' }}
          />
        </Stack>
      </AppProvider>
    </ModelProvider>
  );
}
