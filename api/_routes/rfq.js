// /api/rfq?t=<token> — a supplier opens a request for quotation from the link and submits a quotation, without logging in.
const { admin } = require('../_auth');
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store'); res.setHeader('X-Robots-Tag', 'noindex');
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  const t = String((req.query && req.query.t) || b.t || '');
  if (!/^[A-Za-z0-9_-]{32,128}$/.test(t)) return res.status(400).json({ error: 'This link is not valid.' });
  try {
    const sb = admin();
    if (req.method === 'GET') {
      const { data, error } = await sb.rpc('rfq_public', { p_token: t });
      if (error || !data || !data.org_ok) return res.status(404).json({ error: 'This request for quotation could not be found.' });
      delete data.org_ok; return res.status(200).json(data);
    }
    if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
    const q = b.quote || {};
    const lines = Array.isArray(q.lines) ? q.lines.slice(0, 100).map((l) => ({ price: Math.max(0, Number(l.price) || 0), note: String(l.note || '').slice(0, 300) })) : [];
    const att = typeof q.attachment === 'string' && /^data:(application\/pdf|image\/(png|jpeg));base64,/.test(q.attachment) && q.attachment.length <= 690000 ? q.attachment : null;
    const quote = { company: String(q.company || '').slice(0, 160), contact: String(q.contact || '').slice(0, 120), email: String(q.email || '').slice(0, 160), lines, delivery_days: Math.max(0, Number(q.delivery_days) || 0), payment_days: Math.max(0, Number(q.payment_days) || 0), validity_days: Math.max(0, Number(q.validity_days) || 0), vat_included: !!q.vat_included, notes: String(q.notes || '').slice(0, 2000), attachment: att, attachment_name: att ? String(q.attachment_name || 'quotation').slice(0, 120) : null };
    if (!quote.company || !lines.length) return res.status(400).json({ error: 'Enter your company name and your prices.' });
    const { data, error } = await sb.rpc('rfq_public_submit', { p_token: t, p_quote: quote });
    if (error) return res.status(400).json({ error: 'Your quotation could not be saved.' });
    if (!data.ok) return res.status(409).json({ error: data.why });
    return res.status(200).json({ ok: true });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
