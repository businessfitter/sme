// POST /api/signup {action:'notify'}  — a new person sent their requirements: email the platform admins.
// POST /api/signup {action:'decided', uid} — a platform admin approved or declined: email the person.
const { admin, verify, UUID } = require('../_auth');
const { sendMail, htmlMail } = require('../_mail');
const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
const list = (v) => (Array.isArray(v) ? v.join(', ') : String(v || ''));
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  try {
    const { user } = await verify(bearer(req));
    const db = admin();
    const site = (process.env.PUBLIC_URL || ('https://' + (req.headers['x-forwarded-host'] || req.headers.host || 'orzio.ai'))).replace(/\/$/, '');
    if (b.action === 'notify') {
      const { data: p } = await db.from('profiles').select('full_name,email,request,approval').eq('id', user.id).maybeSingle();
      if (!p || p.approval === 'approved') return res.status(200).json({ sent: 0 });
      const r = p.request || {};
      const { data: pa } = await db.from('platform_admins').select('user_id');
      const ids = (pa || []).map((x) => x.user_id);
      const { data: to } = ids.length ? await db.from('profiles').select('email').in('id', ids) : { data: [] };
      const text = `${p.full_name || ''} (${p.email}) asked for Orzio.\n\nCompany: ${r.company || '—'}\nIndustry: ${r.industry || '—'}\nCountry: ${r.country || '—'}\nPeople who will use it: ${r.users || '—'}\nModules: ${list(r.modules) || '—'}\nPhone: ${r.phone || '—'}\n\nWhat they need:\n${r.notes || '—'}`;
      let sent = 0;
      for (const x of to || []) { if (!x.email) continue; const s = await sendMail({ to: x.email, subject: `New Orzio request: ${r.company || p.email}`, text, html: htmlMail('New request to review', text, site + '/admin', 'Review in Platform admin'), replyTo: p.email }); if (s.sent) sent++; }
      return res.status(200).json({ sent });
    }
    if (b.action === 'decided') {
      const { data: isA } = await db.from('platform_admins').select('user_id').eq('user_id', user.id).maybeSingle();
      if (!isA) return res.status(403).json({ error: 'Platform admins only.' });
      const uid = String(b.uid || ''); if (!UUID.test(uid)) return res.status(400).json({ error: 'Choose the person.' });
      const { data: p } = await db.from('profiles').select('full_name,email,approval,request').eq('id', uid).maybeSingle();
      if (!p || !p.email) return res.status(404).json({ error: 'Not found.' });
      const co = (p.request && p.request.company) || 'your company';
      const ok = p.approval === 'approved';
      const text = ok ? `Hello ${p.full_name || ''},\n\nOrzio is ready for ${co}. Sign in to open your workspace.` : `Hello ${p.full_name || ''},\n\nThank you for your interest in Orzio. We are not able to set up ${co} at this time. Reply to this email if you would like to talk to us.`;
      const s = await sendMail({ to: p.email, subject: ok ? 'Your Orzio workspace is ready' : 'Your Orzio request', text, html: htmlMail(ok ? 'Your workspace is ready' : 'About your request', text, ok ? site + '/app' : '', 'Sign in') });
      return res.status(200).json(s);
    }
    return res.status(400).json({ error: 'Unknown action.' });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
