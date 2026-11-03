// Поиск треков Spotify для плеера в Moonlit.
// Ключи приложения Spotify хранятся в секретах Supabase: SPOTIFY_CLIENT_ID и SPOTIFY_CLIENT_SECRET.
let cached: { token: string; exp: number } | null = null;

async function getToken(): Promise<string> {
  if (cached && cached.exp > Date.now() + 60_000) return cached.token;
  const id = Deno.env.get('SPOTIFY_CLIENT_ID');
  const secret = Deno.env.get('SPOTIFY_CLIENT_SECRET');
  if (!id || !secret) throw new Error('spotify keys not set');
  const r = await fetch('https://accounts.spotify.com/api/token', {
    method: 'POST',
    headers: {
      Authorization: 'Basic ' + btoa(id + ':' + secret),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials',
  });
  const j = await r.json();
  if (!r.ok) throw new Error('spotify token ' + r.status);
  cached = { token: j.access_token, exp: Date.now() + j.expires_in * 1000 };
  return cached.token;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

Deno.serve(async (req) => {
  try {
    const { q } = await req.json();
    const query = String(q ?? '').trim().slice(0, 100);
    if (!query) return json({ items: [] });
    const token = await getToken();
    const r = await fetch(
      'https://api.spotify.com/v1/search?type=track&limit=10&q=' + encodeURIComponent(query),
      { headers: { Authorization: 'Bearer ' + token } },
    );
    if (!r.ok) return json({ error: 'spotify ' + r.status }, 502);
    const j = await r.json();
    const items = (j.tracks?.items ?? []).map((t: any) => ({
      id: t.id,
      name: t.name,
      artist: (t.artists ?? []).map((a: any) => a.name).join(', '),
      image: t.album?.images?.[2]?.url ?? t.album?.images?.[0]?.url ?? null,
    }));
    return json({ items });
  } catch (e) {
    return json({ error: String((e as Error).message ?? e) }, 500);
  }
});
