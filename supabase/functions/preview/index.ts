const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

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

  let requestedUrl: unknown;
  try {
    const body = await req.json();
    requestedUrl = body?.url;
  } catch {
    return out({});
  }
  if (typeof requestedUrl !== "string" || requestedUrl.length > 2048) return out({});

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

    const html = (await response.text()).slice(0, 300000);
    const meta = (property: string) => {
      const escaped = property.replace(/[.*+?^{}()|[\]\\]/g, "\\$&");
      const a = html.match(new RegExp(`<meta[^>]+(?:property|name)=["']${escaped}["'][^>]+content=["']([^"']*)["']`, "i"));
      const b = html.match(new RegExp(`<meta[^>]+content=["']([^"']*)["'][^>]+(?:property|name)=["']${escaped}["']`, "i"));
      return (a || b || [])[1] || "";
    };
    const titleTag = html.match(/<title[^>]*>([^<]*)<\\/title>/i);
    const title = meta("og:title") || (titleTag ? titleTag[1] : "");
    const description = meta("og:description") || meta("description");
    let image = meta("og:image");
    if (image) {
      try {
        const imageUrl = new URL(image, current);
        image = ["http:", "https:"].includes(imageUrl.protocol) ? imageUrl.href : "";
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
