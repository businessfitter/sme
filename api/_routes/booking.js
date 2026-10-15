// /api/booking?t=<clinic booking token> — patients ask for an appointment without logging in.
// GET returns the clinic and its doctors; POST {t, name, phone, doctor, date, note} records a request the front desk confirms.
const { admin } = require('../_auth');
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Robots-Tag', 'noindex');
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  const t = String((req.query && req.query.t) || b.t || '');
  if (!/^[A-Za-z0-9_-]{24,128}$/.test(t)) return res.status(400).json({ error: 'This link is not valid.' });
  try {
    const sb = admin();
    if (req.method === 'GET') {
      const { data, error } = await sb.rpc('booking_public', { p_token: t });
      if (error || !data || !data.org_ok) return res.status(404).json({ error: 'Online booking is not available for this clinic.' });
      delete data.org_ok; return res.status(200).json(data);
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
    const { data, error } = await sb.rpc('booking_public_request', { p_token: t, p_name: String(b.name || '').slice(0, 120), p_phone: String(b.phone || '').slice(0, 30), p_doctor: String(b.doctor || '').slice(0, 40), p_date: /^\d{4}-\d\d-\d\d$/.test(b.date || '') ? b.date : null, p_note: String(b.note || '').slice(0, 500) });
    if (error) return res.status(400).json({ error: 'Your request could not be saved.' });
    if (!data.ok) return res.status(409).json({ error: data.why });
    return res.status(200).json(data);
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
