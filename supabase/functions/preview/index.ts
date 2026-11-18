const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function verifiedUserId(req: Request): string | null {
  try {
    const header = req.headers.get("authorization") || "";
    const token = header.replace(/^Bearer\s+/i, "");
    const payload = token.split(".")[1];
    if (!payload) return null;
    const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (c) => c.charCodeAt(0));
    const claims = JSON.parse(new TextDecoder().decode(bytes));
    return typeof claims.sub === "string" && UUID_RE.test(claims.sub) ? claims.sub : null;
  } catch {
    return null;
  }
}

async function readLimitedHtml(response: Response, maxBytes: number): Promise<string | null> {
  if (!response.body) return null;
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => {});
        return null;
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

function out(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), { headers: CORS, status });
}

function isPublicIPv4(ip: string): boolean {
  const parts = ip.split(".").map(Number);
  if (parts.length !== 4 || parts.some((n) => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b, c] = parts;
  if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
  if (a === 100 && b >= 64 && b <= 127) return false;
  if (a === 169 && b === 254) return false;
  if (a === 172 && b >= 16 && b <= 31) return false;
  if (a === 192 && (b === 168 || (b === 0 && c === 0) || (b === 0 && c === 2))) return false;
  if (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) return false;
  if (a === 203 && b === 0 && c === 113) return false;
  if (a === 192 && b === 88 && c === 99) return false;
  if (a === 255) return false;
  return true;
}

function isPublicIPv6(ip: string): boolean {
  const value = ip.toLowerCase().split("%")[0];
  // Only global unicast space is accepted; this rejects loopback, link-local,
  // unique-local, multicast, unspecified, mapped and transition ranges.
  if (!value.startsWith("2") && !value.startsWith("3")) return false;
  if (value.startsWith("2001:db8:")) return false;
  if (value.startsWith("2001:10:")) return false;
  return true;
}

async function validatePublicUrl(value: string): Promise<URL | null> {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return null;
  }

  if (!["http:", "https:"].includes(url.protocol)) return null;
  if (url.username || url.password) return null;
  if (url.port && !["80", "443"].includes(url.port)) return null;

  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (!host || host === "localhost" || host.endsWith(".localhost") ||
      host.endsWith(".local") || host.endsWith(".internal") ||
      host.endsWith(".test") || host.endsWith(".invalid")) return null;

  // Reject IP literals rather than relying on textual hostname checks.
  if (host.includes(":") || /^\d+(?:\.\d+){3}$/.test(host)) return null;

  try {
    const [a, aaaa] = await Promise.all([
      Deno.resolveDns(host, "A").catch(() => [] as string[]),
      Deno.resolveDns(host, "AAAA").catch(() => [] as string[]),
    ]);
    const addresses = [...a, ...aaaa];
    if (addresses.length === 0) return null;
    if (a.some((ip) => !isPublicIPv4(ip))) return null;
    if (aaaa.some((ip) => !isPublicIPv6(ip))) return null;
  } catch {
    return null;
  }

  return url;
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "Method not allowed" }, 405);

  const declaredLength = Number(req.headers.get("content-length") || 0);
  if (declaredLength > 4096) return out({ error: "payload too large" }, 413);
  const userId = verifiedUserId(req);
  if (!userId) return out({ error: "unauthorized" }, 401);

  let rawBody: string;
  try { rawBody = await req.text(); } catch { return out({}); }
  if (rawBody.length > 4096) return out({ error: "payload too large" }, 413);
  let requestedUrl: unknown;
  try {
    const body = JSON.parse(rawBody);
    requestedUrl = body?.url;
  } catch {
    return out({});
  }
  if (typeof requestedUrl !== "string" || requestedUrl.length > 2048) return out({});

  const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
  const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const limitResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/reserve_preview_slot`, {
    method: "POST",
    headers: {
      apikey: SERVICE_KEY,
      authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ p_user_id: userId }),
  });
  if (!limitResponse.ok) return out({ error: "rate limit unavailable" }, 503);
  if (await limitResponse.json() !== true) return out({ error: "rate limited" }, 429);

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 5000);

  try {
    let current = await validatePublicUrl(requestedUrl);
    if (!current) return out({});

    let response: Response | null = null;
    // Follow redirects manually so every destination is revalidated.
    for (let hop = 0; hop <= 3; hop++) {
      response = await fetch(current, {
        signal: controller.signal,
        redirect: "manual",
        headers: { "User-Agent": "Mozilla/5.0 (compatible; MoonlitPreview/1.0)" },
      });

      if (![301, 302, 303, 307, 308].includes(response.status)) break;
      const location = response.headers.get("location");
      if (!location || hop === 3) return out({ site: current.hostname });
      const next = new URL(location, current).href;
      const validated = await validatePublicUrl(next);
      if (!validated) return out({ site: current.hostname });
      current = validated;
    }

    if (!response) return out({});
    const site = current.hostname;
    const contentType = response.headers.get("content-type") || "";
    if (!contentType.toLowerCase().includes("text/html")) return out({ site });

    const declaredHtmlLength = Number(response.headers.get("content-length") || 0);
    if (declaredHtmlLength > 300000) return out({ site });
    const html = await readLimitedHtml(response, 300000);
    if (html === null) return out({ site });
    const meta = (property: string) => {
      const escaped = property.replace(/[.*+?^{}()|[\]\\]/g, "\\$&");
      const a = html.match(new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]+content=["']([^"']*)["']`, "i"));
      const b = html.match(new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']${escaped}["']`, "i"));
      return (a || b || [])[1] || "";
    };
    const titleTag = html.match(/<title[^>]*>([^<]*)<\/title>/i);
    const title = meta("og:title") || (titleTag ? titleTag[1] : "");
    const description = meta("og:description") || meta("description");
    let image = meta("og:image");
    if (image) {
      try {
        const imageUrl = new URL(image, current);
        const validatedImage = await validatePublicUrl(imageUrl.href);
        image = validatedImage ? validatedImage.href : "";
      } catch {
        image = "";
      }
    }
    return out({
      title: title.trim().slice(0, 200),
      description: description.trim().slice(0, 300),
      image,
      site,
    });
  } catch {
    return out({});
  } finally {
    clearTimeout(timer);
  }
});
