// /api/domain — custom domains for a workspace.
//   GET  ?host=<domain>                        public: which workspace a verified domain opens (name and logo only)
//   POST {action:list|add|check|remove, org, domain}   owners only: manage the workspace's own domain on Vercel
// Needs VERCEL_TOKEN and VERCEL_PROJECT_ID (and VERCEL_TEAM_ID for a team project) in the server settings.
const { admin, verify, UUID } = require('../_auth');
const API = () => process.env.VERCEL_API_BASE || 'https://api.vercel.com';
const DOMAIN = /^(?=.{4,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$/;
const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
function vercelCfg() {
  const token = process.env.VERCEL_TOKEN, project = process.env.VERCEL_PROJECT_ID;
  if (!token || !project) throw Object.assign(new Error('Custom domains are not switched on for this server yet. The platform administrator needs to add VERCEL_TOKEN and VERCEL_PROJECT_ID.'), { status: 503 });
  return { token, project, team: process.env.VERCEL_TEAM_ID || '' };
}
async function vc(method, path, body) {
  const c = vercelCfg(); const u = new URL(API() + path.replace('{p}', encodeURIComponent(c.project)));
  if (c.team) u.searchParams.set('teamId', c.team);
  const r = await fetch(u, { method, headers: { authorization: 'Bearer ' + c.token, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined });
  let j = {}; try { j = await r.json(); } catch (e) { /* empty */ }
  return { ok: r.ok, status: r.status, j };
}
// what the customer must add at their DNS provider
function dnsFor(domain, vercelDomain) {
  const parts = domain.split('.'); const apex = parts.length === 2 || (parts.length === 3 && /^(co|com|org|net|gov|edu|ac)$/.test(parts[1]));
  const recs = [apex ? { type: 'A', name: '@', value: '76.76.21.21' } : { type: 'CNAME', name: parts[0], value: 'cname.vercel-dns.com' }];
  (vercelDomain && vercelDomain.verification || []).forEach((v) => recs.push({ type: v.type, name: v.domain, value: v.value, why: 'Proves you own the domain' }));
  return recs;
}
// the sign-in page brand for a workspace address: one company -> that company; several -> the workspace (its logo, else the first company logo)
const BASE = () => (process.env.ORZIO_BASE_DOMAIN || 'orzio.ai').toLowerCase();
const slugOf = (n) => String(n || '').toLowerCase().normalize('NFKD').replace(/[\u0300-\u036f]/g, '').replace(/\b(llc|l\.l\.c|ltd|limited|fze|fzco|fz|est|group|holdings?|the|co|inc|plc)\b/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 40);
async function bySlug(slug) {
  if (!/^[a-z0-9-]{2,40}$/.test(slug) || /^(www|app|api|admin)$/.test(slug)) return null;
  const db = admin(); const pat = '%' + slug.split('-').filter(Boolean).join('%') + '%';
  const { data: os } = await db.from('orgs').select('id,name,status').ilike('name', pat).limit(50);
  const o = (os || []).find((x) => x.status !== 'cancelled' && slugOf(x.name) === slug);
  if (o) return { data: { org_id: o.id, name: o.name }, ent: null };
  const { data: es } = await db.from('docs').select('org_id,path,data').like('path', 'setup/main/entities/%').ilike('data->>name', pat).limit(50);
  const e = (es || []).find((x) => slugOf(x.data && x.data.name) === slug && !/^(deleted|closed|archived)$/.test(String((x.data || {}).status || '')));
  if (e) return { data: { org_id: e.org_id, name: e.data.name }, ent: e.data };
  return null;
}
async function brandOf(org, base, ent) {
  if (ent) { const l = ent.brand && ent.brand.logo; const id = l && typeof l === 'object' ? l.id : null; return { name: ent.name || base.name, color: (ent.brand && ent.brand.color) || null, logo: id && /^[A-Za-z0-9_-]{6,64}$/.test(id) ? id : null, count: 1 }; }
  const out = { name: base.name, color: base.color, logo: null, count: 0 };
  try {
    const db = admin();
    const [{ data: o }, { data: rows }] = await Promise.all([
      db.from('orgs').select('name').eq('id', org).maybeSingle(),
      db.from('docs').select('path,data').eq('org_id', org).or('path.eq.setup/main,path.like.setup/main/entities/%'),
    ]);
    const idOf = (l) => (l && typeof l === 'object' ? l.id : null);
    const ws = (rows || []).find((r) => r.path === 'setup/main');
    const ents = (rows || []).filter((r) => /^setup\/main\/entities\/[^/]+$/.test(r.path) && r.data && !/^(deleted|closed|archived)$/.test(String(r.data.status || '')))
      .map((r) => ({ name: r.data.name, logo: idOf(r.data.brand && r.data.brand.logo), color: r.data.brand && r.data.brand.color }));
    out.count = ents.length;
    if (ents.length === 1) { out.name = ents[0].name || out.name; out.logo = ents[0].logo; out.color = ents[0].color || out.color; }
    else {
      if (o && o.name) out.name = o.name;
      out.logo = idOf(ws && ws.data && ws.data.logo) || (ents.find((e) => e.logo) || {}).logo || null;
      if (!out.color) out.color = (ents.find((e) => e.color) || {}).color || null;
    }
    if (out.logo && !/^[A-Za-z0-9_-]{6,64}$/.test(out.logo)) out.logo = null;
  } catch (e) { /* fall back to the lookup */ }
  return out;
}
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  try {
    if (req.method === 'GET') {
      const host = String((req.query && req.query.host) || '').toLowerCase();
      if (!DOMAIN.test(host)) return res.status(404).json({});
      let { data } = await admin().rpc('domain_lookup', { p_host: host });
      let ent = null;
      // <name>.orzio.ai that was never registered: find the workspace or company with that name
      if ((!data || !data.org_id) && host.endsWith('.' + BASE())) { const f = await bySlug(host.slice(0, -(BASE().length + 1))); if (f) { data = f.data; ent = f.ent; } }
      if (!data || !data.org_id) return res.status(404).json({ error: 'No workspace uses this address yet.' });
      const b = await brandOf(data.org_id, data, ent);
      if (req.query.logo) {
        if (!b.logo) return res.status(404).send('No logo');
        const { data: su } = await admin().storage.from('assets').createSignedUrl(data.org_id + '/' + b.logo, 3600);
        if (!su || !su.signedUrl) return res.status(404).send('No logo');
        res.setHeader('Cache-Control', 'public, max-age=300');
        res.writeHead(302, { Location: su.signedUrl }); return res.end();
      }
      return res.status(200).json({ org_id: data.org_id, name: b.name, color: b.color || null, has_logo: !!b.logo, companies: b.count });
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
    let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
    const { user, sb } = await verify(bearer(req));
    const org = String(b.org || ''); if (!UUID.test(org)) return res.status(400).json({ error: 'Choose a workspace.' });
    const { data: m } = await sb.from('members').select('role,status').eq('org_id', org).eq('user_id', user.id).maybeSingle();
    if (!m || m.status !== 'active' || m.role !== 'owner') return res.status(403).json({ error: 'Only the workspace owner can manage its domain.' });
    const action = String(b.action || 'list');
    // the workspace's own address on the Orzio domain: <name>.orzio.ai (served by the *.orzio.ai wildcard, no DNS work for the customer)
    if (action === 'subdomain') {
      const base = (process.env.ORZIO_BASE_DOMAIN || 'orzio.ai').toLowerCase();
      const slug = String(b.slug || '').trim().toLowerCase().replace(/[^a-z0-9-]/g, '-').replace(/-+/g, '-').replace(/^-|-$/g, '');
      if (!/^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$/.test(slug)) return res.status(400).json({ error: 'Use 3 to 40 letters, numbers or hyphens.' });
      if (/^(www|app|api|admin|mail|smtp|ftp|site|help|support|status|docs|blog|cdn|static|assets|auth|login|signup|billing|dev|staging|test|demo|orzio|vercel)$/.test(slug)) return res.status(400).json({ error: 'That name is reserved. Choose another.' });
      const domain = slug + '.' + base;
      const { data: taken } = await sb.from('org_domains').select('org_id').eq('domain', domain).maybeSingle();
      const { data: owner } = await admin().from('org_domains').select('org_id').eq('domain', domain).maybeSingle();
      if ((taken && taken.org_id !== org) || (owner && owner.org_id !== org)) return res.status(409).json({ error: `${domain} is already taken. Choose another name.` });
      const { data: mine } = await admin().from('org_domains').select('domain,detail').eq('org_id', org);
      for (const d of (mine || [])) if (d.detail && d.detail.kind === 'subdomain' && d.domain !== domain) await admin().from('org_domains').delete().eq('domain', d.domain);
      await admin().from('org_domains').upsert({ domain, org_id: org, status: 'verified', detail: { kind: 'subdomain' }, created_by: user.id, verified_at: new Date().toISOString() });
      return res.status(200).json({ domain, status: 'verified' });
    }
    if (action === 'list') { const { data } = await sb.from('org_domains').select('*').eq('org_id', org); return res.status(200).json({ domains: data || [], enabled: !!(process.env.VERCEL_TOKEN && process.env.VERCEL_PROJECT_ID) }); }
    const domain = String(b.domain || '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
    if (!DOMAIN.test(domain)) return res.status(400).json({ error: 'Enter a domain like app.yourcompany.com.' });
    if (/(^|\.)(vercel\.app|orzio\.ai|orzio\.com|localhost)$/.test(domain) && action === 'add') return res.status(400).json({ error: 'Use a domain your organisation owns.' });
    const { data: cur } = await sb.from('org_domains').select('*').eq('domain', domain).maybeSingle();
    if (cur && cur.org_id !== org) return res.status(409).json({ error: 'That domain is already used by another workspace.' });
    if (action === 'add') {
      const { count } = await sb.from('org_domains').select('domain', { count: 'exact', head: true }).eq('org_id', org);
      if (!cur && count >= 3) return res.status(400).json({ error: 'A workspace can have up to 3 domains.' });
      const r = await vc('POST', '/v10/projects/{p}/domains', { name: domain });
      if (!r.ok && !(r.j && r.j.error && r.j.error.code === 'domain_already_in_use')) return res.status(400).json({ error: (r.j.error && r.j.error.message) || 'Vercel did not accept the domain.' });
      const g = await vc('GET', `/v9/projects/{p}/domains/${encodeURIComponent(domain)}`);
      const detail = { dns: dnsFor(domain, g.j), vercel_verified: !!g.j.verified };
      await sb.from('org_domains').upsert({ domain, org_id: org, status: 'pending', detail, created_by: user.id });
      return res.status(200).json({ domain, status: 'pending', detail });
    }
    if (!cur) return res.status(404).json({ error: 'That domain is not set up for this workspace.' });
    if (action === 'check') {
      let g = await vc('GET', `/v9/projects/{p}/domains/${encodeURIComponent(domain)}`);
      if (g.ok && !g.j.verified) { await vc('POST', `/v9/projects/{p}/domains/${encodeURIComponent(domain)}/verify`); g = await vc('GET', `/v9/projects/{p}/domains/${encodeURIComponent(domain)}`); }
      const cfg = await vc('GET', `/v6/domains/${encodeURIComponent(domain)}/config`);
      const ok = g.ok && g.j.verified && cfg.ok && cfg.j.misconfigured === false;
      const detail = { dns: dnsFor(domain, g.j), vercel_verified: !!(g.j && g.j.verified), misconfigured: cfg.j ? cfg.j.misconfigured : null, checked_at: new Date().toISOString() };
      await sb.from('org_domains').update({ status: ok ? 'verified' : 'pending', detail, verified_at: ok ? new Date().toISOString() : null }).eq('domain', domain);
      return res.status(200).json({ domain, status: ok ? 'verified' : 'pending', detail });
    }
    if (action === 'remove') {
      await vc('DELETE', `/v9/projects/{p}/domains/${encodeURIComponent(domain)}`);
      await sb.from('org_domains').delete().eq('domain', domain);
      return res.status(200).json({ removed: domain });
    }
    return res.status(400).json({ error: 'Unknown action.' });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
