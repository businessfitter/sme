// POST /api/sign — saved signatures and signing confirmed by a one-time code sent to the signer's email.
//   {action:'send'}                      emails a 6-digit code to the signed-in person (Supabase Auth email)
//   {action:'verify', purpose:'save', code, image, method}
//                                        stores their saved signature
//   {action:'verify', purpose:'sign', code, org, req, key, doc_hash, stamp, use_saved, image?, method?, save?}
//                                        records a one-use attestation with the server time and returns it
// The code is checked by Supabase Auth; the attestation can only be written here, with the service key.
const crypto = require('crypto');
const { verify, publicClient, UUID } = require('../_auth');

const PNG = /^data:image\/png;base64,[A-Za-z0-9+/=]+$/;
const sha = (s) => crypto.createHash('sha256').update(s).digest('hex');
const bad = (res, status, error) => res.status(status).json({ error });

module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return bad(res, 405, 'POST only');
  const token = String(req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  let b = req.body;
  if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } }
  b = b || {};
  try {
    const { user, sb } = await verify(token);
    if (!user.email) return bad(res, 400, 'Your account has no email address.');
    const pub = publicClient();

    if (b.action === 'send') {
      const { data: open } = await sb.rpc('sig_code_gate', { p_user: user.id });
      if (open === false) return bad(res, 429, 'Too many wrong codes. Try again in an hour.');
      const { error } = await pub.auth.signInWithOtp({ email: user.email, options: { shouldCreateUser: false } });
      if (error) return bad(res, error.status === 429 ? 429 : 400, /rate|seconds/i.test(error.message || '') ? 'A code was sent a moment ago. Wait a minute before asking for another.' : 'The code could not be sent. ' + (error.message || ''));
      const at = user.email.indexOf('@');
      return res.status(200).json({ sent: true, to: user.email.slice(0, Math.min(2, at)) + '•••' + user.email.slice(at) });
    }

    if (b.action !== 'verify') return bad(res, 400, 'Unknown action');
    const code = String(b.code || '').replace(/\s+/g, '');
    if (!/^\d{6,10}$/.test(code)) return bad(res, 400, 'Enter the code from the email.');
    const { data: open } = await sb.rpc('sig_code_gate', { p_user: user.id });
    if (open === false) return bad(res, 429, 'Too many wrong codes. Try again in an hour.');
    const { data: v, error: vErr } = await pub.auth.verifyOtp({ email: user.email, token: code, type: 'email' });
    const ok = !vErr && v && v.user && v.user.id === user.id;
    await sb.rpc('sig_code_result', { p_user: user.id, p_ok: !!ok });
    if (v && v.session && v.session.access_token) { try { await sb.auth.admin.signOut(v.session.access_token); } catch (e) { /* best effort */ } }
    if (!ok) return bad(res, 400, 'That code is not right or has expired. Ask for a new one.');

    const fresh = typeof b.image === 'string' && PNG.test(b.image) && b.image.length <= 400000 ? b.image : null;
    if (b.purpose === 'save') {
      if (!fresh) return bad(res, 400, 'Draw, type or upload your signature first.');
      const { error } = await sb.rpc('sig_save', { p_user: user.id, p_image: fresh, p_method: String(b.method || '') });
      if (error) return bad(res, 400, 'The signature could not be saved.');
      return res.status(200).json({ saved: true });
    }
    if (b.purpose !== 'sign') return bad(res, 400, 'Unknown purpose');
    if (!UUID.test(String(b.org || ''))) return bad(res, 400, 'Bad workspace');
    if (!/^[\w-]{1,80}$/.test(String(b.req || '')) || !/^[\w-]{1,80}$/.test(String(b.key || '')) || !/^[a-f0-9]{64}$/.test(String(b.doc_hash || ''))) return bad(res, 400, 'Bad signing request');
    let image = fresh;
    if (b.use_saved) {
      const { data: saved } = await sb.rpc('sig_saved', { p_user: user.id });
      if (!saved) return bad(res, 400, 'You have no saved signature yet.');
      image = saved;
    } else if (!image) return bad(res, 400, 'Draw, type or upload your signature first.');
    else if (b.save) await sb.rpc('sig_save', { p_user: user.id, p_image: image, p_method: String(b.method || '') });
    const { data: att, error: aErr } = await sb.rpc('sig_attest', {
      p_user: user.id, p_org: b.org, p_req: String(b.req), p_key: String(b.key), p_doc_hash: String(b.doc_hash),
      p_image_sha: sha(image), p_stamp: b.stamp !== false, p_saved: !!b.use_saved,
    });
    if (aErr || !att) return bad(res, 403, (aErr && aErr.message) || 'Signing could not be recorded.');
    return res.status(200).json({ attest_id: att.id, verified_at: att.verified_at, image, method: b.use_saved ? 'saved signature' : String(b.method || 'drawn') });
  } catch (e) {
    return bad(res, e.status || 500, e.message || 'Something went wrong.');
  }
};
