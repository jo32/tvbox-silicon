// OpenAI Responses transport. The matcher owns the tools, budgets and verdict rules for both providers.
import { ModelError, type ToolCall, type ToolResult } from "./model.ts";
import type { Fetcher } from "./tmdb.ts";

export interface OpenAI {
  provider: "openai";
  key: string;
  model: string;
  fetcher?: Fetcher;
  api?: string;
}

interface Tool {
  name: string;
  description: string;
  parameters: unknown;
}

export class OpenAISession {
  private input: any[];
  private config: OpenAI;
  private instructions: string;
  private tools: Tool[];
  private signal?: AbortSignal;

  constructor(config: OpenAI, instructions: string, tools: Tool[], message: string, signal?: AbortSignal) {
    this.config = config;
    this.instructions = instructions;
    this.tools = tools;
    this.signal = signal;
    this.input = [{ role: "user", content: message }];
  }

  remind() {
    this.input.push({ role: "user", content: "Use a tool, or submit." });
  }

  respond(results: ToolResult[]) {
    for (const { call, result } of results) {
      this.input.push({ type: "function_call_output", call_id: call.id, output: JSON.stringify({ result }) });
    }
  }

  async ask(last: boolean) {
    const { config, signal } = this;
    const body = JSON.stringify({
      model: config.model,
      instructions: this.instructions,
      input: this.input,
      tools: this.tools.map((tool) => ({ type: "function", ...tool, strict: false })),
      tool_choice: last ? { type: "function", name: "submit" } : "required",
      reasoning: { effort: "low" },
      // Keep the conversation here, including encrypted reasoning needed by later tool turns.
      store: false,
      include: ["reasoning.encrypted_content"],
      max_output_tokens: 4096,
    });
    for (let attempt = 0; ; attempt++) {
      let response: Response;
      try {
        response = await (config.fetcher ?? fetch)(`${config.api ?? "https://api.openai.com/v1"}/responses`, {
          method: "POST",
          headers: { authorization: `Bearer ${config.key}`, "content-type": "application/json" },
          body,
          signal,
        });
      } catch (error) {
        if (attempt < 1 && !signal?.aborted) continue;
        throw new ModelError(`OpenAI unreachable: ${(error as Error).message}`);
      }
      if (!response.ok) {
        const text = (await response.text()).replaceAll(config.key, "[redacted]").slice(0, 2000);
        const failure = new ModelError(`OpenAI ${response.status}: ${text}`);
        // An exhausted account needs attention; retry only short rate limits and transient server errors.
        if (attempt >= 3 || (response.status !== 429 && response.status < 500) || /insufficient_quota|billing_hard_limit_reached/.test(text)) throw failure;
        const retry = response.headers.get("retry-after");
        const seconds = retry === null ? NaN : Number(retry);
        const delay = Number.isFinite(seconds) ? Math.max(0, seconds * 1000) : retry ? Math.max(0, Date.parse(retry) - Date.now()) : NaN;
        if (delay > 30_000) throw failure;
        await new Promise<void>((resolve, reject) => {
          signal?.throwIfAborted();
          const abort = () => { clearTimeout(timer); reject(signal!.reason); };
          const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); resolve(); }, Number.isFinite(delay) ? delay : 2000 * (attempt + 1));
          signal?.addEventListener("abort", abort, { once: true });
        });
        continue;
      }
      let value: any;
      try { value = await response.json(); } catch { throw new ModelError("OpenAI returned invalid JSON."); }
      if (value.status !== "completed" || !Array.isArray(value.output) || !value.output.length) {
        throw new ModelError(`OpenAI gave no complete answer (${value.incomplete_details?.reason ?? value.status ?? "?"})`);
      }
      const calls: ToolCall[] = value.output.filter((item: any) => item.type === "function_call").map((item: any) => {
        let args: unknown;
        try { args = JSON.parse(item.arguments); } catch { throw new ModelError("OpenAI returned invalid tool arguments."); }
        if (!item.call_id || typeof item.name !== "string" || !args || typeof args !== "object" || Array.isArray(args)) {
          throw new ModelError("OpenAI returned an invalid tool call.");
        }
        return { id: item.call_id, name: item.name, args };
      });
      // Replay every output item verbatim, including reasoning and its encrypted content.
      this.input.push(...value.output);
      return { calls, tokens: value.usage?.total_tokens ?? 0, cached: value.usage?.input_tokens_details?.cached_tokens ?? 0 };
    }
  }
}
