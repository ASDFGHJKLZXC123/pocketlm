import { Directory, File, Paths } from 'expo-file-system';
import {
  getEmbeddedModelCatalog,
  type JsonValue,
  type PocketLMModelCatalog,
  type PocketLMModelCatalogEntry,
} from './catalog';

export type InstalledModelManifest = {
  schemaVersion: 1;
  catalogSchemaVersion: 1;
  selectedModelId: string;
  installedAt: string;
  backupExcluded: true;
  model: {
    id: string;
    displayName: string;
    family: string;
    selected: true;
    source: {
      repository: string;
      revision: string;
      artifactIntroducedRevision: string;
      filename: string;
      url: string;
    };
    byteSize: number;
    sha256: string;
    ggufMagic: string;
    ggufVersion: number;
    quantization: string;
    initialContextTokens: number;
    chatTemplateSource: string;
    chatTemplateVerified: true;
    appDirectoryName: string;
    installedFilename: string;
    requiredMetadata: Readonly<Record<string, JsonValue>>;
  };
};

export type ReadyInstalledModel = {
  kind: 'ready';
  model: PocketLMModelCatalogEntry;
  manifest: InstalledModelManifest;
  path: string;
};

export type ModelInstallationStatus =
  | { kind: 'checking' }
  | ReadyInstalledModel
  | {
      kind: 'missing' | 'invalid';
      model: PocketLMModelCatalogEntry | null;
      reason: string;
    };

