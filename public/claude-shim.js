/*
 * SME Suite platform layer — commercial, multi-company edition (Supabase + Vercel).
 *
 * The app talks to its platform only through `window.claude.use(name)`.
 * This file provides those namespaces on your own stack, scoped to ONE company at a time:
 *   db         -> Supabase table `docs` (org_id + path) with realtime updates
 *   user       -> Supabase Auth + company membership
 *   sample     -> /api/ai (Vercel function: quotas, rate limits, usage log)
 *   assets     -> Supabase Storage `assets/<company id>/<file id>`, served through /_blob/<id>
 *   downloads  -> a normal browser download
 * It also adds: workspace sign-up (one workspace = one customer business), a workspace switcher, plan and usage, and trial / read-only notices.
 */
(function () {
  'use strict';
  const cfg = window.__SUPA || {};
  if (!cfg.url || !cfg.anon || !window.supabase) {
    document.addEventListener('DOMContentLoaded', () => {
      document.body.innerHTML = '<div style="font:16px system-ui;padding:2rem;max-width:40rem;margin:auto"><h2>Setup needed</h2><p>SUPABASE_URL and SUPABASE_ANON_KEY are not set on the server. Add them in Vercel → Settings → Environment Variables and redeploy.</p></div>';
    });
    window.claude = { use: async () => null };
    return;
  }
  const APP = cfg.appName || 'SME Suite';
  const sb = window.supabase.createClient(cfg.url, cfg.anon, { auth: { persistSession: true, autoRefreshToken: true } });
  window.__sb = sb;

  const store = {
    get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set(k, v) { try { v == null ? localStorage.removeItem(k) : localStorage.setItem(k, v); } catch (e) {} },
  };
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const whenDom = () => (document.readyState === 'loading' ? new Promise((r) => document.addEventListener('DOMContentLoaded', r)) : Promise.resolve());

  // ---------- session ----------
  let session = null, profile = null, info = {}, orgs = [], invites = [], org = null, ORG = null;
  const setCookie = (s) => {
    const t = s && s.access_token;
    document.cookie = t ? `sb-token=${t}; Path=/; Max-Age=3600; SameSite=Lax; Secure` : 'sb-token=; Path=/; Max-Age=0; SameSite=Lax; Secure';
  };
  sb.auth.onAuthStateChange((_e, s) => { session = s; setCookie(s); });

  // ---------- shared screen styles (sign-in, company setup) ----------
  const SCREEN_CSS = `
#sb-auth{position:fixed;inset:0;z-index:9999;display:grid;place-items:center;overflow:auto;background:radial-gradient(60% 50% at 18% 12%,rgba(20,184,166,.32),transparent 70%),radial-gradient(55% 45% at 88% 92%,rgba(242,167,195,.34),transparent 70%),linear-gradient(160deg,#0E1B33,#13213D 45%,#23272E);font-family:Roboto,system-ui,sans-serif;padding:1rem}
#sb-auth .c{width:min(27rem,100%);background:#fff;border-radius:22px;padding:1.8rem;box-shadow:0 40px 90px -30px rgba(0,0,0,.6);color:#0E1B33}
#sb-auth h1{font-size:1.5rem;margin:.2rem 0 .3rem}#sb-auth p{color:#5B6472;margin:0 0 1.2rem;font-size:.95rem;line-height:1.45}
#sb-auth label{display:block;font-size:.85rem;color:#5B6472;margin:.7rem 0 .3rem}#sb-auth input:not([type=checkbox]){width:100%;box-sizing:border-box;padding:.75rem .9rem;border-radius:12px;border:1px solid #E4E7EE;font:inherit}
#sb-auth label.ck{display:flex;gap:.55rem;align-items:flex-start;color:#2B3340;font-size:.9rem;margin-top:1rem;line-height:1.35}#sb-auth label.ck input{margin-top:.15rem}
#sb-auth button{width:100%;margin-top:1rem;padding:.8rem;border-radius:12px;border:0;background:#0E1B33;color:#fff;font:inherit;font-weight:500;cursor:pointer}
#sb-auth button:disabled{opacity:.6;cursor:default}
#sb-auth .alt{background:#fff;color:#0E1B33;border:1px solid #E4E7EE}#sb-auth .msg{min-height:1.2rem;font-size:.85rem;color:#B84A7C;margin-top:.8rem}
#sb-auth .brand{display:flex;gap:.6rem;align-items:center;font-weight:500}#sb-auth .brand i{width:1.8rem;height:1.8rem;border-radius:.5rem;background:linear-gradient(135deg,#14B8A6,#1D3D7A)}
#sb-auth .sw{background:none;border:0;color:#0F9488;width:auto;padding:0;margin-top:1rem;font-size:.9rem}
#sb-auth .legal{font-size:.8rem;color:#5B6472;margin-top:.9rem}#sb-auth .legal a{color:#0F9488}
#sb-auth .box{background:#F5F7F9;border-radius:12px;padding:.8rem .9rem;font-size:.88rem;color:#2B3340;margin-top:1.2rem;line-height:1.45}
#sb-auth .row{display:flex;gap:.6rem}#sb-auth .row button{margin-top:.8rem}`;
  const legalLine = (verb) => (cfg.termsUrl || cfg.privacyUrl)
    ? `<div class="legal">By ${verb} you agree to the ${cfg.termsUrl ? `<a href="${esc(cfg.termsUrl)}" target="_blank" rel="noopener">Terms of Service</a>` : ''}${cfg.termsUrl && cfg.privacyUrl ? ' and ' : ''}${cfg.privacyUrl ? `<a href="${esc(cfg.privacyUrl)}" target="_blank" rel="noopener">Privacy Policy</a>` : ''}.</div>`
    : '';
  function screen(html) {
    const wrap = document.createElement('div');
    wrap.id = 'sb-auth';
    wrap.innerHTML = `<style>${SCREEN_CSS}</style><div class="c"><div class="brand"><i></i>${esc(APP)}</div>${html}</div>`;
    document.body.append(wrap);
    return wrap;
  }

  // ---------- sign in / create account ----------
  function authScreen() {
    const startUp = /[?&]signup\b/.test(location.search);
    const wrap = screen(`<h1 id="sb-t">Sign in</h1><p id="sb-s">Use your work email.</p>
<form id="sb-f"><div id="sb-nm" hidden><label for="sb-n">Full name</label><input id="sb-n" autocomplete="name"></div>
<label for="sb-e">Email</label><input id="sb-e" type="email" autocomplete="email" required>
<label for="sb-p">Password</label><input id="sb-p" type="password" autocomplete="current-password" minlength="8" required>
<button type="submit" id="sb-go">Sign in</button></form>
<button class="alt" type="button" id="sb-ml">Email me a sign-in link instead</button>
<button class="sw" type="button" id="sb-fp">Forgot your password?</button>
<div class="msg" id="sb-m" role="status"></div><div id="sb-lg" hidden>${legalLine('creating an account')}</div>
<button class="sw" type="button" id="sb-sw">New here? Create an account</button>`);
    let mode = 'in';
    const $ = (id) => wrap.querySelector('#' + id), msg = (t) => { $('sb-m').textContent = t; };
    const setMode = (m) => {
      mode = m;
      $('sb-t').textContent = mode === 'in' ? 'Sign in' : 'Create your account';
      $('sb-s').textContent = mode === 'in' ? 'Use your work email.' : 'Start with a free trial for your business, or join a company that invited you.';
      $('sb-go').textContent = mode === 'in' ? 'Sign in' : 'Create account';
      $('sb-sw').textContent = mode === 'in' ? 'New here? Create an account' : 'Already have an account? Sign in';
      $('sb-p').autocomplete = mode === 'in' ? 'current-password' : 'new-password';
      $('sb-nm').hidden = mode === 'in'; $('sb-lg').hidden = mode === 'in'; $('sb-fp').hidden = mode !== 'in'; msg('');
    };
    if (startUp) setMode('up');
    $('sb-sw').onclick = () => setMode(mode === 'in' ? 'up' : 'in');
    $('sb-f').onsubmit = async (e) => {
      e.preventDefault(); msg(''); $('sb-go').disabled = true;
      const email = $('sb-e').value.trim(), password = $('sb-p').value;
      const r = mode === 'in'
        ? await sb.auth.signInWithPassword({ email, password })
        : await sb.auth.signUp({ email, password, options: { data: { full_name: $('sb-n').value.trim() }, emailRedirectTo: location.origin } });
      $('sb-go').disabled = false;
      if (r.error) return msg(r.error.message);
      if (mode === 'up' && !r.data.session) return msg('Check your inbox to confirm your email, then sign in.');
      try { sessionStorage.setItem('aifd-in', '1'); } catch (x) {}
      location.reload();
    };
    $('sb-ml').onclick = async () => {
      const email = $('sb-e').value.trim(); if (!email) return msg('Enter your email first.');
      const r = await sb.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin, shouldCreateUser: mode === 'up' } });
      msg(r.error ? r.error.message : 'Check your inbox for the sign-in link.');
    };
    $('sb-fp').onclick = async () => {
      const email = $('sb-e').value.trim(); if (!email) return msg('Enter your email first.');
      const r = await sb.auth.resetPasswordForEmail(email, { redirectTo: location.origin + '/?reset' });
      msg(r.error ? r.error.message : 'Check your inbox for a link to set a new password.');
    };
  }

  // ---------- set a new password (after the reset email link) ----------
  function resetScreen() {
    const wrap = screen(`<h1>Set a new password</h1><p>Choose a password of at least 8 characters.</p>
<form id="sb-f"><label for="sb-p">New password</label><input id="sb-p" type="password" autocomplete="new-password" minlength="8" required>
<button type="submit" id="sb-go">Save password</button></form><div class="msg" id="sb-m" role="status"></div>`);
    const $ = (id) => wrap.querySelector('#' + id);
    $('sb-f').onsubmit = async (e) => {
      e.preventDefault();
      const r = await sb.auth.updateUser({ password: $('sb-p').value });
      if (r.error) { $('sb-m').textContent = r.error.message; return; }
      location.replace(location.origin + '/');
    };
  }

  // ---------- company setup (no company yet) ----------
  function companyScreen(opts) {
    opts = opts || {};
    const email = (session && session.user.email) || '';
    const create = info.can_create_org ? `
<form id="sb-f"><label for="sb-c">Workspace name — usually your business name</label><input id="sb-c" autocomplete="organization" maxlength="120" required placeholder="e.g. Al Noor Trading">
${info.has_sample ? '<label class="ck"><input type="checkbox" id="sb-sm"> <span>Start with sample data so I can explore every module first (you can start a clean workspace later)</span></label>' : ''}
<button type="submit" id="sb-go">${info.mode === 'single' ? 'Set up the workspace' : 'Start free trial'}</button></form>${legalLine('continuing')}` : '';
    const wrap = screen(`<h1>${opts.another ? 'Add another workspace' : info.can_create_org ? 'Set up your workspace' : 'Waiting for access'}</h1>
<p>${info.can_create_org
      ? (info.mode === 'single' ? 'Name the business this installation is for. You will be its owner.' : 'A workspace holds one business: its books, team and settings, private to you. Add its legal entities and branches inside it later.')
      : 'Your account is ready, but no workspace has given you access yet.'}</p>${create}
<div class="msg" id="sb-m" role="status"></div>
<div class="box">${info.can_create_org ? 'Joining your employer or a client instead? ' : ''}Ask the workspace owner to add <b>${esc(email)}</b> in Settings, Logins and access, then press Refresh.</div>
<div class="row">${opts.another ? '<button class="alt" type="button" id="sb-bk">Back</button>' : '<button class="alt" type="button" id="sb-rf">Refresh</button>'}<button class="alt" type="button" id="sb-so">Sign out</button></div>`);
    const $ = (id) => wrap.querySelector('#' + id), msg = (t) => { $('sb-m').textContent = t; };
    if ($('sb-rf')) $('sb-rf').onclick = () => location.reload();
    if ($('sb-bk')) $('sb-bk').onclick = () => wrap.remove();
    $('sb-so').onclick = async () => { await sb.auth.signOut(); setCookie(null); location.reload(); };
    if ($('sb-f')) $('sb-f').onsubmit = async (e) => {
      e.preventDefault(); msg(''); $('sb-go').disabled = true;
      const r = await sb.rpc('create_org', { p_name: $('sb-c').value.trim(), p_sample: !!($('sb-sm') && $('sb-sm').checked) });
      if (r.error) { $('sb-go').disabled = false; return msg(r.error.message); }
      store.set('sme-org', r.data);
      try { sessionStorage.setItem('aifd-in', '1'); } catch (x) {}
      location.reload();
    };
  }

  // ---------- invitations (someone added you to their workspace) ----------
  const ROLE_WORD = { owner: 'owner', staff: 'a team member', viewer: 'a read-only member', portal: 'an employee, customer or supplier' };
  async function answer(id, yes) {
    const r = await sb.rpc('answer_invite', { p_org: id, p_accept: yes });
    if (r.error) { alert(r.error.message); return; }
    if (yes) store.set('sme-org', id);
    try { sessionStorage.setItem('aifd-in', '1'); } catch (x) {}
    location.reload();
  }
  function inviteScreen() {
    const wrap = screen(`<h1>You're invited</h1><p>Accept to open the workspace. You can belong to several and switch between them.</p>
${invites.map((o) => `<div class="box" style="margin-top:.8rem"><b>${esc(o.name)}</b><br>${o.invited_by ? esc(o.invited_by) + ' added you' : 'You were added'} as ${esc(ROLE_WORD[o.role] || o.role)}.
<div class="row"><button type="button" data-yes="${esc(o.id)}">Accept</button><button class="alt" type="button" data-no="${esc(o.id)}">Decline</button></div></div>`).join('')}
${info.can_create_org && info.mode !== 'single' ? '<button class="sw" type="button" id="sb-own">Set up my own workspace instead</button>' : ''}
<div class="row"><button class="alt" type="button" id="sb-so">Sign out</button></div>`);
    wrap.querySelectorAll('[data-yes]').forEach((b) => b.onclick = () => { b.disabled = true; answer(b.dataset.yes, true); });
    wrap.querySelectorAll('[data-no]').forEach((b) => b.onclick = () => { b.disabled = true; answer(b.dataset.no, false); });
    const own = wrap.querySelector('#sb-own'); if (own) own.onclick = () => { wrap.remove(); companyScreen(); };
    wrap.querySelector('#sb-so').onclick = async () => { await sb.auth.signOut(); setCookie(null); location.reload(); };
  }

  const ready = (async () => {
    const { data } = await sb.auth.getSession();
    session = data.session; setCookie(session);
    if (!session) { await whenDom(); authScreen(); await new Promise(() => {}); }
    if (/[?&]reset\b/.test(location.search)) { await whenDom(); resetScreen(); await new Promise(() => {}); }
    const uid = session.user.id;
    const [i, o, p] = await Promise.all([
      sb.rpc('app_info'),
      sb.rpc('my_orgs'),
      sb.from('profiles').select('full_name,email').eq('id', uid).maybeSingle(),
    ]);
    info = i.data || {}; profile = p.data || null;
    orgs = (o.data || []).filter((x) => !x.invited); invites = (o.data || []).filter((x) => x.invited);
    if (!orgs.length) { await whenDom(); invites.length ? inviteScreen() : companyScreen(); await new Promise(() => {}); }
    const qs = new URLSearchParams(location.search);
    if (qs.get('workspace')) { store.set('sme-org', qs.get('workspace')); qs.delete('workspace'); history.replaceState(null, '', location.pathname + (qs.toString() ? '?' + qs : '') + location.hash); }
    const want = store.get('sme-org');
    org = orgs.find((x) => x.id === want) || orgs[0];
    ORG = org.id; store.set('sme-org', ORG);
    whenDom().then(mountChrome);
    return true;
  })();

  // sign out also ends the Supabase session
  document.addEventListener('click', async (e) => {
    const b = e.target.closest && e.target.closest('#signout,#psignout,.lh-btn');
    if (b && /sign out/i.test(b.textContent || '')) {
      try { sessionStorage.removeItem('aifd-in'); } catch (x) {}
      await sb.auth.signOut(); setCookie(null); location.reload();
    }
  }, true);

  // ---------- db: documents in collections, Firestore-style, inside the current company ----------
  const parentOf = (p) => p.slice(0, p.lastIndexOf('/'));
  const idOf = (p) => p.slice(p.lastIndexOf('/') + 1);
  const rid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now()).replace(/-/g, '').slice(0, 20);
  const clone = (d) => (d == null ? d : JSON.parse(JSON.stringify(d)));
  const snapOf = (id, data) => ({ id, exists: data !== undefined && data !== null, data: () => (data == null ? undefined : clone(data)) });
  const fail = (error, fallback) => {
    let m = (error && error.message) || fallback || 'The database refused the request.';
    if (error && error.code === '42501' && !/plan|owner|workspace/i.test(m)) m = org && !org.writable ? 'This workspace is read-only right now. See Plan and usage.' : 'You do not have permission to change this.';
    const e = new Error(m); e.code = (error && error.code) || 'db_error'; return e;
  };

  const subs = new Map(); // collection -> {map, rows, ls:Set, loaded, ch}
  function emit(s) { const docs = [...s.map.entries()].map(([id, d]) => snapOf(id, d)); s.ls.forEach((l) => { try { l.next({ docs }); } catch (e) { console.error(e); } }); }
  async function load(c, s) {
    const map = new Map(), rows = new Map();
    let from = 0;
    for (;;) {
      const { data, error } = await sb.from('docs').select('id,path,data').eq('scope', ORG + ':' + c).order('path').range(from, from + 999);
      if (error) { s.ls.forEach((l) => l.error && l.error(fail(error))); return; }
      data.forEach((r) => { const id = idOf(r.path); map.set(id, r.data); rows.set(r.id, id); });
      if (data.length < 1000) break; from += 1000;
    }
    s.map = map; s.rows = rows; s.loaded = true; emit(s);
  }
  function watch(c) {
    let s = subs.get(c); if (s) return s;
    s = { map: new Map(), rows: new Map(), ls: new Set(), loaded: false }; subs.set(c, s);
    load(c, s);
    s.ch = sb.channel('docs:' + c + ':' + rid())
      .on('postgres_changes', { event: '*', schema: 'public', table: 'docs', filter: `scope=eq.${ORG}:${c}` }, (p) => {
        if (p.eventType === 'DELETE') {
          const id = p.old && s.rows.get(p.old.id);
          if (!id) return;
          s.map.delete(id); s.rows.delete(p.old.id);
        } else {
          const r = p.new;
          if (!r || r.org_id !== ORG || r.collection !== c) return;
          s.map.set(idOf(r.path), r.data); s.rows.set(r.id, idOf(r.path));
        }
        if (s.loaded) emit(s);
      }).subscribe();
    return s;
  }
  // Safety net: when the tab comes back into view, re-read what is on screen (catches missed deletes).
  let lastSync = Date.now();
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState !== 'visible' || Date.now() - lastSync < 60000) return;
    lastSync = Date.now();
    subs.forEach((s, c) => { if (s.loaded && s.ls.size) load(c, s); });
  });
  function local(path, data) { const s = subs.get(parentOf(path)); if (!s) return; if (data === null) s.map.delete(idOf(path)); else s.map.set(idOf(path), clone(data)); if (s.loaded) emit(s); }
  function listen(c, next, error) { const s = watch(c); const l = { next, error }; s.ls.add(l); if (s.loaded) setTimeout(() => emit(s), 0); return () => s.ls.delete(l); }

  function docRef(path) {
    const c = parentOf(path), id = idOf(path);
    return {
      id, path,
      async get() { const { data, error } = await sb.from('docs').select('data').eq('org_id', ORG).eq('path', path).maybeSingle(); if (error) throw fail(error); return snapOf(id, data ? data.data : null); },
      async set(d) { const data = clone(d); const { error } = await sb.from('docs').upsert({ org_id: ORG, path, collection: c, scope: ORG + ':' + c, data }, { onConflict: 'org_id,path' }); if (error) throw fail(error); local(path, data); },
      async update(patch) { const p = clone(patch); const { error } = await sb.rpc('doc_update', { p_org: ORG, p_path: path, p_patch: p }); if (error) throw fail(error, 'missing ' + path); const s = subs.get(c); if (s && s.map.has(id)) local(path, { ...s.map.get(id), ...p }); },
      async delete() { const { error } = await sb.from('docs').delete().eq('org_id', ORG).eq('path', path); if (error) throw fail(error); local(path, null); },
      onSnapshot(cb, err) { return listen(c, ({ docs }) => { const d = docs.find((x) => x.id === id); cb(d || snapOf(id, null)); }, err); },
      collection: (sub) => coll(path + '/' + sub),
    };
  }
  function coll(c) {
    return {
      path: c,
      doc: (id) => docRef(c + '/' + (id || rid())),
      async add(d) { const r = docRef(c + '/' + rid()); await r.set(d); return { id: r.id }; },
      onSnapshot(cb, err) { return listen(c, cb, err); },
      async get() { const s = watch(c); if (!s.loaded) await new Promise((r) => { const u = listen(c, () => { u(); r(); }); }); return { docs: [...s.map.entries()].map(([id, d]) => snapOf(id, d)) }; },
    };
  }
  const db = Object.freeze({ collection: coll, doc: docRef });

  // ---------- user ----------
  const role = () => (org && org.role) || null;
  const isEd = () => ['owner', 'staff', 'viewer'].includes(role());
  const user = Object.freeze({
    id: async () => session.user.id,
    me: async () => ({ id: session.user.id, name: (profile && profile.full_name) || session.user.email, email: session.user.email }),
    canEdit: async () => isEd(),
    isOwner: async () => role() === 'owner',
    can: async (n) => (n === 'data.write' ? !!(org && org.writable) && role() !== 'viewer' : null),
    name: async () => (profile && profile.full_name) || (session.user.email || '').split('@')[0],
    profiles: async (ids) => {
      const out = {}; const list = (ids || []).filter((x) => /^[0-9a-f-]{36}$/i.test(x)); if (!list.length) return out;
      const { data } = await sb.rpc('org_profiles', { p_org: ORG, p_ids: list });
      (data || []).forEach((p) => { out[p.id] = { name: p.name || '', email: p.email || undefined }; });
      return out;
    },
    search: async (q) => {
      const { data } = await sb.rpc('people_search', { p_org: ORG, p_q: q || '' });
      return (data || []).map((p) => ({ id: p.id, name: p.name || p.email, email: p.email }));
    },
  });

  // ---------- sample: Claude through /api/ai ----------
  const blobToB64 = (b) => new Promise((res, rej) => { const fr = new FileReader(); fr.onload = () => res(String(fr.result).split(',')[1]); fr.onerror = rej; fr.readAsDataURL(b); });
  async function callAI(body, signal) {
    const { data } = await sb.auth.getSession();
    const r = await fetch('/api/ai', { method: 'POST', signal, headers: { 'content-type': 'application/json', 'x-org': ORG, authorization: 'Bearer ' + (data.session && data.session.access_token) }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) {
      const e = new Error((j.error && j.error.message) || j.message || 'The AI service did not answer.');
      e.code = r.status === 429 ? 'rate_limited' : r.status === 402 ? 'quota_exceeded' : r.status === 401 || r.status === 403 || r.status === 503 ? 'not_granted' : 'sample_error';
      throw e;
    }
    return j;
  }
  async function sample(input, opts) {
    opts = opts || {};
    let messages = typeof input === 'string' ? [{ role: 'user', content: input }] : (input || []).map((m) => ({ role: m.role, content: m.content }));
    if (opts.images && opts.images.length) {
      const last = messages[messages.length - 1];
      const imgs = [];
      for (const b of opts.images.slice(0, 10)) imgs.push({ type: 'image', source: { type: 'base64', media_type: b.type && /^image\//.test(b.type) ? b.type : 'image/png', data: await blobToB64(b) } });
      last.content = [...imgs, { type: 'text', text: typeof last.content === 'string' ? last.content : '' }];
    }
    const tools = (opts.tools || []).map((t) => ({ name: t.name, description: t.description || '', input_schema: t.inputSchema || { type: 'object', properties: {} } }));
    let text = '';
    for (let turn = 0; turn < 8; turn++) {
      const res = await callAI({ messages, tools: tools.length ? tools : undefined, tier: opts.modelTier || 'default' }, opts.signal);
      const blocks = res.content || [];
      text = blocks.filter((b) => b.type === 'text').map((b) => b.text).join('');
      if (opts.onText && text) { try { opts.onText({ text, delta: text }); } catch (e) {} }
      const uses = blocks.filter((b) => b.type === 'tool_use');
      if (res.stop_reason !== 'tool_use' || !uses.length) return { text, truncated: res.stop_reason === 'max_tokens' };
      messages = [...messages, { role: 'assistant', content: blocks }];
      const results = [];
      for (const u of uses) {
        const t = (opts.tools || []).find((x) => x.name === u.name);
        let out, isErr = false;
        try { out = t ? await t.execute(u.input || {}) : { error: 'unknown tool' }; } catch (e) { out = { error: String(e && e.message || e) }; isErr = true; }
        let s = typeof out === 'string' ? out : JSON.stringify(out); if (s.length > 60000) s = s.slice(0, 60000) + '…';
        results.push({ type: 'tool_result', tool_use_id: u.id, content: s, is_error: isErr || undefined });
      }
      messages = [...messages, { role: 'user', content: results }];
    }
    return { text, truncated: true };
  }
  sample.json = async (input, opts) => {
    const r = await sample(input, opts);
    let t = r.text.trim().replace(/^```(?:json)?\s*/i, '').replace(/```\s*$/, '');
    try { return JSON.parse(t); } catch (e) {}
    const a = t.search(/[\[{]/); const b = Math.max(t.lastIndexOf('}'), t.lastIndexOf(']'));
    if (a >= 0 && b > a) { try { return JSON.parse(t.slice(a, b + 1)); } catch (e) {} }
    const err = new Error('The AI answer was not valid JSON.'); err.code = 'bad_json'; err.text = r.text; throw err;
  };
  sample.limits = async () => ({ images: { maxCount: 10 } });

  // ---------- assets: private storage per company, served through /_blob/<id> ----------
  const assets = Object.freeze({
    async upload(blob) {
      if (blob.size > 20 * 1024 * 1024) { const e = new Error('Files are limited to 20 MB.'); e.code = 'too_large'; throw e; }
      const id = rid(); const contentType = blob.type || 'application/octet-stream';
      const { error } = await sb.storage.from('assets').upload(ORG + '/' + id, blob, { contentType, upsert: false });
      if (error) throw fail(error, 'Upload failed. Your plan\'s storage may be full — see Plan and usage.');
      return { id, url: '/_blob/' + id, sizeBytes: blob.size, contentType };
    },
    async delete(id) { const { error } = await sb.storage.from('assets').remove([ORG + '/' + id]); if (error) throw fail(error); },
    async list() {
      const { data } = await sb.storage.from('assets').list(ORG, { limit: 1000 });
      return { assets: (data || []).map((f) => ({ id: f.name, url: '/_blob/' + f.name, sizeBytes: f.metadata && f.metadata.size })), usage: {} };
    },
  });

  // ---------- downloads ----------
  const downloads = Object.freeze({
    async save({ filename, data }) {
      const blob = data instanceof Blob ? data : new Blob([data], { type: /\.pdf$/i.test(filename) ? 'application/pdf' : /\.xlsx$/i.test(filename) ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' : 'application/octet-stream' });
      const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = filename; document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 10000);
    },
  });

  // ---------- company switcher, plan and usage, notices ----------
  const DAY = 864e5;
  const trialLeft = () => (org && org.status === 'trial' && org.trial_ends_at ? Math.ceil((Date.parse(org.trial_ends_at) - Date.now()) / DAY) : null);
  const ROLE_NAME = { owner: 'Owner', staff: 'Team', viewer: 'Read-only', portal: 'Portal' };
  const fmtLim = (v) => (v == null ? 'Unlimited' : Number(v).toLocaleString());
  const contact = (subject) => info.support_email
    ? `<a class="sx-btn primary" href="mailto:${esc(info.support_email)}?subject=${encodeURIComponent(subject + ' — ' + (org ? org.name : ''))}">Contact us</a>` : '';

  function chromeCss() {
    const st = document.createElement('style');
    st.textContent = `
#sx-co{display:inline-flex;align-items:center;gap:.4rem;max-width:16rem;appearance:none;border:1px solid var(--line,#E3E6EA);background:var(--panel,#fff);color:var(--ink,#1E242C);border-radius:999px;padding:.32rem .7rem;font:inherit;font-size:.85rem;cursor:pointer;white-space:nowrap}
#sx-co .n{overflow:hidden;text-overflow:ellipsis}#sx-co .t{font-size:.75rem;padding:.08rem .45rem;border-radius:999px;background:var(--blue-soft,#E8EFFC);color:var(--blue,#1F5FD6)}
#sx-co .t.warn{background:var(--blush,#FDF1F6);color:var(--pink,#D9488A)}
#sx-co svg{width:.8rem;height:.8rem;stroke:currentColor;fill:none;stroke-width:2}
#sx-pan{position:fixed;z-index:60;top:3.6rem;right:clamp(.6rem,2vw,1.5rem);width:min(25rem,calc(100vw - 1.2rem));max-height:calc(100vh - 5rem);overflow:auto;background:var(--panel,#fff);color:var(--ink,#1E242C);border:1px solid var(--line,#E3E6EA);border-radius:14px;box-shadow:0 24px 60px -20px rgba(0,0,0,.35);padding:1rem;font-size:.9rem}
#sx-pan h3{font-size:.78rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted,#5F6874);margin:1rem 0 .5rem;font-weight:500}#sx-pan h3:first-child{margin-top:0}
#sx-pan .co{display:flex;justify-content:space-between;align-items:center;gap:.5rem;width:100%;text-align:left;border:1px solid var(--line,#E3E6EA);background:none;color:inherit;font:inherit;border-radius:10px;padding:.55rem .7rem;margin-bottom:.4rem;cursor:pointer}
#sx-pan .co.on{border-color:var(--blue,#1F5FD6);box-shadow:inset 0 0 0 1px var(--blue,#1F5FD6)}#sx-pan .co small{color:var(--muted,#5F6874)}
#sx-pan .m{margin:.55rem 0}#sx-pan .m div{display:flex;justify-content:space-between;font-size:.85rem}#sx-pan .m div span:last-child{color:var(--muted,#5F6874)}
#sx-pan .bar{height:6px;border-radius:99px;background:var(--sunk,#F2F4F6);margin-top:.3rem;overflow:hidden}#sx-pan .bar i{display:block;height:100%;background:var(--teal,#0E968C);border-radius:99px}#sx-pan .bar i.hi{background:var(--pink,#D9488A)}
#sx-pan table{width:100%;border-collapse:collapse;font-size:.8rem}#sx-pan th,#sx-pan td{padding:.35rem .3rem;border-bottom:1px solid var(--line,#E3E6EA);text-align:right}#sx-pan th:first-child,#sx-pan td:first-child{text-align:left;color:var(--muted,#5F6874)}#sx-pan th.cur{color:var(--blue,#1F5FD6)}
#sx-pan #sx-new{margin:.2rem 0 .3rem}#sx-pan .note{color:var(--muted,#5F6874);font-size:.82rem;margin:.4rem 0}#sx-pan .acts{display:flex;flex-wrap:wrap;gap:.5rem;margin-top:.8rem}
.sx-btn{display:inline-block;appearance:none;border:1px solid var(--line,#E3E6EA);background:var(--panel,#fff);color:var(--ink,#1E242C);border-radius:9px;padding:.42rem .75rem;font:inherit;font-size:.85rem;cursor:pointer;text-decoration:none}
.sx-btn.primary{background:var(--blue,#1F5FD6);border-color:transparent;color:#fff}
#sx-ro{position:fixed;z-index:55;left:50%;bottom:1rem;transform:translateX(-50%);width:min(40rem,calc(100vw - 2rem));display:flex;gap:.8rem;align-items:center;background:var(--ink,#1E242C);color:var(--bg,#fff);border-radius:12px;padding:.7rem .9rem;font-size:.9rem;box-shadow:0 18px 40px -16px rgba(0,0,0,.5)}
#sx-ro span{flex:1}#sx-ro button{appearance:none;border:0;background:none;color:inherit;font:inherit;cursor:pointer;opacity:.8}#sx-ro button.go{background:var(--bg,#fff);color:var(--ink,#1E242C);border-radius:8px;padding:.3rem .65rem;opacity:1}
#sx-co{margin-right:.5rem}#sx-co.inline{margin-left:auto;margin-right:.75rem}#sx-co.hub{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.14);color:#fff;border-radius:12px;padding:.5rem .8rem}#sx-co.hub:hover{background:rgba(255,255,255,.14)}
#sx-co.hub .t{background:rgba(255,255,255,.16);color:#fff}#sx-co.hub .t.warn{background:#F4A6C8;color:#3A1426}
@media (max-width:640px){#sx-co .n{max-width:7rem}}`;
    document.head.append(st);
  }

  function badge() {
    const left = trialLeft();
    if (!org.writable) return '<span class="t warn">Read-only</span>';
    if (left != null) return `<span class="t${left <= 3 ? ' warn' : ''}">Trial · ${left <= 0 ? 'ends today' : left + 'd left'}</span>`;
    return '';
  }

  function mountChrome() {
    chromeCss();
    const btn = document.createElement('button');
    btn.type = 'button'; btn.id = 'sx-co'; btn.title = 'Workspaces, plan and usage';
    btn.innerHTML = `<span class="n">${esc(org.name)}</span>${badge()}${invites.length ? '<span class="t warn" title="Invitations waiting">' + invites.length + ' invite' + (invites.length > 1 ? 's' : '') + '</span>' : ''}<svg viewBox="0 0 24 24"><path d="M6 9l6 6 6-6"/></svg>`;
    btn.onclick = (e) => { e.stopPropagation(); togglePanel(); };
    const shown = (el) => !!el && el.offsetParent !== null;
    // Top bar when it is showing; otherwise next to whichever "Sign out" button is on screen
    // (home hub, setup wizard, portal).
    const place = () => {
      const bar = document.querySelector('.topbar .tright');
      if (shown(bar)) { btn.classList.remove('hub', 'inline'); if (bar.firstChild !== btn) bar.prepend(btn); return; }
      const out = [...document.querySelectorAll('button, a')].find((x) => x.id !== 'signout' && x !== btn && /^\s*sign out\s*$/i.test(x.textContent || '') && shown(x));
      if (!out) return;
      const hub = !!out.closest('.lh-acts');
      btn.classList.toggle('hub', hub); btn.classList.toggle('inline', !hub);
      if (btn.nextSibling !== out) out.before(btn);
    };
    let queued = false;
    const later = () => { if (queued) return; queued = true; requestAnimationFrame(() => { queued = false; place(); }); };
    place();
    new MutationObserver(later).observe(document.body, { attributes: true, childList: true, subtree: true, attributeFilter: ['hidden'] });
    document.addEventListener('click', (e) => { const p = document.getElementById('sx-pan'); if (p && !p.contains(e.target)) p.remove(); });
    readOnlyNotice();
  }

  function readOnlyNotice() {
    if (org.writable || store.get('sx-ro-' + ORG) === new Date().toISOString().slice(0, 10)) return;
    const why = org.status === 'suspended' ? 'This workspace is suspended, so it is read-only.'
      : org.status === 'trial' ? 'Your free trial has ended, so this workspace is read-only. Your data is safe.'
      : 'This workspace is read-only.';
    const bar = document.createElement('div'); bar.id = 'sx-ro'; bar.setAttribute('role', 'status');
    bar.innerHTML = `<span>${why}</span><button type="button" class="go">Plan and usage</button><button type="button" aria-label="Dismiss">✕</button>`;
    const [go, x] = bar.querySelectorAll('button');
    go.onclick = (e) => { e.stopPropagation(); togglePanel(); };
    x.onclick = () => { store.set('sx-ro-' + ORG, new Date().toISOString().slice(0, 10)); bar.remove(); };
    document.body.append(bar);
  }

  async function togglePanel() {
    const old = document.getElementById('sx-pan'); if (old) { old.remove(); return; }
    const pan = document.createElement('div'); pan.id = 'sx-pan'; pan.setAttribute('role', 'dialog'); pan.setAttribute('aria-label', 'Workspaces, plan and usage');
    pan.onclick = (e) => e.stopPropagation();
    const list = orgs.map((o) => `<button type="button" class="co${o.id === ORG ? ' on' : ''}" data-id="${esc(o.id)}"><span>${esc(o.name)}<br><small>${esc(ROLE_NAME[o.role] || o.role)} · ${esc(o.plan_name)}${o.writable ? '' : ' · read-only'}</small></span>${o.id === ORG ? '<small>Current</small>' : '<small>Switch</small>'}</button>`).join('');
    const inv = invites.map((o) => `<div class="co"><span>${esc(o.name)}<br><small>${o.invited_by ? esc(o.invited_by) + ' invited you' : 'Invitation'} · ${esc(ROLE_NAME[o.role] || o.role)}</small></span><span style="display:flex;gap:.35rem"><button type="button" class="sx-btn primary" data-yes="${esc(o.id)}">Accept</button><button type="button" class="sx-btn" data-no="${esc(o.id)}">Decline</button></span></div>`).join('');
    pan.innerHTML = `${inv ? '<h3>Invitations</h3>' + inv : ''}<h3>Workspaces</h3>${list}
${info.can_create_org && info.mode !== 'single' ? '<button type="button" class="sx-btn" id="sx-new">+ Add a workspace</button>' : ''}
<div id="sx-use"><h3>Plan and usage</h3><p class="note">Loading…</p></div>
<div class="acts">${role() === 'owner' ? '<button type="button" class="sx-btn" id="sx-ren">Rename workspace</button>' : ''}${info.is_platform_admin ? '<a class="sx-btn" href="/admin">Platform admin</a>' : ''}</div>`;
    document.body.append(pan);
    pan.querySelectorAll('[data-yes]').forEach((b) => b.onclick = () => answer(b.dataset.yes, true));
    pan.querySelectorAll('[data-no]').forEach((b) => b.onclick = () => answer(b.dataset.no, false));
    pan.querySelectorAll('button.co').forEach((b) => b.onclick = () => { if (b.dataset.id === ORG) return; store.set('sme-org', b.dataset.id); location.reload(); });
    const nw = pan.querySelector('#sx-new'); if (nw) nw.onclick = () => { pan.remove(); companyScreen({ another: true }); };
    const rn = pan.querySelector('#sx-ren'); if (rn) rn.onclick = async () => {
      const n = prompt('Workspace name', org.name); if (!n || n.trim() === org.name) return;
      const r = await sb.rpc('rename_org', { p_org: ORG, p_name: n.trim() }); if (r.error) { alert(r.error.message); return; } location.reload();
    };
    if (role() === 'portal') { pan.querySelector('#sx-use').remove(); return; }
    const { data: u, error } = await sb.rpc('org_usage', { p_org: ORG });
    const box = pan.querySelector('#sx-use'); if (!box) return;
    if (error || !u) { box.innerHTML = '<h3>Plan and usage</h3><p class="note">Could not load usage.</p>'; return; }
    const meter = (label, used, lim, unit) => {
      const pct = lim == null ? 0 : Math.min(100, Math.round((used / Math.max(lim, 1)) * 100));
      return `<div class="m"><div><span>${label}</span><span>${Number(used).toLocaleString()}${unit || ''} of ${fmtLim(lim)}${lim != null && unit ? unit : ''}</span></div>${lim == null ? '' : `<div class="bar"><i class="${pct >= 85 ? 'hi' : ''}" style="width:${pct}%"></i></div>`}</div>`;
    };
    const left = trialLeft();
    const status = u.status === 'trial' ? (left > 0 ? `${left} day${left === 1 ? '' : 's'} left` : 'ended — read-only') : u.status === 'active' ? 'Active' : u.status === 'past_due' ? 'Payment overdue' : u.status === 'suspended' ? 'Suspended' : u.status;
    const plans = (u.plans || []);
    const row = (label, k, unit) => `<tr><td>${label}</td>${plans.map((p) => `<td>${p[k] == null ? '∞' : Number(p[k]).toLocaleString() + (unit || '')}</td>`).join('')}</tr>`;
    box.innerHTML = `<h3>Plan and usage</h3>
<p><b>${esc(u.plan_name)}</b> · ${esc(status)}</p>
${meter('Team logins', u.staff.used, u.staff.limit)}
${meter('Employee, customer and supplier logins', u.portal.used, u.portal.limit)}
${meter('Entities', u.entities.used, u.entities.limit)}
${meter('AI agent calls this month', u.ai.used, u.ai.limit)}
${u.ai_tokens ? meter('AI allowance this month (thousand tokens)', Math.round(u.ai_tokens.used / 1000), u.ai_tokens.limit == null ? null : Math.round(u.ai_tokens.limit / 1000)) : ''}
${u.records ? meter('Records', u.records.used_mb, u.records.limit, ' MB') : ''}
${meter('File storage', u.storage.used_mb, u.storage.limit, ' MB')}
${plans.length ? `<h3>Plans</h3><table><tr><th></th>${plans.map((p) => `<th class="${p.id === u.plan ? 'cur' : ''}">${esc(p.name)}</th>`).join('')}</tr>
${plans.some((p) => p.price_month != null) ? `<tr><td>Per month</td>${plans.map((p) => `<td>${p.price_month == null ? '—' : esc(p.currency) + ' ' + Number(p.price_month).toLocaleString()}</td>`).join('')}</tr>` : ''}
${row('Team logins', 'max_staff')}${row('Portal logins', 'max_portal')}${row('Entities', 'max_entities')}${row('AI calls / month', 'ai_calls_month')}${row('Records (GB)', 'data_mb')}${row('Storage (GB)', 'storage_mb')}</table>` : ''}
${role() === 'owner' ? `<p class="note">To ${u.status === 'trial' ? 'continue after your trial or ' : ''}change plan, get in touch.</p><div class="acts">${contact('Plan change')}</div>` : '<p class="note">The workspace owner can change the plan.</p>'}`;
    // storage row is stored in MB; show GB in the comparison
    box.querySelectorAll('table tr').forEach((tr) => { if (/Storage|Records/.test(tr.firstChild.textContent)) tr.querySelectorAll('td:not(:first-child)').forEach((td) => { const n = Number(td.textContent.replace(/,/g, '')); if (!isNaN(n)) td.textContent = (n / 1024).toLocaleString(undefined, { maximumFractionDigits: 1 }); }); });
  }

  const NS = { db, user, sample, assets, downloads };
  window.claude = Object.freeze({
    use: async (name) => {
      await ready;
      if (name === 'assets' && !['owner', 'staff'].includes(role())) return null;
      return NS[name] || null;
    },
  });
})();
