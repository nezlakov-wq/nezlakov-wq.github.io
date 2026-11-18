import webpush from "npm:web-push@3.6.7";

const SB = Deno.env.get("SUPABASE_URL")!;
const KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const H = { apikey: KEY, Authorization: `Bearer ${KEY}` };

async function q(path: string) {
  const r = await fetch(`${SB}/rest/v1/${path}`, { headers: H });
  return r.json();
}

const ALLOWED_PUSH_HOSTS = new Set([
  "fcm.googleapis.com",
  "web.push.apple.com",
  "updates.push.services.mozilla.com",
  "push.services.mozilla.com",
]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function safePushEndpoint(value: unknown): string | null {
  if (typeof value !== "string" || value.length > 4096) return null;
  try {
    const u = new URL(value);
    if (u.protocol !== "https:" || u.username || u.password || (u.port && u.port !== "443") || u.hash) return null;
    if (!ALLOWED_PUSH_HOSTS.has(u.hostname.toLowerCase())) return null;
    if (!u.pathname || u.pathname === "/") return null;
    return u.toString();
  } catch {
    return null;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("method", { status: 405 });
  let cfg: Record<string, string>;
  try {
    cfg = Object.fromEntries(
      (await q("push_config?select=key,value")).map((r: any) => [r.key, r.value]),
    );
  } catch {
    return new Response("configuration unavailable", { status: 503 });
  }
  if (!cfg.push_secret || req.headers.get("x-push-secret") !== cfg.push_secret) {
    return new Response("forbidden", { status: 403 });
  }

  let body: { conversation_id?: unknown; sender_id?: unknown };
  try {
    body = await req.json();
  } catch {
    return new Response("bad json", { status: 400 });
  }
  const conversation_id = body?.conversation_id;
  const sender_id = body?.sender_id;
  if (typeof conversation_id !== "string" || !UUID_RE.test(conversation_id)
      || typeof sender_id !== "string" || !UUID_RE.test(sender_id)) {
    return new Response("invalid ids", { status: 400 });
  }
  if (!cfg.vapid_public || !cfg.vapid_private) {
    return new Response("push configuration unavailable", { status: 503 });
  }

  webpush.setVapidDetails("https://nezlakov-wq.github.io", cfg.vapid_public, cfg.vapid_private);

  // Only conversation members with notifications enabled receive a push.
  const members = await q(`conversation_members?select=user_id&conversation_id=eq.${conversation_id}&muted=eq.false`);
  const ids = members.map((m: any) => m.user_id).filter((id: string) => id !== sender_id);
  if (!ids.length) return new Response("ok");

  const [sender] = await q(`profiles?select=display_name&id=eq.${sender_id}`);
  const subs = await q(`push_subscriptions?select=*&user_id=in.(${ids.join(",")})`);
  const payload = JSON.stringify({
    title: "Moonlit",
    body: `${sender?.display_name || "Новое сообщение"}: новое сообщение`,
    tag: conversation_id,
    url: "./",
  });

  await Promise.all(subs.map(async (s: any) => {
    const endpoint = safePushEndpoint(s.endpoint);
    if (!endpoint) return;
    try {
      await webpush.sendNotification(
        { endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
      );
    } catch (e: any) {
      if (e.statusCode === 404 || e.statusCode === 410) {
        await fetch(`${SB}/rest/v1/push_subscriptions?endpoint=eq.${encodeURIComponent(s.endpoint)}`, { method: "DELETE", headers: H });
      }
    }
  }));
  return new Response("ok");
});
