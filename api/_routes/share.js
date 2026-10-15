// /api/share?t=<token> — a patient opens their prescription or lab report from a link that expires.
const { admin } = require('../_auth');
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Robots-Tag', 'noindex');
  if (req.method !== 'GET') return res.status(405).json({ error: 'Not allowed' });
  const t = String((req.query && req.query.t) || '');
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(t)) return res.status(400).json({ error: 'This link is not valid.' });
  try {
    const { data, error } = await admin().rpc('share_public', { p_token: t });
    if (error || !data || !data.org_ok) return res.status(404).json({ error: 'This record could not be found.' });
    if (data.expired) return res.status(410).json({ error: 'This link has expired. Ask the clinic for a new one.' });
    delete data.org_ok; return res.status(200).json(data);
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
