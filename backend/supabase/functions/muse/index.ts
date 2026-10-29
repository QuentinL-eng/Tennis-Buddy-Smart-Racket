// Muse Spark proxy. The Meta API key lives only in this function's secrets (META_API_KEY);
// the app authenticates with the signed-in user's Supabase session.
import { createClient } from "npm:@supabase/supabase-js@2";

const ENDPOINT = "https://api.meta.ai/v1/chat/completions";
const MODEL = "muse-spark-1.3";
const MAX_BODY_BYTES = 256 * 1024;

const json = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "method" }, 405);

  const token = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "unauthorized" }, 401);
  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_ANON_KEY")!);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user) return json({ error: "unauthorized" }, 401);

  const raw = await req.text();
  if (raw.length > MAX_BODY_BYTES) return json({ error: "too large" }, 413);
  let input: Record<string, unknown>;
  try { input = JSON.parse(raw); } catch { return json({ error: "bad json" }, 400); }
  if (!Array.isArray(input.messages)) return json({ error: "messages required" }, 400);

  // Only forward fields the app needs, with the model and limits pinned server-side.
  const body: Record<string, unknown> = {
    model: MODEL,
    messages: input.messages,
    max_completion_tokens: Math.min(Number(input.max_completion_tokens) || 2048, 2048),
    reasoning_effort: "low",
  };
  if (Array.isArray(input.tools) && input.tools.length > 0) {
    body.tools = input.tools;
    body.tool_choice = "auto";
  }

  const upstream = await fetch(ENDPOINT, {
    method: "POST",
    headers: { Authorization: `Bearer ${Deno.env.get("META_API_KEY")}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(40_000),
  }).catch(() => null);
  if (!upstream) return json({ error: "upstream unreachable" }, 502);
  return new Response(upstream.body, { status: upstream.status, headers: { "Content-Type": "application/json" } });
});
