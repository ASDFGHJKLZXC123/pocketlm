/**
 * withPocketLMPod.js
 *
 * Expo config plugin that adds the PocketLM local-pod declaration, freezes the
 * iOS deployment target, and corrects known whitespace-unsafe bundle-script
 * invocations. These generated settings survive prebuild while preserving the
 * custom podspec and native source.
 *
 * Usage in app.config.ts:
 *   plugins: [['./plugins/withPocketLMPod', { deploymentTarget: '17.0' }]]
 *
 * The pod is added after the use_react_native!() block.
 *
 * Ref: https://docs.expo.dev/config-plugins/plugins-and-mods/#podfile
 */

const {
  withPodfile,
  withPodfileProperties,
  withXcodeProject,
} = require('expo/config-plugins');

const POD_LINE = `\n  # PocketLM native bridge: Obj-C++ TurboModule + CMake-built static libs.\n  # Its distinct pod target name prevents a workspace scheme collision with\n  # the PocketLM app target; the JS/TurboModule export remains \`PocketLM\`.\n  pod 'PocketLMNative', :path => '.'`;
const LEGACY_POD_DECLARATION = "pod 'PocketLM', :path => '.'";
const POD_DECLARATION = "pod 'PocketLMNative', :path => '.'";
const RN_BUNDLE_PHASE_NAME = 'Bundle React Native code and images';
const LEGACY_RN_XCODE_SCRIPT_INVOCATION =
  `\`\\\"$NODE_BINARY\\\" --print \\\"require('path').dirname(require.resolve('react-native/package.json')) + '/scripts/react-native-xcode.sh'\\\"\``;
const SAFE_RN_XCODE_SCRIPT_INVOCATION =
  `REACT_NATIVE_XCODE_SCRIPT=\\\"$(\\\"$NODE_BINARY\\\" --print \\\"require('path').dirname(require.resolve('react-native/package.json')) + '/scripts/react-native-xcode.sh'\\\")\\\"\\n` +
  `\\\"$REACT_NATIVE_XCODE_SCRIPT\\\"`;
const LEGACY_SENTRY_XCODE_SCRIPT_INVOCATION =
  `/bin/sh \`\\\"$NODE_BINARY\\\" --print \\\"require('path').dirname(require.resolve('@sentry/react-native/package.json')) + '/scripts/sentry-xcode.sh'\\\"\` ` +
  LEGACY_RN_XCODE_SCRIPT_INVOCATION;
const SAFE_SENTRY_XCODE_SCRIPT_INVOCATION =
  `SENTRY_XCODE_SCRIPT=\\\"$(\\\"$NODE_BINARY\\\" --print \\\"require('path').dirname(require.resolve('@sentry/react-native/package.json')) + '/scripts/sentry-xcode.sh'\\\")\\\"\\n` +
  `REACT_NATIVE_XCODE_SCRIPT=\\\"$(\\\"$NODE_BINARY\\\" --print \\\"require('path').dirname(require.resolve('react-native/package.json')) + '/scripts/react-native-xcode.sh'\\\")\\\"\\n` +
  `/bin/sh \\\"$SENTRY_XCODE_SCRIPT\\\" \\\"$REACT_NATIVE_XCODE_SCRIPT\\\"`;

/**
 * Patch only the app target's known Expo-generated React Native bundle phase.
 * The xcode package exposes shellScript in pbxproj-escaped form, so the
 * guarded strings intentionally contain escaped quotes and literal `\\n`s.
 *
 * @param {import('xcode').XcodeProject} project
 */
