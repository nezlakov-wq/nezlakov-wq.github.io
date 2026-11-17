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
  if (!product || !meta.user_id || pay.amount?.currency !== 'RUB'
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

  let note: { event?: string; object?: { id?: string } };
  try { note = await req.json(); } catch { return json({ error: 'bad json' }, 400); }
  const event = note.event;
  const objectId = note.object?.id;
  if (!objectId || (event !== 'payment.succeeded' && event !== 'refund.succeeded')) {
    return json({ ok: true, skipped: true });
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
