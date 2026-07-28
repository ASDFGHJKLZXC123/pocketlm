import { ExpoConfig, ConfigContext } from 'expo/config';
import modelCatalog from '../models/catalog.json';

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: 'PocketLM',
  slug: 'pocketlm',
  version: '1.0.0',
  scheme: 'pocketlm',
  platforms: ['ios'],
  orientation: 'portrait',
  userInterfaceStyle: 'automatic',

  // Embed the immutable, repository-owned catalog in the native app
  // configuration. Runtime code validates the sandbox manifest against this
  // exact identity instead of maintaining a second JavaScript catalog.
  extra: {
    ...config.extra,
    pocketlmModelCatalog: modelCatalog,
  },

  // iOS only. Android is not implemented.
  ios: {
    // Replace this identifier before signing or distribution.
    bundleIdentifier: 'com.pocketlm.app',
    supportsTablet: false,
    infoPlist: {
      NSPhotoLibraryUsageDescription: 'PocketLM does not access the photo library.',
      NSCameraUsageDescription: 'PocketLM does not access the camera.',
    },
  },

  plugins: [
    'expo-router',
    // Expo Xcode mods unwind in reverse registration order. Declaring this
    // before Sentry makes its guarded bundle-phase correction execute after
    // Sentry installs the sourcemap wrapper. It also adds the local pod.
    // A clean prebuild must preserve the custom podspec and native sources.
    [
      './plugins/withPocketLMPod',
      {
        // The plugin writes this project-wide value into generated
        // Podfile.properties.json and every Xcode build configuration.
        deploymentTarget: '17.0',
      },
    ],
    // Sentry: wires the dSYM upload build phase and the sentry-xcode.sh
    // sourcemap wrapper into the Xcode project on every `expo prebuild --clean`.
    //
    // No authToken, org, or project are hardcoded here — all three are
    // consumed from env vars (SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT)
    // by the sentry-xcode-debug-files.sh script at build time.  When the env
    // vars are absent the upload phase silently exits 0 (see the shell script).
    //
    // The `@sentry/react-native` app.plugin.js (plugin/build/index.js via
    // expo.js) is used directly — no custom plugin needed because the
    // Sentry-provided one already handles iOS-only builds correctly.
    [
      '@sentry/react-native',
      {
        // org/project left undefined: the plugin emits env-var fallback
        // comments in sentry.properties rather than hardcoded values.
        // authToken is intentionally absent — use SENTRY_AUTH_TOKEN in env.
      },
    ],
  ],

  experiments: {
    typedRoutes: true,
  },
});
