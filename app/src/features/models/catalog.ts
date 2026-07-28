import Constants from 'expo-constants';

export type PocketLMModelCatalogEntry = {
  id: string;
  displayName: string;
  family: 'qwen2';
  repository: string;
  revision: string;
  artifactIntroducedRevision: string;
  filename: string;
  sourceUrl: string;
  byteSize: number;
  sha256: string;
  ggufMagic: 'GGUF';
  ggufVersion: number;
  quantization: 'Q4_K_M';
  parameterCountApproximate: string;
  license: string;
  licenseUrl: string;
  gated: false;
  initialContextTokens: number;
  chatTemplateSource: 'gguf_metadata';
  chatTemplateVerified: true;
  appDirectoryName: string;
  installedFilename: 'model.gguf';
  requiredMetadata: Readonly<Record<string, JsonValue>>;
};

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | readonly JsonValue[]
  | { readonly [key: string]: JsonValue };

export type PocketLMModelCatalog = {
  schemaVersion: 1;
  models: readonly [PocketLMModelCatalogEntry];
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function readString(
  record: Record<string, unknown>,
  key: string,
): string | null {
  const value = record[key];
  return typeof value === 'string' && value.length > 0 ? value : null;
}

const SAFE_PATH_COMPONENT = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const PINNED_REVISION = /^[a-f0-9]{40}$/;

function requireSafePathComponent(
  model: Record<string, unknown>,
  key: 'id' | 'appDirectoryName' | 'installedFilename' | 'filename',
): void {
  const value = readString(model, key);
  if (value === null || !SAFE_PATH_COMPONENT.test(value)) {
    throw new Error(`The catalog ${key} is not a safe path component.`);
  }
}

function validateRequiredMetadata(model: Record<string, unknown>): void {
  const metadata = model['requiredMetadata'];
  if (!isRecord(metadata)) {
    throw new Error('The catalog model is missing required GGUF metadata.');
  }
  if (metadata['general.architecture'] !== model['family']) {
    throw new Error('The catalog GGUF architecture does not match its family.');
  }
  if (metadata['general.file_type'] !== 15) {
    throw new Error('The catalog GGUF file type does not match Q4_K_M.');
  }
  if (
    metadata['tokenizer.ggml.model'] !== 'gpt2' ||
    metadata['tokenizer.ggml.pre'] !== 'qwen2'
  ) {
    throw new Error('The catalog tokenizer metadata is not Qwen2-compatible.');
  }

  const template = metadata['tokenizer.chat_template'];
  if (!isRecord(template) || template['nonEmpty'] !== true) {
    throw new Error('The catalog must require a nonempty GGUF chat template.');
  }
  const contains = template['contains'];
  if (
    !Array.isArray(contains) ||
    contains.length === 0 ||
    !contains.every((item) => typeof item === 'string' && item.length > 0) ||
    !contains.includes('<|im_start|>') ||
    !contains.includes('<|im_end|>') ||
    !contains.includes('add_generation_prompt')
  ) {
    throw new Error('The catalog chat template requirements are incomplete.');
  }
}

/**
 * Validate the build-time catalog before any path is trusted. The repository
 * JSON is the sole model-identity source; this function only narrows the
 * immutable object embedded by app.config.ts.
 */
export function parseModelCatalog(value: unknown): PocketLMModelCatalog {
  if (!isRecord(value) || value['schemaVersion'] !== 1) {
    throw new Error('The embedded model catalog has an unsupported schema.');
  }
  const models = value['models'];
  if (!Array.isArray(models) || models.length !== 1 || !isRecord(models[0])) {
    throw new Error('PocketLM requires exactly one catalog model.');
  }

  const model = models[0];
  const requiredStrings = [
    'id',
    'displayName',
    'repository',
    'revision',
    'artifactIntroducedRevision',
    'filename',
    'sourceUrl',
    'sha256',
    'parameterCountApproximate',
    'license',
    'licenseUrl',
    'appDirectoryName',
    'installedFilename',
  ] as const;
  for (const key of requiredStrings) {
    if (readString(model, key) === null) {
      throw new Error(`The catalog model is missing ${key}.`);
    }
  }

  for (const key of [
    'id',
    'appDirectoryName',
    'installedFilename',
    'filename',
  ] as const) {
    requireSafePathComponent(model, key);
  }
  if (!(model['installedFilename'] as string).endsWith('.gguf')) {
    throw new Error('The catalog installed filename must end in .gguf.');
  }

  const revision = model['revision'] as string;
  const artifactRevision = model['artifactIntroducedRevision'] as string;
  if (
    !PINNED_REVISION.test(revision) ||
    !PINNED_REVISION.test(artifactRevision)
  ) {
    throw new Error('The catalog revisions must be pinned commits.');
  }
  const expectedSourceUrl =
    `https://huggingface.co/${model['repository'] as string}/resolve/` +
    `${revision}/${model['filename'] as string}`;
  if (model['sourceUrl'] !== expectedSourceUrl) {
    throw new Error('The catalog source URL does not match its pinned identity.');
  }

  if (
    model['family'] !== 'qwen2' ||
    model['ggufMagic'] !== 'GGUF' ||
    model['quantization'] !== 'Q4_K_M' ||
    model['installedFilename'] !== 'model.gguf' ||
    model['chatTemplateSource'] !== 'gguf_metadata' ||
    model['chatTemplateVerified'] !== true ||
    model['gated'] !== false ||
    !Number.isSafeInteger(model['byteSize']) ||
    (model['byteSize'] as number) <= 0 ||
    !Number.isSafeInteger(model['initialContextTokens']) ||
    (model['initialContextTokens'] as number) <= 0 ||
    !Number.isSafeInteger(model['ggufVersion']) ||
    (model['ggufVersion'] as number) <= 0 ||
    !/^[a-f0-9]{64}$/.test(model['sha256'] as string)
  ) {
    throw new Error('The embedded catalog model identity is invalid.');
  }

  validateRequiredMetadata(model);

  return value as unknown as PocketLMModelCatalog;
}

export function getEmbeddedModelCatalog(): PocketLMModelCatalog {
  const extra = Constants.expoConfig?.extra;
  return parseModelCatalog(extra?.['pocketlmModelCatalog']);
}

export function getPocketLMModel(): PocketLMModelCatalogEntry {
  return getEmbeddedModelCatalog().models[0];
}
