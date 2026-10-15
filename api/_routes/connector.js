// /api/connector — keeps Shopify and WooCommerce stock in step with Orzio, and holds their keys on the server.
//   POST {action:'save', org, store, platform, url, token|key+secret, location, webhook_secret}   owner or team
//   POST {action:'status'|'test'|'push', org, store, skus?}                                         owner or team
const crypto = require('crypto');
const { admin, verify, UUID } = require('../_auth');
const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
const SHOPIFY_V = '2024-07';
const shopBase = (u) => { const h = String(u || '').replace(/^https?:\/\//, '').replace(/\/.*$/, ''); if (!/^[a-z0-9-]+\.myshopify\.com$/i.test(h)) throw Object.assign(new Error('Use the shop’s myshopify.com address, for example yourshop.myshopify.com.'), { status: 400 }); return 'https://' + h; };
const wooBase = (u) => { const x = new URL(String(u || '')); if (x.protocol !== 'https:' && x.hostname !== 'localhost') throw Object.assign(new Error('Use the website’s https:// address.'), { status: 400 }); return x.origin + x.pathname.replace(/\/$/, ''); };
async function shopifyGql(c, query, variables) {
  const r = await fetch(shopBase(c.url) + `/admin/api/${SHOPIFY_V}/graphql.json`, { method: 'POST', headers: { 'content-type': 'application/json', 'x-shopify-access-token': c.token }, body: JSON.stringify({ query, variables }) });
  const j = await r.json().catch(() => ({})); if (!r.ok || j.errors) throw Object.assign(new Error('Shopify refused the request. Check the access token and its inventory permissions.'), { status: 502 }); return j.data;
}
async function woo(c, method, path, body) {
  const auth = 'Basic ' + Buffer.from(c.key + ':' + c.secret).toString('base64');
  const r = await fetch(wooBase(c.url) + '/wp-json/wc/v3' + path, { method, headers: { 'content-type': 'application/json', authorization: auth }, body: body ? JSON.stringify(body) : undefined });
  const j = await r.json().catch(() => ({})); if (!r.ok) throw Object.assign(new Error('WooCommerce refused the request. Check the website address and the API keys (read/write).'), { status: 502 }); return j;
}
async function pushOne(c, sku, qty) {
  if (c.platform === 'shopify') {
    const d = await shopifyGql(c, 'query($q:String!){productVariants(first:1,query:$q){edges{node{id inventoryItem{id}}}}}', { q: 'sku:' + sku });
    const e = d && d.productVariants && d.productVariants.edges[0]; if (!e) return 'not found';
    await shopifyGql(c, 'mutation($i:InventorySetQuantitiesInput!){inventorySetQuantities(input:$i){userErrors{message}}}', { i: { name: 'available', reason: 'correction', ignoreCompareQuantity: true, quantities: [{ inventoryItemId: e.node.inventoryItem.id, locationId: c.location, quantity: qty }] } });
    return 'updated';
  }
  const found = await woo(c, 'GET', '/products?sku=' + encodeURIComponent(sku)); const p = Array.isArray(found) && found[0]; if (!p) return 'not found';
  await woo(c, 'PUT', '/products/' + p.id, { manage_stock: true, stock_quantity: qty }); return 'updated';
}
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
  try {
    let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
    const { user } = await verify(bearer(req)); const sb = admin();
    const org = String(b.org || ''), store = String(b.store || '');
    if (!UUID.test(org) || !/^[A-Za-z0-9_-]{3,80}$/.test(store)) return res.status(400).json({ error: 'Choose the shop.' });
    const { data: mem } = await sb.from('members').select('role,status,entities').eq('org_id', org).eq('user_id', user.id).maybeSingle();
    if (!mem || mem.status !== 'active' || !['owner', 'staff'].includes(mem.role)) return res.status(403).json({ error: 'Only the team can manage shop connections.' });
    const { data: sd } = await sb.from('docs').select('data').eq('org_id', org).eq('path', 'stores/' + store).maybeSingle();
    if (!sd) return res.status(404).json({ error: 'Shop not found.' });
    if (mem.entities && !mem.entities.includes(sd.data.entity || 'main')) return res.status(403).json({ error: 'You do not have access to this company.' });
    const { data: secRow } = await sb.from('store_secrets').select('data').eq('store_id', store).eq('org_id', org).maybeSingle();
    const sec = (secRow && secRow.data) || {};
    if (b.action === 'save') {
      const p = String(b.platform || ''); if (!['shopify', 'woo', 'none'].includes(p)) return res.status(400).json({ error: 'Choose Shopify or WooCommerce.' });
      const next = { ...sec, platform: p, url: String(b.url || sec.url || '').trim(), location: String(b.location || sec.location || '').trim(), webhook_secret: sec.webhook_secret || crypto.randomBytes(24).toString('hex') };
      if (b.token) next.token = String(b.token).trim(); if (b.key) next.key = String(b.key).trim(); if (b.secret) next.secret = String(b.secret).trim();
      if (b.webhook_secret) next.webhook_secret = String(b.webhook_secret).trim();
      if (p === 'shopify') shopBase(next.url); if (p === 'woo') wooBase(next.url);
      await sb.from('store_secrets').upsert({ store_id: store, org_id: org, data: next, updated_at: new Date().toISOString() });
      return res.status(200).json({ ok: true, platform: p, url: next.url, webhook_secret: next.webhook_secret, has_keys: p === 'shopify' ? !!next.token : !!(next.key && next.secret) });
    }
    if (b.action === 'status') return res.status(200).json({ platform: sec.platform || 'none', url: sec.url || '', location: sec.location || '', webhook_secret: sec.webhook_secret || '', has_keys: sec.platform === 'shopify' ? !!sec.token : !!(sec.key && sec.secret), last_push: sec.last_push || null });
    if (!sec.platform || sec.platform === 'none') return res.status(400).json({ error: 'Connect Shopify or WooCommerce first.' });
    const c = sec;
    if (b.action === 'test') { if (c.platform === 'shopify') await shopifyGql(c, '{shop{name}}'); else await woo(c, 'GET', '/system_status'); return res.status(200).json({ ok: true }); }
    if (b.action === 'push') {
      const { data: cat } = await sb.rpc('store_catalog', { p_key: sd.data.key }); const want = Array.isArray(b.skus) && b.skus.length ? new Set(b.skus.map(String)) : null;
      const items = ((cat && cat.items) || []).filter((i) => i.sku && (!want || want.has(i.sku))).slice(0, 200); const out = [];
      for (const i of items) { try { out.push({ sku: i.sku, qty: i.available, result: await pushOne(c, i.sku, i.available) }); } catch (e) { out.push({ sku: i.sku, qty: i.available, result: 'error', why: e.message }); } }
      await sb.from('store_secrets').update({ data: { ...sec, last_push: { at: new Date().toISOString(), by: user.id, count: out.filter((x) => x.result === 'updated').length } } }).eq('store_id', store).eq('org_id', org);
      return res.status(200).json({ ok: true, results: out });
    }
    return res.status(400).json({ error: 'Unknown action.' });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
