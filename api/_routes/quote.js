// /api/quote?t=<token> — a customer opens a quote from the link in their email, without logging in.
// GET returns the quote; POST {t, action: accept|changes|decline, name, comment} records the answer.
const { admin } = require('../_auth');
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('X-Robots-Tag', 'noindex');
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  const t = String((req.query && req.query.t) || b.t || '');
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(t)) return res.status(400).json({ error: 'This link is not valid.' });
  try {
    const sb = admin();
    if (req.method === 'GET') {
      const { data, error } = await sb.rpc('quote_public', { p_token: t });
      if (error || !data || !data.org_ok) return res.status(404).json({ error: 'This quote could not be found. It may have been replaced by a newer version.' });
      delete data.org_ok;
      return res.status(200).json(data);
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
    const { data, error } = await sb.rpc('quote_public_answer', { p_token: t, p_action: String(b.action || ''), p_name: String(b.name || '').slice(0, 120), p_comment: String(b.comment || '').slice(0, 4000) });
    if (error) return res.status(400).json({ error: 'Your answer could not be saved.' });
    if (!data.ok) return res.status(409).json({ error: data.why });
    return res.status(200).json(data);
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
