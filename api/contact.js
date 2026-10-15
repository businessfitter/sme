// POST /api/contact — the website's contact form. Sends the message to CONTACT_EMAIL (or the platform's support_email).
const { admin } = require('./_auth');
const { sendMail, EMAIL } = require('./_mail');
const hits = new Map();
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  if (b.website) return res.status(200).json({ ok: true }); // bots fill the hidden field
  const ip = String(req.headers['x-forwarded-for'] || '').split(',')[0].trim() || 'x'; const now = Date.now();
  const list = (hits.get(ip) || []).filter((t) => now - t < 3600e3); if (list.length >= 5) return res.status(429).json({ error: 'Too many messages. Email us instead.' }); list.push(now); hits.set(ip, list);
  const name = String(b.name || '').trim().slice(0, 120), email = String(b.email || '').trim().slice(0, 160);
  if (name.length < 2 || !EMAIL.test(email)) return res.status(400).json({ error: 'Enter your name and a valid email.' });
  let to = process.env.CONTACT_EMAIL || '';
  if (!to) { try { const { data } = await admin().from('platform_config').select('value').eq('key', 'support_email').maybeSingle(); to = (data && data.value) || ''; } catch (e) { /* not set */ } }
  if (!to) return res.status(503).json({ error: 'The form is not switched on yet. Email us instead.' });
  const lines = [`Name: ${name}`, `Email: ${email}`, `Phone: ${String(b.phone || '').slice(0, 40)}`, `Company: ${String(b.company || '').slice(0, 160)}`, `Topic: ${String(b.topic || '').slice(0, 40)}`, '', String(b.message || '').slice(0, 5000)];
  const r = await sendMail({ to, subject: `Website: ${String(b.topic || 'message')} from ${name}`, text: lines.join('\n'), replyTo: email });
  if (!r.sent) return res.status(503).json({ error: 'It could not be sent. Email us instead.' });
  return res.status(200).json({ ok: true });
};
