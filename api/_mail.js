// Sends email through Resend (resend.com) when RESEND_API_KEY and EMAIL_FROM are set on the server.
// Without them, the app falls back to opening the user's own email program with the message filled in.
async function sendMail({ to, subject, text, html, replyTo }) {
  const key = process.env.RESEND_API_KEY, from = process.env.EMAIL_FROM;
  if (!key || !from) return { sent: false, reason: 'not_configured' };
  const r = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { authorization: 'Bearer ' + key, 'content-type': 'application/json' },
    body: JSON.stringify({ from, to: [to], subject, text, html, reply_to: replyTo || undefined }),
  });
  if (!r.ok) { let m = ''; try { m = (await r.json()).message || ''; } catch (e) { /* empty */ } return { sent: false, reason: 'provider', message: m }; }
  return { sent: true };
}
const EMAIL = /^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]+$/;
const esc = (s) => String(s == null ? '' : s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
function htmlMail(title, text, link, linkLabel, company) {
  return `<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:#1E242C"><div style="background:#0E1B33;color:#fff;padding:18px 22px;border-radius:12px 12px 0 0;font-size:18px">${esc(company || 'Orzio')}</div><div style="border:1px solid #E3E6EA;border-top:0;padding:22px;border-radius:0 0 12px 12px"><h2 style="margin:0 0 12px;font-size:18px">${esc(title)}</h2><p style="white-space:pre-wrap;line-height:1.5">${esc(text)}</p>${link ? `<p><a href="${esc(link)}" style="display:inline-block;background:#0B8277;color:#fff;padding:11px 18px;border-radius:8px;text-decoration:none">${esc(linkLabel || 'Open')}</a></p><p style="font-size:12px;color:#5F6874">Or copy this link: ${esc(link)}</p>` : ''}</div><p style="font-size:11px;color:#94A3B8;text-align:center">Sent with Orzio</p></div>`;
}
module.exports = { sendMail, EMAIL, htmlMail };
