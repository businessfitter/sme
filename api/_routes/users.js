// POST /api/users {action:'create', org, email, name, password?}
// The workspace owner (or an admin) creates a sign-in for an employee or another person, with a temporary password.
// The person is asked to choose their own password the first time they sign in. Access rights are then given in Logins and access.
const crypto = require('crypto');
const { admin, verify, UUID } = require('../_auth');
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;
const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
function tempPassword() { const A = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789'; const b = crypto.randomBytes(12); let s = ''; for (let i = 0; i < 12; i++) s += A[b[i] % A.length]; return s.slice(0, 4) + '-' + s.slice(4, 8) + '-' + s.slice(8); }
module.exports = async (req, res) => {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Not allowed' });
  let b = req.body; if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } } b = b || {};
  try {
    const { user } = await verify(bearer(req));
    const org = String(b.org || ''); if (!UUID.test(org)) return res.status(400).json({ error: 'Choose a workspace.' });
    const db = admin();
    const { data: m } = await db.from('members').select('role,status').eq('org_id', org).eq('user_id', user.id).maybeSingle();
    if (!m || m.status !== 'active' || !['owner', 'admin'].includes(m.role)) return res.status(403).json({ error: 'Only the workspace owner or an admin can create logins.' });
    if (b.action === 'reset') {
      const uid = String(b.uid || ''); if (!UUID.test(uid)) return res.status(400).json({ error: 'Choose the person.' });
      if (uid === user.id) return res.status(400).json({ error: 'Change your own password in Workspace settings, Password.' });
      const { data: tm } = await db.from('members').select('role').eq('org_id', org).eq('user_id', uid).maybeSingle();
      if (!tm) return res.status(404).json({ error: 'This person is not in this workspace.' });
      if (tm.role === 'owner') return res.status(403).json({ error: 'The owner’s password can only be changed by the owner.' });
      let pw = String(b.password || ''); if (pw && pw.length < 8) return res.status(400).json({ error: 'The temporary password needs at least 8 characters.' }); if (!pw) pw = tempPassword();
      const { data: cur } = await db.auth.admin.getUserById(uid);
      const meta = { ...((cur && cur.user && cur.user.user_metadata) || {}), must_change: true, reset_by: user.id, reset_at: new Date().toISOString() };
      const { error } = await db.auth.admin.updateUserById(uid, { password: pw, user_metadata: meta });
      if (error) return res.status(400).json({ error: error.message || 'The password could not be reset.' });
      const { data: pr } = await db.from('profiles').select('email,full_name').eq('id', uid).maybeSingle();
      return res.status(200).json({ id: uid, email: pr && pr.email, name: pr && pr.full_name, password: pw });
    }
    if ((b.action || 'create') !== 'create') return res.status(400).json({ error: 'Unknown action.' });
    const email = String(b.email || '').trim().toLowerCase(); const name = String(b.name || '').trim().slice(0, 120);
    if (!EMAIL.test(email)) return res.status(400).json({ error: 'Enter a valid email address.' });
    if (!name) return res.status(400).json({ error: 'Enter the person’s full name.' });
    let password = String(b.password || '');
    if (password && password.length < 8) return res.status(400).json({ error: 'The temporary password needs at least 8 characters.' });
    const { data: ex } = await db.from('profiles').select('id,full_name').ilike('email', email).maybeSingle();
    if (ex && ex.id) return res.status(200).json({ id: ex.id, name: ex.full_name || name, existed: true });
    if (!password) password = tempPassword();
    const { data, error } = await db.auth.admin.createUser({ email, password, email_confirm: true, user_metadata: { full_name: name, must_change: true, created_by: user.id, created_for: org } });
    if (error || !data || !data.user) return res.status(400).json({ error: (error && error.message) || 'The login could not be created.' });
    try { await db.from('profiles').upsert({ id: data.user.id, full_name: name, email }, { onConflict: 'id' }); } catch (e) { /* profile trigger usually does this */ }
    return res.status(200).json({ id: data.user.id, name, email, password, existed: false });
  } catch (e) { return res.status(e.status || 500).json({ error: e.message || 'Something went wrong.' }); }
};
