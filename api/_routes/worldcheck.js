// POST /api/worldcheck — screens names with LSEG World-Check One when the workspace has credentials on the server:
// WC1_API_KEY, WC1_API_SECRET, WC1_GROUP_ID (and optionally WC1_HOST, default api-worldcheck.refinitiv.com).
// Built to LSEG's published API (v2, HMAC-SHA256 request signing). Not testable without credentials.
const crypto = require('crypto');
const { verify, UUID } = require('../_auth');
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  const key = process.env.WC1_API_KEY, secret = process.env.WC1_API_SECRET, group = process.env.WC1_GROUP_ID;
  if (req.method === 'GET') return res.status(200).json({ configured: !!(key && secret && group) });
  if (!key || !secret || !group) return res.status(200).json({ configured: false });
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  try {
    const { user, sb } = await verify(String(req.headers.authorization || '').replace(/^Bearer\s+/i, ''));
    if (!UUID.test(String(b.org || ''))) return res.status(400).json({ error: 'Bad workspace' });
    const { data: m } = await sb.from('members').select('role,status').eq('org_id', b.org).eq('user_id', user.id).maybeSingle();
    if (!m || m.status !== 'active' || !['owner', 'staff'].includes(m.role)) return res.status(403).json({ error: 'Not allowed' });
    const host = process.env.WC1_HOST || 'api-worldcheck.refinitiv.com'; const base = '/v2/';
    const names = (Array.isArray(b.names) ? b.names : []).slice(0, 25);
    const out = [];
    for (const n of names) {
      const body = JSON.stringify({ groupId: group, entityType: n.type === 'individual' ? 'INDIVIDUAL' : 'ORGANISATION', providerTypes: ['WATCHLIST'], name: String(n.name || '').slice(0, 200), secondaryFields: [], customFields: [] });
      const path = base + 'cases/screeningRequest'; const date = new Date().toUTCString(); const len = Buffer.byteLength(body);
      const toSign = `(request-target): post ${path}\nhost: ${host}\ndate: ${date}\ncontent-type: application/json\ncontent-length: ${len}\n${body}`;
      const sig = crypto.createHmac('sha256', secret).update(toSign).digest('base64');
      const r = await fetch(`https://${host}${path}`, { method: 'POST', headers: { Date: date, 'Content-Type': 'application/json', 'Content-Length': String(len), Authorization: `Signature keyId="${key}",algorithm="hmac-sha256",headers="(request-target) host date content-type content-length",signature="${sig}"` }, body });
      if (!r.ok) { out.push({ name: n.name, error: `World-Check answered ${r.status}` }); continue; }
      const j = await r.json();
      out.push({ name: n.name, case_id: j.caseId || null, matches: (j.results || []).slice(0, 10).map((x) => ({ source: 'worldcheck', name: x.matchedTerm || x.primaryName, strength: x.matchStrength, categories: x.categories || [], ref: x.referenceId })) });
    }
    return res.status(200).json({ configured: true, results: out });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'World-Check request failed.' }); }
};
