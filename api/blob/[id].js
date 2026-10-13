// GET /_blob/<id> (rewritten to /api/blob/<id>) — serves an uploaded document or logo.
// Files live in a private bucket at assets/<company id>/<file id>. Staff of that company get a
// two-minute signed link; employees, customers and suppliers only for files shared to their portal.
const { verify, cookie } = require('../_auth');

module.exports = async (req, res) => {
  const id = String(req.query.id || '');
  if (!/^[A-Za-z0-9_-]{6,64}$/.test(id)) return res.status(400).send('Bad file id');
  try {
    const { user, sb } = await verify(cookie(req, 'sb-token'));
    const { data: org, error: lErr } = await sb.rpc('blob_locate', { p_user: user.id, p_id: id });
    if (lErr || !org) return res.status(404).send('File not found');
    const { data, error } = await sb.storage.from('assets').createSignedUrl(org + '/' + id, 120);
    if (error || !data) return res.status(404).send('File not found');
    res.setHeader('Cache-Control', 'private, no-store');
    res.writeHead(302, { Location: data.signedUrl });
    return res.end();
  } catch (e) {
    return res.status(e.status || 401).send(e.message || 'Sign in first');
  }
};
