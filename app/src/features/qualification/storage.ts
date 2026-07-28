import { Directory, File, Paths } from 'expo-file-system';
import type {
  QualificationArtifactSink,
  QualificationSuite,
} from './runner';

const RUN_ID_PATTERN = /^[a-z0-9][a-z0-9._-]{0,127}$/;
const COLLECTOR_NONCE_PATTERN = /^[0-9a-f]{32}$/;

function createJsonFile(directory: Directory, filename: string, value: unknown): void {
  const file = new File(directory, filename);
  const partial = new File(directory, `${filename}.partial`);
  partial.create({ intermediates: true, overwrite: true });
  partial.write(`${JSON.stringify(value, null, 2)}\n`);
  if (file.exists) file.delete();
  partial.move(file);
}

export function makeQualificationRunId(
  suite: QualificationSuite,
  now: Date = new Date(),
  random: () => number = Math.random,
): string {
  const timestamp = now.toISOString().replace(/[-:.]/g, '').toLowerCase();
  const nonce = Math.floor(random() * 0x1_0000_0000)
    .toString(16)
    .padStart(8, '0');
  return `m4-${suite}-${timestamp}-${nonce}`;
}

/**
 * Create a unique qualification result directory. COMPLETE.json is written
 * only after every selected suite and final manifest have been persisted.
 */
export function createQualificationArtifactSink(
  suite: QualificationSuite,
  collectorNonce: string | null,
  runId = makeQualificationRunId(suite),
): QualificationArtifactSink {
  if (!RUN_ID_PATTERN.test(runId)) {
    throw new Error('Qualification run ID is not a safe path component.');
  }
  if (
    collectorNonce !== null &&
    !COLLECTOR_NONCE_PATTERN.test(collectorNonce)
  ) {
    throw new Error('Collector nonce must be exactly 32 lowercase hexadecimal characters.');
  }

  const root = new Directory(Paths.document, 'PocketLM', 'M4');
  root.create({ intermediates: true, idempotent: true });
  const runDirectory = new Directory(root, runId);
  runDirectory.create({ intermediates: true, idempotent: true });
  createJsonFile(root, 'latest.json', {
    schemaVersion: 1,
    runId,
    suite,
    collectorNonce,
    createdAt: new Date().toISOString(),
  });

  return {
    runId,
    writeJson: async (filename: string, value: unknown): Promise<void> => {
      if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.json$/.test(filename)) {
        throw new Error(`Unsafe qualification artifact filename: ${filename}`);
      }
      createJsonFile(runDirectory, filename, value);
    },
  };
}
