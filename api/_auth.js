// Shared helpers for the Vercel functions: verify the caller's Supabase session.
const { createClient } = require('@supabase/supabase-js');

const URL_ = process.env.SUPABASE_URL;
const SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY;
let client = null;

function admin() {
  if (!URL_ || !SERVICE) throw Object.assign(new Error('SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is not set on the server.'), { status: 503 });
  if (!client) client = createClient(URL_, SERVICE, { auth: { persistSession: false, autoRefreshToken: false } });
  return client;
}

// Returns { user, sb } or throws { status }.
async function verify(token) {
  if (!token) throw Object.assign(new Error('Sign in first.'), { status: 401 });
  const sb = admin();
  const { data, error } = await sb.auth.getUser(token);
  if (error || !data || !data.user) throw Object.assign(new Error('Your session has expired. Sign in again.'), { status: 401 });
  return { user: data.user, sb };
}

function cookie(req, name) {
  const h = req.headers.cookie || '';
  const m = h.split(/;\s*/).find((c) => c.startsWith(name + '='));
  return m ? decodeURIComponent(m.slice(name.length + 1)) : null;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

module.exports = { admin, verify, cookie, UUID };
