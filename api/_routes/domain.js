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
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  try {
    if (req.method === 'GET') {
      const host = String((req.query && req.query.host) || '').toLowerCase();
      if (!DOMAIN.test(host)) return res.status(404).json({});
      const { data } = await admin().rpc('domain_lookup', { p_host: host });
      return data ? res.status(200).json(data) : res.status(404).json({});
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
    let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
    const { user, sb } = await verify(bearer(req));
    const org = String(b.org || ''); if (!UUID.test(org)) return res.status(400).json({ error: 'Choose a workspace.' });
    const { data: m } = await sb.from('members').select('role,status').eq('org_id', org).eq('user_id', user.id).maybeSingle();
    if (!m || m.status !== 'active' || m.role !== 'owner') return res.status(403).json({ error: 'Only the workspace owner can manage its domain.' });
    const action = String(b.action || 'list');
    if (action === 'list') { const { data } = await sb.from('org_domains').select('*').eq('org_id', org); return res.status(200).json({ domains: data || [], enabled: !!(process.env.VERCEL_TOKEN && process.env.VERCEL_PROJECT_ID) }); }
    const domain = String(b.domain || '').trim().toLowerCase().replace(/^https?:\/\//, '').replace(/\/.*$/, '');
    if (!DOMAIN.test(domain)) return res.status(400).json({ error: 'Enter a domain like app.yourcompany.com.' });
    if (/(^|\.)(vercel\.app|orzio\.ai|orzio\.com|localhost)$/.test(domain)) return res.status(400).json({ error: 'Use a domain your organisation owns.' });
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
