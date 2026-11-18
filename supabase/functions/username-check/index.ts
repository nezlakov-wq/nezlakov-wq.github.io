const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const json = (value: unknown, status = 200) =>
  new Response(JSON.stringify(value), {
    status,
    headers: { ...CORS, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

async function hashIp(req: Request): Promise<string> {
  const forwarded = req.headers.get("x-forwarded-for");
  const ip = req.headers.get("cf-connecting-ip")?.trim()
    || forwarded?.split(",").map((v) => v.trim()).filter(Boolean).at(-1)
    || "unknown";
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(ip));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "method not allowed" }, 405);
  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) return json({ error: "service unavailable" }, 503);

  const declaredLength = Number(req.headers.get("content-length") || 0);
  if (declaredLength > 1024) return json({ error: "payload too large" }, 413);
  let raw: string;
  try { raw = await req.text(); } catch { return json({ error: "bad body" }, 400); }
  if (raw.length > 1024) return json({ error: "payload too large" }, 413);

  let body: { username?: unknown };
  try { body = JSON.parse(raw); } catch { return json({ error: "bad json" }, 400); }
  if (typeof body?.username !== "string") return json({ error: "invalid username" }, 400);
  const username = body.username.trim().toLowerCase();
  if (!/^[a-z0-9_]{3,20}$/.test(username)) return json({ error: "invalid username" }, 400);

  const headers = {
    apikey: SERVICE_ROLE_KEY,
    authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    "Content-Type": "application/json",
  };
  const limiter = await fetch(`${SUPABASE_URL}/rest/v1/rpc/reserve_username_check_slot`, {
    method: "POST",
    headers,
    body: JSON.stringify({ p_ip_hash: await hashIp(req) }),
  });
  if (!limiter.ok) return json({ error: "rate limit unavailable" }, 503);
  if (await limiter.json() !== true) return json({ error: "too many requests" }, 429);

  const lookup = await fetch(`${SUPABASE_URL}/rest/v1/rpc/username_is_taken`, {
    method: "POST",
    headers,
    body: JSON.stringify({ requested_username: username }),
  });
  if (!lookup.ok) return json({ error: "username lookup unavailable" }, 503);
  const taken = await lookup.json();
  if (typeof taken !== "boolean") return json({ error: "invalid lookup response" }, 503);
  return json(taken);
});
