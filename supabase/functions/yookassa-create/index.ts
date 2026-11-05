// Создание платежа ЮKassa. Вызывается из приложения с токеном пользователя.
// Секреты: YOOKASSA_SHOP_ID, YOOKASSA_SECRET_KEY, APP_URL (https://moonlit.us.ci).
// SUPABASE_URL и SUPABASE_SERVICE_ROLE_KEY Supabase подставляет сам.

// Цены и состав товаров. Источник истины на сервере: клиенту цену не доверяем.
// Суммы совпадают с магазином в index.html (openShop).
const PRODUCTS: Record<string, { amount: string; description: string; plusDays?: number; tokens?: number }> = {
  plus_month:   { amount: '199.00', description: 'Moonlit Plus, 1 месяц',  plusDays: 30 },
  plus_3m:      { amount: '537.00', description: 'Moonlit Plus, 3 месяца', plusDays: 90 },
  plus_12m:     { amount: '1910.00', description: 'Moonlit Plus, 12 месяцев', plusDays: 365 },
  tokens_100:   { amount: '50.00',  description: '100 токенов Moonlit',   tokens: 100 },
  tokens_500:   { amount: '200.00', description: '500 токенов Moonlit',   tokens: 500 },
  tokens_1000:  { amount: '350.00', description: '1000 токенов Moonlit',  tokens: 1000 },
};

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'method' }, 405);

  const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
  const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const SHOP_ID = Deno.env.get('YOOKASSA_SHOP_ID')!;
  const SECRET = Deno.env.get('YOOKASSA_SECRET_KEY')!;
  const APP_URL = Deno.env.get('APP_URL') || 'https://moonlit.us.ci';

  // 1. Кто платит: проверяем токен пользователя
  const authHeader = req.headers.get('authorization') || '';
  if (!authHeader.startsWith('Bearer ')) return json({ error: 'unauthorized' }, 401);
  const userRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
    headers: { apikey: SERVICE_KEY, authorization: authHeader },
  });
  if (!userRes.ok) return json({ error: 'unauthorized' }, 401);
  const user = await userRes.json();
  if (!user?.id) return json({ error: 'unauthorized' }, 401);

  // 2. Какой товар
  let body: { product?: string };
  try { body = await req.json(); } catch { return json({ error: 'bad json' }, 400); }
  const product = PRODUCTS[body.product || ''];
  if (!product) return json({ error: 'unknown product' }, 400);

  // 3. Создаём платёж в ЮKassa. Idempotence-Key защищает от двойного списания при повторе запроса.
  const idem = crypto.randomUUID();
  const payRes = await fetch('https://api.yookassa.ru/v3/payments', {
    method: 'POST',
    headers: {
      authorization: 'Basic ' + btoa(`${SHOP_ID}:${SECRET}`),
      'Idempotence-Key': idem,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      amount: { value: product.amount, currency: 'RUB' },
      capture: true,
      confirmation: { type: 'redirect', return_url: `${APP_URL}/?payment=done` },
      description: product.description,
      metadata: { user_id: user.id, product: body.product },
    }),
  });
  const pay = await payRes.json();
  if (!payRes.ok || !pay?.id || !pay?.confirmation?.confirmation_url) {
    console.error('yookassa create failed', payRes.status, JSON.stringify(pay));
    return json({ error: 'payment provider error' }, 502);
  }

  // 4. Запоминаем платёж как ожидающий оплаты
  const ins = await fetch(`${SUPABASE_URL}/rest/v1/payments`, {
    method: 'POST',
    headers: { apikey: SERVICE_KEY, authorization: `Bearer ${SERVICE_KEY}`, 'Content-Type': 'application/json', Prefer: 'return=minimal' },
    body: JSON.stringify({ id: pay.id, user_id: user.id, product: body.product, amount: product.amount, status: 'pending' }),
  });
  if (!ins.ok) {
    console.error('payments insert failed', ins.status, await ins.text());
    return json({ error: 'db error' }, 500);
  }

  return json({ confirmation_url: pay.confirmation.confirmation_url, payment_id: pay.id });
});