const patchReactNativeBundleScript = (project) => {
  const appTarget = project.getTarget('com.apple.product-type.application');
  const matchingPhaseRefs = appTarget?.target?.buildPhases?.filter(
    (phase) => phase.comment === RN_BUNDLE_PHASE_NAME,
  );

  if (matchingPhaseRefs?.length !== 1) {
    console.warn(
      `[PocketLM] Expected one ${RN_BUNDLE_PHASE_NAME} app phase; whitespace-path correction skipped.`,
    );
    return;
  }

  const phaseId = matchingPhaseRefs[0].value;
  const phase = project.hash.project.objects.PBXShellScriptBuildPhase?.[phaseId];
  if (!phase || typeof phase.shellScript !== 'string') {
    console.warn(
      `[PocketLM] ${RN_BUNDLE_PHASE_NAME} script body not found; whitespace-path correction skipped.`,
    );
    return;
  }

  if (
    phase.shellScript.includes(SAFE_RN_XCODE_SCRIPT_INVOCATION) ||
    phase.shellScript.includes(SAFE_SENTRY_XCODE_SCRIPT_INVOCATION)
  ) {
    return;
  }

  const sentryFirstMatch = phase.shellScript.indexOf(LEGACY_SENTRY_XCODE_SCRIPT_INVOCATION);
  const sentryLastMatch = phase.shellScript.lastIndexOf(LEGACY_SENTRY_XCODE_SCRIPT_INVOCATION);
  if (sentryFirstMatch >= 0) {
    if (sentryFirstMatch !== sentryLastMatch) {
      console.warn(
        `[PocketLM] ${RN_BUNDLE_PHASE_NAME} Sentry script shape changed; whitespace-path correction skipped.`,
      );
      return;
    }
    phase.shellScript = phase.shellScript.replace(
      LEGACY_SENTRY_XCODE_SCRIPT_INVOCATION,
      SAFE_SENTRY_XCODE_SCRIPT_INVOCATION,
    );
    return;
  }

  const firstMatch = phase.shellScript.indexOf(LEGACY_RN_XCODE_SCRIPT_INVOCATION);
  const lastMatch = phase.shellScript.lastIndexOf(LEGACY_RN_XCODE_SCRIPT_INVOCATION);
  if (firstMatch < 0 || firstMatch !== lastMatch) {
    console.warn(
      `[PocketLM] ${RN_BUNDLE_PHASE_NAME} script shape changed; whitespace-path correction skipped.`,
    );
    return;
  }

  phase.shellScript = phase.shellScript.replace(
    LEGACY_RN_XCODE_SCRIPT_INVOCATION,
    SAFE_RN_XCODE_SCRIPT_INVOCATION,
  );
};

/**
 * @param {import('expo/config-plugins').ExpoConfig} config
 * @param {{deploymentTarget?: string}} options
 * @returns {import('expo/config-plugins').ExpoConfig}
 */
const withPocketLMPod = (config, options = {}) => {
  const deploymentTarget = options.deploymentTarget ?? '17.0';

  let nextConfig = withPodfileProperties(config, (mod) => {
    mod.modResults['ios.deploymentTarget'] = deploymentTarget;
    return mod;
  });

  nextConfig = withXcodeProject(nextConfig, (mod) => {
    const configurations = mod.modResults.pbxXCBuildConfigurationSection();
    for (const entry of Object.values(configurations)) {
      if (entry && typeof entry === 'object' && entry.buildSettings) {
        entry.buildSettings.IPHONEOS_DEPLOYMENT_TARGET = deploymentTarget;
      }
    }
    patchReactNativeBundleScript(mod.modResults);
    return mod;
  });

  return withPodfile(nextConfig, (mod) => {
    const platformPattern =
      /platform :ios, podfile_properties\['ios\.deploymentTarget'\] \|\| '[^']+'/;
    mod.modResults.contents = mod.modResults.contents.replace(
      platformPattern,
      `platform :ios, podfile_properties['ios.deploymentTarget'] || '${deploymentTarget}'`,
    );

    let podfile = mod.modResults.contents;

    // Migrate an already-generated Podfile without leaving both targets in the
    // workspace. Subsequent runs take the ordinary idempotent path below.
    if (podfile.includes(LEGACY_POD_DECLARATION)) {
      podfile = podfile.replace(LEGACY_POD_DECLARATION, POD_DECLARATION);
      mod.modResults.contents = podfile;
    }

    // Idempotency check — do not add the line if it already exists.
    if (podfile.includes(POD_DECLARATION)) {
      return mod;
    }

    // Insert after the `use_react_native!(...)` closing paren + newline.
    // We match the closing ')' of use_react_native! followed by a newline.
    const USE_RN_CLOSE = /(\s+\)\s*\n)(\s*\n\s*post_install)/;

    if (USE_RN_CLOSE.test(podfile)) {
      mod.modResults.contents = podfile.replace(
        USE_RN_CLOSE,
        `$1${POD_LINE}\n$2`
      );
    } else {
      // Narrow fallback: only the final block terminator is a known target
      // boundary. Never let multiline `$` select an earlier nested `end`.
      const TARGET_END_AT_EOF = /(\n\s*end\s*)$/;
      if (TARGET_END_AT_EOF.test(podfile)) {
        mod.modResults.contents = podfile.replace(
          TARGET_END_AT_EOF,
          `${POD_LINE}\n$1`,
        );
      } else {
        console.warn(
          '[PocketLM] Podfile target boundary changed; local pod insertion skipped.',
        );
      }
    }

    return mod;
  });
};

module.exports = withPocketLMPod;
