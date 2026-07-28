'use strict';

/**
 * React Native 0.83.4's generateReactCodegenPodspec.js interpolates appPath
 * into two shell `find` commands without quoting it. This preload is installed
 * only by the version-and-SHA-guarded Podfile hook. It changes no files in
 * node_modules and touches only commands whose first path is under the exact
 * raw or normalized RCT_SCRIPT_APP_PATH.
 */

const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const expectedVersion = '0.83.4';
const expectedSha256 =
  '473f10259e7429b7d6d1b804d875d23748d95fda22bfe44a8343c9ea81cfa683';
const appPath =
  process.env.RCT_SCRIPT_APP_PATH || process.env.POCKETLM_CODEGEN_APP_PATH;
const reactNativePath =
  process.env.RCT_SCRIPT_RN_DIR || process.env.POCKETLM_CODEGEN_RN_DIR;

if (appPath && reactNativePath && /\s/.test(appPath)) {
  const packagePath = path.join(reactNativePath, 'package.json');
  const vulnerableScriptPath = path.join(
    reactNativePath,
    'scripts/codegen/generate-artifacts-executor/generateReactCodegenPodspec.js',
  );
  const version = JSON.parse(fs.readFileSync(packagePath, 'utf8')).version;
  const script = fs.readFileSync(vulnerableScriptPath);
  const sha256 = crypto.createHash('sha256').update(script).digest('hex');

  if (version !== expectedVersion || sha256 !== expectedSha256) {
    throw new Error(
      `[PocketLM] Refusing stale React Native codegen path shim: ` +
        `expected ${expectedVersion}/${expectedSha256}, got ${version}/${sha256}`,
    );
  }

  const originalExecSync = childProcess.execSync;
  const guardedRoots = [...new Set([appPath, path.resolve(appPath)])]
    .sort((left, right) => right.length - left.length);
  const shellQuote = value => `'${value.replace(/'/g, `'\\''`)}'`;

  childProcess.execSync = function pocketlmExecSync(command, ...args) {
    if (typeof command === 'string') {
      for (const guardedRoot of guardedRoots) {
        const unquotedPrefix = `find ${guardedRoot}`;
        if (
          command.startsWith(`${unquotedPrefix} `) ||
          command.startsWith(`${unquotedPrefix}/`)
        ) {
          command =
            `find ${shellQuote(guardedRoot)}` + command.slice(unquotedPrefix.length);
          break;
        }
      }
    }
    return originalExecSync.call(childProcess, command, ...args);
  };

  process.stderr.write(
    '[PocketLM] Applied guarded RN 0.83.4 codegen quoting for whitespace app path.\n',
  );
}