export type InstalledModelFileFacts = {
  modelExists: boolean;
  manifestExists: boolean;
  partialExists: boolean;
  manifestPartialExists: boolean;
  modelSize: number;
  modelMagic: string;
  modelUri: string;
  manifestText: string;
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function jsonEqual(left: unknown, right: unknown): boolean {
  if (left === right) return true;
  if (Array.isArray(left) && Array.isArray(right)) {
    return (
      left.length === right.length &&
      left.every((value, index) => jsonEqual(value, right[index]))
    );
  }
  if (isRecord(left) && isRecord(right)) {
    const leftKeys = Object.keys(left).sort();
    const rightKeys = Object.keys(right).sort();
    return (
      leftKeys.length === rightKeys.length &&
      leftKeys.every(
        (key, index) =>
          key === rightKeys[index] && jsonEqual(left[key], right[key]),
      )
    );
  }
  return false;
}

function readManifest(value: unknown): InstalledModelManifest | null {
  if (!isRecord(value) || !isRecord(value['model'])) return null;
  const model = value['model'];
  if (!isRecord(model['source']) || !isRecord(model['requiredMetadata'])) {
    return null;
  }
  if (
    value['schemaVersion'] !== 1 ||
    value['catalogSchemaVersion'] !== 1 ||
    typeof value['selectedModelId'] !== 'string' ||
    typeof value['installedAt'] !== 'string' ||
    Number.isNaN(Date.parse(value['installedAt'])) ||
    value['backupExcluded'] !== true
  ) {
    return null;
  }
  return value as unknown as InstalledModelManifest;
}

/** Validate every persisted identity field against the embedded catalog. */
export function validateInstalledManifest(
  value: unknown,
  catalog: PocketLMModelCatalog,
): InstalledModelManifest {
  const manifest = readManifest(value);
  if (manifest === null) {
    throw new Error('The installed model manifest is malformed.');
  }
  const expected = catalog.models[0];
  const actual = manifest.model;
  if (
    manifest.selectedModelId !== expected.id ||
    actual.id !== expected.id ||
    actual.displayName !== expected.displayName ||
    actual.family !== expected.family ||
    actual.selected !== true ||
    actual.source.repository !== expected.repository ||
    actual.source.revision !== expected.revision ||
    actual.source.artifactIntroducedRevision !==
      expected.artifactIntroducedRevision ||
    actual.source.filename !== expected.filename ||
    actual.source.url !== expected.sourceUrl ||
    actual.byteSize !== expected.byteSize ||
    actual.sha256 !== expected.sha256 ||
    actual.ggufMagic !== expected.ggufMagic ||
    actual.ggufVersion !== expected.ggufVersion ||
    actual.quantization !== expected.quantization ||
    actual.initialContextTokens !== expected.initialContextTokens ||
    actual.chatTemplateSource !== expected.chatTemplateSource ||
    actual.chatTemplateVerified !== true ||
    actual.appDirectoryName !== expected.appDirectoryName ||
    actual.installedFilename !== expected.installedFilename ||
    !jsonEqual(actual.requiredMetadata, expected.requiredMetadata)
  ) {
    throw new Error('The installed model manifest does not match the catalog.');
  }
  return manifest;
}

export function fileUriToAbsolutePath(uri: string): string {
  const prefix = 'file://';
  if (!uri.startsWith(prefix)) {
    throw new Error('The installed model does not have a local file URI.');
  }
  const path = decodeURIComponent(uri.slice(prefix.length));
  if (!path.startsWith('/')) {
    throw new Error('The installed model path is not absolute.');
  }
  return path;
}

export function evaluateInstalledModel(
  catalog: PocketLMModelCatalog,
  facts: InstalledModelFileFacts,
): Exclude<ModelInstallationStatus, { kind: 'checking' }> {
  const model = catalog.models[0];
  if (!facts.modelExists && !facts.manifestExists) {
    if (facts.partialExists || facts.manifestPartialExists) {
      return {
        kind: 'invalid',
        model,
        reason: 'An incomplete model import was found; seed it again.',
      };
    }
    return {
      kind: 'missing',
      model,
      reason: 'The verified model has not been seeded into this app sandbox.',
    };
  }
  if (!facts.modelExists || !facts.manifestExists) {
    return {
      kind: 'invalid',
      model,
      reason: 'The model file and manifest are not an atomic installed pair.',
    };
  }

  try {
    const parsed: unknown = JSON.parse(facts.manifestText);
    const manifest = validateInstalledManifest(parsed, catalog);
    if (facts.modelSize !== model.byteSize) {
      throw new Error(
        `Model size mismatch: expected ${String(model.byteSize)} bytes, got ` +
          `${String(facts.modelSize)}.`,
      );
    }
    if (facts.modelMagic !== model.ggufMagic) {
      throw new Error('The installed file does not have GGUF magic.');
    }
    return {
      kind: 'ready',
      model,
      manifest,
      path: fileUriToAbsolutePath(facts.modelUri),
    };
  } catch (error: unknown) {
    return {
      kind: 'invalid',
      model,
      reason: error instanceof Error ? error.message : String(error),
    };
  }
}

function readMagic(file: File): string {
  const handle = file.open();
  try {
    const bytes = handle.readBytes(4);
    return String.fromCharCode(...bytes);
  } finally {
    handle.close();
  }
}

/**
 * Validate the published sandbox pair without rehashing 491 MB on the JS
 * thread. The atomic seed/import path authenticates source, partial, and final
 * SHA-256 before it writes this catalog-derived manifest.
 */
export async function inspectInstalledModel(): Promise<
  Exclude<ModelInstallationStatus, { kind: 'checking' }>
> {
  let catalog: PocketLMModelCatalog;
  try {
    catalog = getEmbeddedModelCatalog();
  } catch (error: unknown) {
    return {
      kind: 'invalid',
      model: null,
      reason: error instanceof Error ? error.message : String(error),
    };
  }

  const model = catalog.models[0];
  const directory = new Directory(
    Paths.document.parentDirectory,
    'Library',
    'Application Support',
    'PocketLM',
    'Models',
    model.appDirectoryName,
  );
  const modelFile = new File(directory, model.installedFilename);
  const manifestFile = new File(directory, 'manifest.json');
  const partialFile = new File(directory, `${model.installedFilename}.partial`);
  const manifestPartialFile = new File(directory, 'manifest.json.partial');

  try {
    const modelExists = modelFile.exists;
    const manifestExists = manifestFile.exists;
    const facts: InstalledModelFileFacts = {
      modelExists,
      manifestExists,
      partialExists: partialFile.exists,
      manifestPartialExists: manifestPartialFile.exists,
      modelSize: modelExists ? modelFile.size : 0,
      modelMagic: modelExists ? readMagic(modelFile) : '',
      modelUri: modelFile.uri,
      manifestText: manifestExists ? await manifestFile.text() : '',
    };
    return evaluateInstalledModel(catalog, facts);
  } catch (error: unknown) {
    return {
      kind: 'invalid',
      model,
      reason:
        error instanceof Error
          ? `Unable to inspect the installed model: ${error.message}`
          : `Unable to inspect the installed model: ${String(error)}`,
    };
  }
}
