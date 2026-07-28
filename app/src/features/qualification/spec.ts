import type {
  GenerationParams,
  NativeChatMessage,
  SessionConfig,
} from '../../lib/NativePocketLM';

/**
 * This is intentionally a frozen workload, not an interactive benchmark.
 * Changing any value here creates a different qualification workload and must
 * result in a new validation run.
 */
export const M4_WORKLOAD_VERSION = 'm4-workload-v2' as const;

export const M4_SESSION_CONFIG: SessionConfig = {
  contextSize: 2048,
  accelerator: 'cpu',
  gpuLayers: 0,
};

const FIXED_SAMPLING = {
  temperature: 0.2,
  topK: 20,
  topP: 0.8,
  seed: 424_242,
  nThreads: 4,
} as const;

export const M4_PARAMS = {
  reproducibility: {
    ...FIXED_SAMPLING,
    maxTokens: 64,
  },
  utf8: {
    ...FIXED_SAMPLING,
    maxTokens: 16,
  },
  cancellation: {
    ...FIXED_SAMPLING,
    maxTokens: 256,
  },
  memory: {
    ...FIXED_SAMPLING,
    maxTokens: 32,
  },
  benchmark: {
    ...FIXED_SAMPLING,
    maxTokens: 512,
  },
} as const satisfies Readonly<Record<string, GenerationParams>>;

export const REPRODUCIBILITY_PROMPT =
  'Return exactly one short sentence explaining why deterministic seeds are useful.';

export const CANCELLATION_PROMPT =
  'Write a detailed numbered list of 200 distinct ways to organize a personal library. ' +
  'Keep generating until the list is complete.';

export const MEMORY_PROMPT =
  'In two short sentences, explain what model unloading should release.';

export type Utf8CorpusCase = {
  id: string;
  category: 'emoji-cjk-rtl';
  prompt: string;
};

const UTF8_SOURCE_LINES = [
  '🌍 你好世界 — مرحبا بالعالم',
  '🚀 今日は — שלום עולם',
  '🧠 学习与推理 — التعلم والاستدلال',
  '🌱 可持续未来 — עתיד בר־קיימא',
  '🎨 色彩と形 — اللون والشكل',
  '🎵 音乐とリズム — מוזיקה וקצב',
  '🧪 科学实验 — تجربة علمية',
  '📚 物語と知識 — סיפורים וידע',
  '🏙️ 城市生活 — الحياة في المدينة',
  '🤝 合作と信頼 — שיתוף פעולה ואמון',
  '⛅ 天气と季節 — الطقس والفصول',
  '🍎 健康な食事 — אוכל בריא',
  '🚂 旅行計画 — خطة سفر',
  '💡 創意と解決 — יצירתיות ופתרון',
  '🔒 安全とプライバシー — الأمان والخصوصية',
  '🤖 人工知能 — בינה מלאכותית',
  '🌊 海と生態系 — البحر والنظام البيئي',
  '🏛️ 歴史と文化 — היסטוריה ותרבות',
  '🔭 宇宙と星 — الفضاء والنجوم',
  '⚙️ 工具と仕組み — כלים ומנגנונים',
  '🦋 変化と成長 — التغيير والنمو',
  '🏡 家と安心 — בית ושלווה',
  '🏃 運動と健康 — الرياضة والصحة',
  '💬 対話と理解 — דיאלוג והבנה',
  '🎉 祝いと喜び — الاحتفال والفرح',
] as const;

const UTF8_INSTRUCTIONS = [
  'Repeat the line exactly, then add one English word:',
  'Summarize the meaning in one short English sentence:',
  'List the scripts and emoji you can identify in this line:',
  'Respond with a friendly acknowledgement that preserves the line:',
] as const;

export const UTF8_CORPUS: readonly Utf8CorpusCase[] = Object.freeze(
  UTF8_INSTRUCTIONS.flatMap((instruction, instructionIndex) =>
    UTF8_SOURCE_LINES.map((source, sourceIndex) => ({
      id:
        `utf8-${String(instructionIndex + 1).padStart(2, '0')}-` +
        String(sourceIndex + 1).padStart(2, '0'),
      category: 'emoji-cjk-rtl' as const,
      prompt: `${instruction} ${source}`,
    })),
  ),
);

export type BenchmarkPrompt = {
  id: string;
  prompt: string;
  qualityDimension: string;
};

export const BENCHMARK_PROMPTS: readonly BenchmarkPrompt[] = Object.freeze([
  {
    id: 'bench-summary',
    qualityDimension: 'instruction following and factual compression',
    prompt:
      'In three bullet points, explain why on-device language models can improve privacy. ' +
      'Mention one limitation.',
  },
  {
    id: 'bench-reasoning',
    qualityDimension: 'basic reasoning and explanation',
    prompt:
      'A notebook costs $8 and a pen costs $3. Explain the total cost of two notebooks ' +
      'and three pens, showing the arithmetic.',
  },
  {
    id: 'bench-code',
    qualityDimension: 'small code generation',
    prompt:
      'Write a TypeScript function named clamp that constrains a number between min and max. ' +
      'Return only one fenced code block.',
  },
  {
    id: 'bench-rewrite',
    qualityDimension: 'concise rewriting',
    prompt:
      'Rewrite this sentence to be concise and professional: "I just wanted to reach out ' +
      'and let you know that the meeting has been moved to tomorrow morning."',
  },
  {
    id: 'bench-multilingual',
    qualityDimension: 'Unicode and multilingual response',
    prompt:
      'Answer in one line containing all three: a friendly greeting in Chinese, Arabic, ' +
      'and Hebrew, followed by one smiling emoji.',
  },
]);

/**
 * Three predeclared rotations keep prompt order deterministic and distribute
 * early/middle/late positions without choosing an order after seeing results.
 */
export const BENCHMARK_ORDER: readonly (readonly number[])[] = Object.freeze([
  Object.freeze([0, 1, 2, 3, 4]),
  Object.freeze([2, 3, 4, 0, 1]),
  Object.freeze([4, 0, 1, 2, 3]),
]);

export function singleUserMessage(prompt: string): readonly NativeChatMessage[] {
  return [{ role: 'user', content: prompt }];
}
