import assert from "node:assert/strict";
import test from "node:test";
import { identify, ModelError } from "../src/agent.ts";
import { OpenAISession, type OpenAI } from "../src/openai.ts";
import { modelConfig } from "../src/provider.ts";
import { TMDB, UpstreamError } from "../src/tmdb.ts";

const call = (name: string, args: unknown, id = name) => ({ type: "function_call", id: `fc_${id}`, call_id: id, name, arguments: JSON.stringify(args) });
const submit = () => call("submit", { status: "notFound", confidence: 0, reason: "No matching work." });
const completed = (output: unknown[]) => Response.json({ status: "completed", output, usage: { total_tokens: 100, input_tokens_details: { cached_tokens: 20 } } });

function model(turns: unknown[][]) {
  const sent: any[] = [];
  const config: OpenAI = {
    provider: "openai", key: "test-key", model: "gpt-6-luna",
    fetcher: async (url, init) => {
      assert.equal(url, "https://api.openai.com/v1/responses");
      assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-key");
      sent.push(JSON.parse(String(init?.body)));
      assert.ok(turns.length, "unexpected extra model turn");
      return completed(turns.shift()!);
    },
  };
  return { config, sent };
}

test("provider defaults to Luna, retains Gemini, and fails explicitly for missing credentials or unknown providers", () => {
  assert.deepEqual(modelConfig({ OPENAI_API_KEY: " k " }), { provider: "openai", key: "k", model: "gpt-6-luna" });
  assert.deepEqual(modelConfig({ AI_PROVIDER: "gemini", GEMINI_API_KEY: "g" }), { provider: "gemini", key: "g", model: "gemini-3.5-flash-lite" });
  assert.equal(modelConfig({ OPENAI_API_KEY: "k", OPENAI_MODEL: "chosen" }).model, "chosen");
  assert.throws(() => modelConfig({ GEMINI_API_KEY: "g" }), /OPENAI_API_KEY/);
  assert.throws(() => modelConfig({ AI_PROVIDER: "gemini", OPENAI_API_KEY: "k" }), /GEMINI_API_KEY/);
  assert.throws(() => modelConfig({ AI_PROVIDER: "typo", OPENAI_API_KEY: "k" }), /AI_PROVIDER/);
});

test("Luna replays reasoning and parallel tool results by call ID, shares budgets and validates its verdict", async () => {
  let searches = 0;
  const tmdb = new TMDB("t", async url => {
    if (url.includes("/search/")) {
      searches++;
      return Response.json({ results: [{ id: 7, name: "繁花", first_air_date: "2023-12-27" }] });
    }
    return Response.json({ id: 7, name: "繁花", first_air_date: "2023-12-27", seasons: [{ season_number: 1, episode_count: 30 }] });
  }, null);
  const reasoning = { type: "reasoning", id: "rs_1", summary: [], encrypted_content: "opaque" };
  const { config, sent } = model([
    [reasoning, call("search", { query: "繁花", type: "tv" }, "a"), call("search", { query: "Blossoms", type: "tv" }, "b")],
    [call("submit", { status: "matched", mediaType: "tv", id: 7, season: 1, confidence: 0.95, reason: "Name and year agree." })],
  ]);
  const events: any[] = [];
  const answer = await identify({ title: "繁花", year: "2023", type: "tv" }, tmdb, config, event => events.push(event), { searches: 1, details: 1, seasons: 1, turns: 2 });
  assert.equal(answer.verdict.status, "matched");
  assert.equal(answer.verdict.id, 7);
  assert.equal(answer.tokens, 200);
  assert.equal(answer.cachedTokens, 40);
  assert.equal(searches, 1);
  assert.equal(events.filter(event => event.step === "search").length, 1);
  assert.equal(sent[0].model, "gpt-6-luna");
  assert.equal(sent[0].store, false);
  assert.equal(sent[0].tool_choice, "required");
  assert.equal(sent[0].reasoning.effort, "low");
  assert.deepEqual(sent[0].include, ["reasoning.encrypted_content"]);
  assert.match(sent[0].input[0].content, /繁花/);
  assert.ok(sent[0].tools.every((tool: any) => tool.type === "function" && tool.strict === false));
  assert.deepEqual(sent[1].input[1], reasoning);
  const outputs = sent[1].input.filter((item: any) => item.type === "function_call_output");
  assert.deepEqual(outputs.map((item: any) => item.call_id), ["a", "b"]);
  assert.equal(JSON.parse(outputs[0].output).result.results[0].id, 7);
  assert.match(outputs[1].output, /No searches left/);
  assert.deepEqual(sent[1].tool_choice, { type: "function", name: "submit" });
});

test("Luna can reject a short drama before searching and cannot submit an unseen TMDB ID", async () => {
  const tmdb = new TMDB("t", async () => { throw new Error("Must not search"); }, null);
  for (const final of [submit(), call("submit", { status: "matched", mediaType: "movie", id: 999, confidence: 1 })]) {
    const { config } = model([[final]]);
    const answer = await identify({ title: "短剧", category: "短剧" }, tmdb, config, () => {});
    assert.equal(answer.verdict.status, "notFound");
  }
});

test("Luna stops on TMDB failure instead of caching notFound", async () => {
  const tmdb = new TMDB("t", async () => Response.json({}, { status: 401 }), null);
  const { config } = model([[call("search", { query: "x", type: "tv" })]]);
  await assert.rejects(identify({ title: "x" }, tmdb, config, () => {}), UpstreamError);
});

test("Luna rejects incomplete responses and malformed calls as model failures", async () => {
  const tmdb = new TMDB("t", async () => Response.json({}), null);
  const invalid = [
    { status: "incomplete", incomplete_details: { reason: "max_output_tokens" }, output: [submit()] },
    { status: "completed", output: [] },
    { status: "completed", output: [{ ...submit(), arguments: "{" }] },
    { status: "completed", output: [{ ...submit(), arguments: "null" }] },
    { status: "completed", output: [{ ...submit(), call_id: null }] },
  ];
  for (const value of invalid) {
    await assert.rejects(identify({ title: "x" }, tmdb, { provider: "openai", key: "k", model: "m", fetcher: async () => Response.json(value) }, () => {}), ModelError);
  }
});

test("OpenAI retries short rate limits, fails immediately on quota or long waits, and redacts credentials", async () => {
  for (const [code, retry, expected] of [["rate_limit_exceeded", "0", 2], ["insufficient_quota", "0", 1], ["rate_limit_exceeded", "60", 1]] as const) {
    let requests = 0;
    const session = new OpenAISession({ provider: "openai", key: "secret", model: "m", fetcher: async () => {
      if (++requests > 1) return completed([submit()]);
      return Response.json({ error: { code, message: "secret" } }, { status: 429, headers: { "retry-after": retry } });
    } }, "instructions", [], "source");
    if (expected === 2) assert.equal((await session.ask(false)).calls[0].name, "submit");
    else await assert.rejects(session.ask(false), error => error instanceof ModelError && !error.message.includes("secret"));
    assert.equal(requests, expected);
  }
});

test("OpenAI respects cancellation while waiting to retry", async () => {
  const controller = new AbortController();
  let requests = 0;
  const session = new OpenAISession({ provider: "openai", key: "k", model: "m", fetcher: async () => {
    requests++;
    return Response.json({}, { status: 429, headers: { "retry-after": "30" } });
  } }, "instructions", [], "source", controller.signal);
  const pending = session.ask(false);
  setTimeout(() => controller.abort(), 5);
  await assert.rejects(pending, { name: "AbortError" });
  assert.equal(requests, 1);
});
