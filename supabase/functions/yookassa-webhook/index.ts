// Webhook ЮKassa: payment.succeeded → начисление Plus или токенов.
// Развернуть с verify_jwt = false (ЮKassa не присылает токен Supabase).
// Секреты: YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY.
//
// Не доверяем телу запроса: статус и сумму перепроверяем запросом к API ЮKassa.
// Повторные уведомления безопасны: выдача идёт только при первой записи платежа.

const PRODUCTS: Record<string, { amount: string; plusDays?: number; tokens?: number }> = {
  plus_month:  { amount: '199.00', plusDays: 30 },
  plus_3m:     { amount: '537.00', plusDays: 90 },
  plus_12m:    { amount: '1910.00', plusDays: 365 },
  tokens_50:   { amount: '25.00',  tokens: 50 },
  tokens_100:  { amount: '50.00',  tokens: 100 },
  tokens_200:  { amount: '90.00',  tokens: 200 },
  tokens_500:  { amount: '200.00', tokens: 500 },
  tokens_1000: { amount: '350.00', tokens: 1000 },
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

// Возврат: проверяем у ЮKassa, что возврат полный и успешный, отмечаем платёж и откатываем выдачу.
// Баланс не уходит ниже нуля; недостача пишется в лог (console.error) и видна в token_ledger.
async function handleRefund(
  refundId: string, SHOP_ID: string, SECRET: string, SUPABASE_URL: string,
  dbHeaders: Record<string, string>,
): Promise<Response> {
  const auth = { authorization: 'Basic ' + btoa(`${SHOP_ID}:${SECRET}`) };
  const rr = await fetch(`https://api.yookassa.ru/v3/refunds/${encodeURIComponent(refundId)}`, { headers: auth });
  if (!rr.ok) return json({ error: 'provider check failed' }, 502);
  const refund = await rr.json();
  if (refund.status !== 'succeeded' || !refund.payment_id) return json({ ok: true, skipped: true });

  const pr = await fetch(`https://api.yookassa.ru/v3/payments/${encodeURIComponent(refund.payment_id)}`, { headers: auth });
  if (!pr.ok) return json({ error: 'provider check failed' }, 502);
  const pay = await pr.json();
  const meta = pay.metadata || {};
  const product = PRODUCTS[meta.product];
  if (!product || !meta.user_id) return json({ ok: true, skipped: true });

  // Частичный возврат не откатываем автоматически: решаем вручную
  if (refund.amount?.value !== pay.amount?.value || refund.amount?.currency !== 'RUB') {
    console.error('partial refund, manual review', refund.payment_id, refund.amount?.value, pay.amount?.value);
    return json({ ok: true, skipped: true });
  }

  // Идемпотентность: отмечаем платёж как возвращённый только один раз
  const claim = await fetch(`${SUPABASE_URL}/rest/v1/payments?id=eq.${encodeURIComponent(refund.payment_id)}&status=eq.succeeded`, {
    method: 'PATCH', headers: { ...dbHeaders, Prefer: 'return=representation' },
    body: JSON.stringify({ status: 'refunded' }),
  });
  if (!claim.ok) return json({ error: 'db error' }, 500);
  const claimed = await claim.json();
  if (Array.isArray(claimed) && claimed.length === 0) return json({ ok: true, duplicate: true });

  const revert = () => fetch(`${SUPABASE_URL}/rest/v1/payments?id=eq.${encodeURIComponent(refund.payment_id)}`, {
    method: 'PATCH', headers: { ...dbHeaders, Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'succeeded' }),
  });

  // Токены, которые выдавались за покупку: у Plus это 50 бонусных
  const tokens = product.tokens ?? (product.plusDays ? 50 : 0);
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/revoke_purchase`, {
    method: 'POST', headers: dbHeaders,
    body: JSON.stringify({ uid: meta.user_id, days: product.plusDays ?? 0, tokens }),
  });
  if (!r.ok) { console.error('revoke failed', await r.text()); await revert(); return json({ error: 'revoke failed' }, 500); }
  const shortfall = Number(await r.json());
  if (shortfall > 0) console.error('refund shortfall', refund.payment_id, meta.user_id, shortfall);
  return json({ ok: true, shortfall });
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'method' }, 405);

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const SHOP_ID = Deno.env.get('YOOKASSA_SHOP_ID')!;
  const SECRET = Deno.env.get('YOOKASSA_SECRET_KEY')!;
  const dbHeaders = { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json' };

  let note: { event?: string; object?: { id?: string } };
  try { note = await req.json(); } catch { return json({ error: 'bad json' }, 400); }
  if (note.event === 'refund.succeeded' && note.object?.id) {
    return await handleRefund(note.object.id, SHOP_ID, SECRET, SUPABASE_URL, dbHeaders);
  }
  if (note.event !== 'payment.succeeded' || !note.object?.id) return json({ ok: true, skipped: true });

  // 1. Перепроверяем платёж у ЮKassa, а не верим уведомлению
  const paymentId = note.object.id;
  const check = await fetch(`https://api.yookassa.ru/v3/payments/${encodeURIComponent(paymentId)}`, {
    headers: { authorization: 'Basic ' + btoa(`${SHOP_ID}:${SECRET}`) },
  });
  if (!check.ok) return json({ error: 'provider check failed' }, 502);
  const pay = await check.json();

  const meta = pay.metadata || {};
  const product = PRODUCTS[meta.product];
  const paid = pay.status === 'succeeded' && pay.paid === true
    && pay.amount?.currency === 'RUB' && pay.amount?.value === product?.amount;
  if (!product || !meta.user_id || !paid) {
    console.error('payment not valid', paymentId, pay.status, pay.amount?.value, meta.product);
    return json({ ok: true, skipped: true });
  }

  // 2. Атомарно переводим платёж в «succeeded». Выдача только если строка реально изменилась:
  //    повторное уведомление или параллельный запрос не выдадут второй раз.
  const claim = await fetch(`${SUPABASE_URL}/rest/v1/payments?id=eq.${encodeURIComponent(paymentId)}&status=neq.succeeded`, {
    method: 'PATCH',
    headers: { ...dbHeaders, Prefer: 'return=representation' },
    body: JSON.stringify({ status: 'succeeded', paid_at: new Date().toISOString() }),
  });
  if (!claim.ok) return json({ error: 'db error' }, 500);
  const claimed = await claim.json();
  if (Array.isArray(claimed) && claimed.length === 0) {
    // Либо уже выдано, либо строки нет (create её не записал): проверяем
    const exists = await fetch(`${SUPABASE_URL}/rest/v1/payments?id=eq.${encodeURIComponent(paymentId)}&select=id`, { headers: dbHeaders });
    const rows = exists.ok ? await exists.json() : [];
    if (rows.length > 0) return json({ ok: true, duplicate: true });
    const ins = await fetch(`${SUPABASE_URL}/rest/v1/payments`, {
      method: 'POST',
      headers: { ...dbHeaders, Prefer: 'resolution=ignore-duplicates,return=representation' },
      body: JSON.stringify({ id: paymentId, user_id: meta.user_id, product: meta.product, amount: product.amount, status: 'succeeded', paid_at: new Date().toISOString() }),
    });
    if (!ins.ok) return json({ error: 'db error' }, 500);
    const inserted = await ins.json();
    if (!Array.isArray(inserted) || inserted.length === 0) return json({ ok: true, duplicate: true });
  }

  // Если выдача не удалась, возвращаем статус в pending: тогда повтор уведомления выдаст товар
  const revert = () => fetch(`${SUPABASE_URL}/rest/v1/payments?id=eq.${encodeURIComponent(paymentId)}`, {
    method: 'PATCH', headers: { ...dbHeaders, Prefer: 'return=minimal' }, body: JSON.stringify({ status: 'pending', paid_at: null }),
  });

  // 3. Выдача.
  if (product.plusDays) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/grant_plus`, {
      method: 'POST', headers: dbHeaders, body: JSON.stringify({ uid: meta.user_id, days: product.plusDays }),
    });
    if (!r.ok) { console.error('grant_plus failed', await r.text()); await revert(); return json({ error: 'grant failed' }, 500); }
  }
  if (product.tokens) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/grant_tokens`, {
      method: 'POST', headers: dbHeaders, body: JSON.stringify({ uid: meta.user_id, amount: product.tokens }),
    });
    if (!r.ok) { console.error('grant_tokens failed', await r.text()); await revert(); return json({ error: 'grant failed' }, 500); }
  }

  return json({ ok: true });
});
