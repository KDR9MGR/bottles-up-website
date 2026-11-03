// Stand-in for `npm:@anthropic-ai/sdk@1` inside edge-function tests. A test sets what the "model" answers through `model.answer`; nothing leaves the machine.
export const model: {
  answer: (request: Record<string, unknown>) => Promise<unknown>;
  calls: Record<string, unknown>[];
  apiKeys: unknown[];
} = {
  answer: async () => ({ stop_reason: 'end_turn', content: [{ type: 'text', text: '{"captions": ["One", "Two", "Three"]}' }] }),
  calls: [],
  apiKeys: [],
};

export default class Anthropic {
  constructor(options: { apiKey?: string }) {
    model.apiKeys.push(options.apiKey);
  }

  beta = {
    messages: {
      create: async (request: Record<string, unknown>) => {
        model.calls.push(request);
        return model.answer(request);
      },
    },
  };
}
