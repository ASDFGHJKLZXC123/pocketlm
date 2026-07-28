import {
  evaluateInstalledModel,
  fileUriToAbsolutePath,
  validateInstalledManifest,
  type InstalledModelFileFacts,
  type InstalledModelManifest,
} from '../src/features/models/storage';
import {
  parseModelCatalog,
  type PocketLMModelCatalog,
} from '../src/features/models/catalog';
import repositoryCatalog from '../../models/catalog.json';

const catalog: PocketLMModelCatalog = parseModelCatalog({
  schemaVersion: 1,
  models: [
    {
      id: 'qwen2.5-0.5b-instruct-q4-k-m',
      displayName: 'Qwen2.5 0.5B Instruct (Q4_K_M)',
      family: 'qwen2',
      repository: 'Qwen/Qwen2.5-0.5B-Instruct-GGUF',
      revision: '1'.repeat(40),
      artifactIntroducedRevision: '2'.repeat(40),
      filename: 'source.gguf',
      sourceUrl:
        'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/' +
        `resolve/${'1'.repeat(40)}/source.gguf`,
      byteSize: 1234,
      sha256: 'a'.repeat(64),
      ggufMagic: 'GGUF',
      ggufVersion: 3,
      quantization: 'Q4_K_M',
      parameterCountApproximate: '0.49B',
      license: 'Apache-2.0',
      licenseUrl: 'https://example.test/license',
      gated: false,
      initialContextTokens: 2048,
      chatTemplateSource: 'gguf_metadata',
      chatTemplateVerified: true,
      appDirectoryName: 'qwen-model',
      installedFilename: 'model.gguf',
      requiredMetadata: {
        'general.architecture': 'qwen2',
        'general.file_type': 15,
        'tokenizer.ggml.model': 'gpt2',
        'tokenizer.ggml.pre': 'qwen2',
        'tokenizer.chat_template': {
          nonEmpty: true,
          contains: [
            '<|im_start|>',
            '<|im_end|>',
            'add_generation_prompt',
          ],
        },
      },
    },
  ],
});

function manifest(): InstalledModelManifest {
  const model = catalog.models[0];
  return {
    schemaVersion: 1,
    catalogSchemaVersion: 1,
    selectedModelId: model.id,
    installedAt: '2026-07-17T12:00:00Z',
    backupExcluded: true,
    model: {
      id: model.id,
      displayName: model.displayName,
      family: model.family,
      selected: true,
      source: {
        repository: model.repository,
        revision: model.revision,
        artifactIntroducedRevision: model.artifactIntroducedRevision,
        filename: model.filename,
        url: model.sourceUrl,
      },
      byteSize: model.byteSize,
      sha256: model.sha256,
      ggufMagic: model.ggufMagic,
      ggufVersion: model.ggufVersion,
      quantization: model.quantization,
      initialContextTokens: model.initialContextTokens,
      chatTemplateSource: model.chatTemplateSource,
      chatTemplateVerified: true,
      appDirectoryName: model.appDirectoryName,
      installedFilename: model.installedFilename,
      requiredMetadata: model.requiredMetadata,
    },
  };
}

function facts(
  overrides: Partial<InstalledModelFileFacts> = {},
): InstalledModelFileFacts {
  return {
    modelExists: true,
    manifestExists: true,
    partialExists: false,
    manifestPartialExists: false,
    modelSize: catalog.models[0].byteSize,
    modelMagic: 'GGUF',
    modelUri:
      'file:///var/mobile/Containers/Data/Application/ABC/Library/' +
      'Application%20Support/PocketLM/Models/qwen-model/model.gguf',
    manifestText: JSON.stringify(manifest()),
    ...overrides,
  };
}

describe('installed model storage', () => {
  it('accepts the repository catalog shared with host provisioning', () => {
    const parsed = parseModelCatalog(repositoryCatalog);
    expect(parsed.models).toHaveLength(1);
    expect(parsed.models[0].sha256).toBe(
      '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db',
    );
  });

  it('accepts only a complete pair matching the embedded catalog', () => {
    const status = evaluateInstalledModel(catalog, facts());
    expect(status.kind).toBe('ready');
    if (status.kind === 'ready') {
      expect(status.path).toContain('/Library/Application Support/PocketLM/');
      expect(status.manifest.selectedModelId).toBe(catalog.models[0].id);
    }
  });

  it('distinguishes a clean missing install from an interrupted partial', () => {
    expect(
      evaluateInstalledModel(
        catalog,
        facts({
          modelExists: false,
          manifestExists: false,
          modelSize: 0,
          modelMagic: '',
          manifestText: '',
        }),
      ).kind,
    ).toBe('missing');
    expect(
      evaluateInstalledModel(
        catalog,
        facts({
          modelExists: false,
          manifestExists: false,
          partialExists: true,
          modelSize: 0,
          modelMagic: '',
          manifestText: '',
        }),
      ).kind,
    ).toBe('invalid');
  });

  const invalidCases: readonly [
    string,
    Partial<InstalledModelFileFacts>,
  ][] = [
    ['wrong byte count', { modelSize: 1233 }],
    ['corrupt magic', { modelMagic: 'NOPE' }],
    [
      'catalog hash drift',
      {
        manifestText: JSON.stringify({
          ...manifest(),
          model: { ...manifest().model, sha256: 'b'.repeat(64) },
        }),
      },
    ],
  ];
  for (const [name, overrides] of invalidCases) {
    it(`rejects ${name}`, () => {
      expect(evaluateInstalledModel(catalog, facts(overrides)).kind).toBe(
        'invalid',
      );
    });
  }

  it('rejects an otherwise valid manifest without backup exclusion', () => {
    const value = { ...manifest(), backupExcluded: false };
    expect(() => validateInstalledManifest(value, catalog)).toThrow(
      /manifest is malformed/,
    );
  });

  it('converts only local absolute file URIs for the native bridge', () => {
    expect(fileUriToAbsolutePath('file:///tmp/A%20B/model.gguf')).toBe(
      '/tmp/A B/model.gguf',
    );
    expect(() => fileUriToAbsolutePath('https://example.test/model')).toThrow(
      /local file URI/,
    );
  });

  it('rejects unsafe catalog paths before constructing sandbox locations', () => {
    const unsafe = {
      ...catalog.models[0],
      appDirectoryName: '../escape',
    };
    expect(() =>
      parseModelCatalog({ schemaVersion: 1, models: [unsafe] }),
    ).toThrow(/safe path component/);
  });

  it('rejects unpinned source identity and incomplete metadata', () => {
    expect(() =>
      parseModelCatalog({
        schemaVersion: 1,
        models: [{ ...catalog.models[0], revision: 'main' }],
      }),
    ).toThrow(/pinned commits/);

    const metadata = {
      ...catalog.models[0].requiredMetadata,
      'tokenizer.ggml.pre': 'wrong',
    };
    expect(() =>
      parseModelCatalog({
        schemaVersion: 1,
        models: [{ ...catalog.models[0], requiredMetadata: metadata }],
      }),
    ).toThrow(/Qwen2-compatible/);
  });
});
