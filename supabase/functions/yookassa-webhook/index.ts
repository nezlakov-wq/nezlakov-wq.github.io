// YooKassa webhook. Provider state is verified server-to-server; settlement and
// entitlement changes are serialized atomically inside Postgres.
const PRODUCTS: Record<string, { amount: string }> = {
  plus_month: { amount: '199.00' },
  plus_3m: { amount: '537.00' },
  plus_12m: { amount: '1910.00' },
  tokens_50: { amount: '25.00' },
  tokens_100: { amount: '50.00' },
  tokens_200: { amount: '90.00' },
  tokens_500: { amount: '200.00' },
  tokens_1000: { amount: '350.00' },
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

async function hashClientIp(req: Request): Promise<string> {
  const ip = req.headers.get('cf-connecting-ip')?.trim()
    || req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    || 'unknown';
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(ip));
  return Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

async function settle(
  event: 'succeeded' | 'refunded',
  paymentId: string,
  pay: any,
  SUPABASE_URL: string,
  dbHeaders: Record<string, string>,
): Promise<Response> {
  const meta = pay.metadata || {};
  const product = PRODUCTS[meta.product];
  if (!product || typeof meta.user_id !== 'string' || !UUID_RE.test(meta.user_id) || pay.amount?.currency !== 'RUB'
      || pay.amount?.value !== product.amount) {
    console.error('provider payment metadata/amount mismatch', paymentId);
    return json({ ok: true, skipped: true });
  }

  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/settle_yookassa_payment`, {
    method: 'POST',
    headers: dbHeaders,
    body: JSON.stringify({
      p_payment_id: paymentId,
      p_user_id: meta.user_id,
      p_product: meta.product,
      p_amount: product.amount,
      p_event: event,
    }),
  });
  if (!response.ok) {
    console.error('atomic payment settlement failed', response.status, await response.text());
    return json({ error: 'settlement failed' }, 500);
  }
  return json({ ok: true, result: await response.json() });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method' }, 405);

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const SHOP_ID = Deno.env.get('YOOKASSA_SHOP_ID')!;
  const SECRET = Deno.env.get('YOOKASSA_SECRET_KEY')!;
  const dbHeaders = {
    apikey: SERVICE_KEY,
    authorization: `Bearer ${SERVICE_KEY}`,
    'Content-Type': 'application/json',
  };
  const providerAuth = { authorization: 'Basic ' + btoa(`${SHOP_ID}:${SECRET}`) };

  const declaredLength = Number(req.headers.get('content-length') || 0);
  if (declaredLength > 8192) return json({ error: 'payload too large' }, 413);
  let rawBody: string;
  try { rawBody = await req.text(); } catch { return json({ error: 'bad body' }, 400); }
  if (rawBody.length > 8192) return json({ error: 'payload too large' }, 413);

  let note: { event?: string; object?: { id?: string } };
  try { note = JSON.parse(rawBody); } catch { return json({ error: 'bad json' }, 400); }
  const event = note.event;
  const objectId = note.object?.id;
  if (event !== 'payment.succeeded' && event !== 'refund.succeeded') {
    return json({ ok: true, skipped: true });
  }
  if (typeof objectId !== 'string' || !UUID_RE.test(objectId)) {
    return json({ error: 'invalid provider object id' }, 400);
  }

  // The endpoint is public for provider callbacks. Rate-limit by a hashed client IP
  // before making authenticated requests to YooKassa.
  const ipHash = await hashClientIp(req);
  const limitResponse = await fetch(`${SUPABASE_URL}/rest/v1/rpc/reserve_yookassa_webhook_slot`, {
    method: 'POST',
    headers: dbHeaders,
    body: JSON.stringify({ p_ip_hash: ipHash }),
  });
  if (!limitResponse.ok) {
    console.error('webhook rate limit check failed', limitResponse.status);
    return json({ error: 'rate limit unavailable' }, 503);
  }
  if (await limitResponse.json() !== true) {
    return json({ error: 'too many webhook requests' }, 429);
  }

  if (event === 'payment.succeeded') {
    const check = await fetch(
      `https://api.yookassa.ru/v3/payments/${encodeURIComponent(objectId)}`,
      { headers: providerAuth },
    );
    if (!check.ok) return json({ error: 'provider check failed' }, 502);
    const pay = await check.json();
    if (pay.status !== 'succeeded' || pay.paid !== true) {
      return json({ ok: true, skipped: true });
    }
    return await settle('succeeded', objectId, pay, SUPABASE_URL, dbHeaders);
  }

  const refundResponse = await fetch(
    `https://api.yookassa.ru/v3/refunds/${encodeURIComponent(objectId)}`,
    { headers: providerAuth },
  );
  if (!refundResponse.ok) return json({ error: 'refund provider check failed' }, 502);
  const refund = await refundResponse.json();
  if (refund.status !== 'succeeded' || !refund.payment_id) {
    return json({ ok: true, skipped: true });
  }

  const paymentResponse = await fetch(
    `https://api.yookassa.ru/v3/payments/${encodeURIComponent(refund.payment_id)}`,
    { headers: providerAuth },
  );
  if (!paymentResponse.ok) return json({ error: 'payment provider check failed' }, 502);
  const pay = await paymentResponse.json();
  const meta = pay.metadata || {};
  const product = PRODUCTS[meta.product];
  if (!product || !meta.user_id || pay.amount?.currency !== 'RUB'
      || pay.amount?.value !== product.amount
      || refund.amount?.currency !== 'RUB'
      || refund.amount?.value !== product.amount) {
    console.error('partial or mismatched refund requires manual review', objectId, refund.payment_id);
    return json({ ok: true, skipped: true });
  }

  return await settle('refunded', refund.payment_id, pay, SUPABASE_URL, dbHeaders);
});
