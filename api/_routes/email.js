// POST /api/email — a team member sends a quote, agreement, statement or reminder to a customer.
// Body: {org, to, subject, text, link, link_label, kind}. Only owners and team members of that workspace; capped per day.
const { verify, UUID } = require('../_auth');
const { sendMail, EMAIL, htmlMail } = require('../_mail');
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  try {
    const { user, sb } = await verify(String(req.headers.authorization || '').replace(/^Bearer\s+/i, ''));
    if (!UUID.test(String(b.org || ''))) return res.status(400).json({ error: 'Bad workspace' });
    const to = String(b.to || '').trim();
    if (!EMAIL.test(to)) return res.status(400).json({ error: 'Enter a valid email address.' });
    if (!process.env.RESEND_API_KEY || !process.env.EMAIL_FROM) return res.status(200).json({ sent: false, reason: 'not_configured' });
    const { data: ok } = await sb.rpc('email_gate', { p_org: b.org, p_user: user.id, p_kind: String(b.kind || 'mail'), p_to: to });
    if (!ok) return res.status(403).json({ error: 'Not allowed, or today’s email limit for this workspace is reached.' });
    const subject = String(b.subject || '').slice(0, 200) || 'A message for you';
    const text = String(b.text || '').slice(0, 8000);
    const link = /^https:\/\//.test(String(b.link || '')) ? String(b.link) : '';
    const r = await sendMail({ to, subject, text: text + (link ? '\n\n' + link : ''), html: htmlMail(subject, text, link, b.link_label, b.company), replyTo: EMAIL.test(user.email || '') ? user.email : undefined });
    return res.status(200).json(r);
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Could not send.' }); }
};
