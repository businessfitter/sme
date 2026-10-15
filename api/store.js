// /api/store — the bridge between a business's website(s) and Orzio.
//   GET  ?k=<store key>                  public: products with live available stock (CORS open, any website)
//   GET  ?k=<store key>&track=WEB-2026-00001&phone=1234   public: order status for the customer
//   POST ?k=<store key>                  public: place an order from the website (stock is reserved at once)
//   POST ?k=<store key>&src=shopify      Shopify "orders/create" webhook (signed with the store's webhook secret)
//   POST ?k=<store key>&src=woo          WooCommerce "order.created" webhook (signed with the store's webhook secret)
const crypto = require('crypto');
const { admin } = require('./_auth');
const KEY = /^[A-Za-z0-9_-]{24,128}$/;
async function rawBody(req) {
  if (typeof req.rawBody === 'string') return req.rawBody;
  if (typeof req.body === 'string') return req.body;
  if (Buffer.isBuffer(req.body)) return req.body.toString('utf8');
  if (req.body && typeof req.body === 'object') return JSON.stringify(req.body);
  const chunks = []; for await (const c of req) chunks.push(c); return Buffer.concat(chunks).toString('utf8');
}
const safeEq = (a, b) => { const x = Buffer.from(String(a || '')), y = Buffer.from(String(b || '')); return x.length === y.length && crypto.timingSafeEqual(x, y); };
const sign = (secret, raw) => crypto.createHmac('sha256', secret).update(raw, 'utf8').digest('base64');
// map a Shopify or WooCommerce order onto Orzio's order shape (lines matched by SKU)
function fromShopify(o) {
  const a = o.shipping_address || o.billing_address || {};
  return { ext: String(o.id || ''), order: { customer: { name: [a.first_name, a.last_name].filter(Boolean).join(' ') || (o.customer && [o.customer.first_name, o.customer.last_name].join(' ')) || '', phone: a.phone || o.phone || '', email: o.email || '', address: [a.address1, a.address2].filter(Boolean).join(', '), city: a.city || '', country: a.country_code || '' },
    lines: (o.line_items || []).map((l) => ({ sku: l.sku || '', name: l.title || l.name, qty: +l.quantity || 0, price: +l.price || 0 })), shipping: (o.shipping_lines || []).reduce((s, x) => s + (+x.price || 0), 0),
    payment: o.financial_status === 'paid' ? 'paid' : 'cod', note: o.note || '' } };
}
function fromWoo(o) {
  const a = o.shipping && o.shipping.address_1 ? o.shipping : (o.billing || {});
  return { ext: String(o.id || ''), order: { customer: { name: [a.first_name, a.last_name].filter(Boolean).join(' '), phone: (o.billing && o.billing.phone) || a.phone || '', email: (o.billing && o.billing.email) || '', address: [a.address_1, a.address_2].filter(Boolean).join(', '), city: a.city || '', country: a.country || '' },
    lines: (o.line_items || []).map((l) => ({ sku: l.sku || '', name: l.name, qty: +l.quantity || 0, price: +l.price || (+l.total / (+l.quantity || 1)) || 0 })), shipping: +o.shipping_total || 0,
    payment: o.date_paid || o.status === 'processing' || o.status === 'completed' ? 'paid' : 'cod', note: o.customer_note || '' } };
}
module.exports = async (req, res) => {
  res.setHeader('Access-Control-Allow-Origin', '*'); res.setHeader('Access-Control-Allow-Headers', 'content-type'); res.setHeader('Access-Control-Allow-Methods', 'GET,POST,OPTIONS');
  res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Robots-Tag', 'noindex');
  if (req.method === 'OPTIONS') return res.status(204).end();
  const q = req.query || {}; const k = String(q.k || '');
  if (!KEY.test(k)) return res.status(400).json({ error: 'This shop link is not valid.' });
  try {
    const sb = admin();
    if (req.method === 'GET' && q.track) {
      const { data } = await sb.rpc('store_track', { p_key: k, p_number: String(q.track).slice(0, 40), p_phone4: String(q.phone || '').slice(0, 20) });
      return data ? res.status(200).json(data) : res.status(404).json({ error: 'No order found with that number and phone.' });
    }
    if (req.method === 'GET') {
      const { data, error } = await sb.rpc('store_catalog', { p_key: k });
      if (error || !data) return res.status(404).json({ error: 'This shop is not available.' });
      return res.status(200).json(data);
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
    const raw = await rawBody(req); if (raw.length > 200000) return res.status(413).json({ error: 'Too large.' });
    let body = {}; try { body = JSON.parse(raw || '{}'); } catch (e) { return res.status(400).json({ error: 'Bad request.' }); }
    const src = String(q.src || '');
    if (src === 'shopify' || src === 'woo') {
      const { data: f } = await sb.rpc('store_find', { p_key: k }); const st = Array.isArray(f) ? f[0] : f;
      if (!st) return res.status(404).json({ error: 'Unknown shop.' });
      const { data: sec } = await sb.from('store_secrets').select('data').eq('store_id', st.store_id).eq('org_id', st.org_id).maybeSingle();
      const secret = sec && sec.data && sec.data.webhook_secret;
      const sig = src === 'shopify' ? req.headers['x-shopify-hmac-sha256'] : req.headers['x-wc-webhook-signature'];
      if (!secret || !safeEq(sig, sign(secret, raw))) return res.status(401).json({ error: 'Signature does not match.' });
      if (src === 'woo' && !body.id) return res.status(200).json({ ok: true, ping: true }); // WooCommerce sends a ping when the webhook is created
      const m = src === 'shopify' ? fromShopify(body) : fromWoo(body);
      const { data, error } = await sb.rpc('store_place_order', { p_key: k, p_order: m.order, p_source: src, p_ext_id: m.ext });
      if (error) return res.status(400).json({ error: 'The order could not be recorded.' });
      return res.status(200).json(data);
    }
    const order = { customer: body.customer || {}, lines: Array.isArray(body.lines) ? body.lines.slice(0, 50).map((l) => ({ id: String(l.id || '').slice(0, 80), qty: +l.qty || 0 })) : [], payment: String(body.payment || 'cod'), note: String(body.note || '').slice(0, 500) };
    const { data, error } = await sb.rpc('store_place_order', { p_key: k, p_order: order, p_source: 'web', p_ext_id: null });
    if (error) return res.status(400).json({ error: 'Your order could not be placed.' });
    if (!data.ok) return res.status(409).json({ error: data.why, item: data.item || null });
    return res.status(200).json(data);
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
