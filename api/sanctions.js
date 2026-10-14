// Refreshes the official sanctions lists used for AML name screening (Vercel Cron, daily; or the platform admin).
// Free official sources: UN Security Council consolidated list, US OFAC SDN (with aliases), UK Sanctions List (FCDO),
// EU consolidated financial sanctions. The UAE Local Terrorist List is published by the EOCN (uaeiec.gov.ae) as Excel/PDF
// without a stable file address: set UAE_LOCAL_LIST_URL to a CSV export, or upload it in Compliance → Screening.
const { admin } = require('./_auth');
const SOURCES = {
  un: { title: 'UN Security Council Consolidated List', url: 'https://scsanctions.un.org/resources/xml/en/consolidated.xml' },
  ofac: { title: 'US OFAC SDN List', url: 'https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/SDN.CSV', alt: 'https://sanctionslistservice.ofac.treas.gov/api/PublicationPreview/exports/ALT.CSV' },
  uk: { title: 'UK Sanctions List (FCDO)', url: 'https://sanctionslist.fcdo.gov.uk/docs/UK-Sanctions-List.csv' },
  eu: { title: 'EU Consolidated Financial Sanctions', url: 'https://webgate.ec.europa.eu/fsd/fsf/public/files/csvFullSanctionsList_1_1/content?token=dG9rZW4tMjAxNw' },
};
const norm = (t) => String(t || '').normalize('NFKD').replace(/[̀-ͯ]/g, '').toLowerCase()
  .replace(/\b(llc|l\.l\.c|ltd|limited|co|company|inc|fze|fzco|fz|est|establishment|trading|group|holding|holdings|the|mr|mrs|ms|dr|al|el|bin|ibn|abu)\b|[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
function csv(text, sep) {
  const rows = []; let row = [], f = '', q = false;
  for (let i = 0; i < text.length; i++) { const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true; else if (c === sep) { row.push(f); f = ''; } else if (c === '\n') { row.push(f.replace(/\r$/, '')); rows.push(row); row = []; f = ''; } else f += c; }
  if (f || row.length) { row.push(f); rows.push(row); } return rows;
}
const tag = (x, t) => { const m = x.match(new RegExp(`<${t}>([\\s\\S]*?)</${t}>`)); return m ? m[1].replace(/<!\[CDATA\[|\]\]>/g, '').trim() : ''; };
function parseUN(xml) {
  const out = [];
  for (const [k, re] of [['individual', /<INDIVIDUAL>([\s\S]*?)<\/INDIVIDUAL>/g], ['entity', /<ENTITY>([\s\S]*?)<\/ENTITY>/g]]) {
    let m; while ((m = re.exec(xml))) { const x = m[1]; const name = ['FIRST_NAME', 'SECOND_NAME', 'THIRD_NAME', 'FOURTH_NAME'].map((t) => tag(x, t)).filter(Boolean).join(' ');
      const base = { source: 'un', ext_id: tag(x, 'REFERENCE_NUMBER'), kind: k, program: tag(x, 'UN_LIST_TYPE'), listed_on: tag(x, 'LISTED_ON'), country: tag(x, 'NATIONALITY').replace(/<[^>]+>/g, ' ').trim().slice(0, 80) };
      if (name) out.push({ ...base, name });
      const al = /<(?:INDIVIDUAL|ENTITY)_ALIAS>([\s\S]*?)<\/(?:INDIVIDUAL|ENTITY)_ALIAS>/g; let a; while ((a = al.exec(x))) { const n = tag(a[1], 'ALIAS_NAME'); if (n) out.push({ ...base, name: n, extra: 'alias' }); } } }
  return out;
}
function parseOFAC(main, alt) {
  const out = []; const names = {};
  csv(main, ',').forEach((r) => { if (r.length < 4 || !/^\d+$/.test((r[0] || '').trim())) return; const n = r[1].trim(); names[r[0].trim()] = r; out.push({ source: 'ofac', ext_id: r[0].trim(), name: n, kind: (r[2] || '').trim().replace(/^-0-$/, '') || 'entity', program: (r[3] || '').trim(), extra: (r[11] || '').slice(0, 300) }); });
  if (alt) csv(alt, ',').forEach((r) => { if (r.length < 4 || !names[(r[0] || '').trim()]) return; const b = names[r[0].trim()]; out.push({ source: 'ofac', ext_id: r[0].trim(), name: r[3].trim(), kind: (b[2] || '').trim().replace(/^-0-$/, '') || 'entity', program: (b[3] || '').trim(), extra: 'alias' }); });
  return out;
}
function parseGenericCSV(text, source) {
  const sep = (text.split('\n')[0].match(/;/g) || []).length > (text.split('\n')[0].match(/,/g) || []).length ? ';' : ',';
  const rows = csv(text, sep); const hi = rows.findIndex((r) => r.some((c) => /name/i.test(c))); if (hi < 0) return [];
  const H = rows[hi].map((c) => c.trim()); const idx = (re) => H.findIndex((c) => re.test(c));
  const whole = idx(/^(NameAlias_WholeName|Name\s*Full|Full\s*Name|Name)$/i); const parts = H.map((c, i) => (/^Name\s*[1-6]$/i.test(c) ? i : -1)).filter((i) => i >= 0);
  const typeI = idx(/type|subject/i), progI = idx(/regime|programme|program/i), idI = idx(/^(unique id|group id|logical_id|Entity_LogicalId|ofsi group id|id)$/i), dateI = idx(/^(?!.*generation).*(designat|listed|date)/i), ctryI = idx(/nationality|country|citizen/i);
  const out = [];
  rows.slice(hi + 1).forEach((r) => { let name = whole >= 0 ? r[whole] : ''; if (!name && parts.length) { const ps = parts.map((i) => ({ k: H[i], v: (r[i] || '').trim() })).filter((x) => x.v); const last = ps.find((x) => /6$/.test(x.k)); name = [...ps.filter((x) => !/6$/.test(x.k)).map((x) => x.v), last ? last.v : ''].filter(Boolean).join(' '); }
    name = String(name || '').trim(); if (!name || name.length < 3) return;
    out.push({ source, ext_id: idI >= 0 ? (r[idI] || '').trim() : null, name, kind: typeI >= 0 ? (r[typeI] || '').trim().toLowerCase() : null, program: progI >= 0 ? (r[progI] || '').trim().slice(0, 200) : null, listed_on: dateI >= 0 ? (r[dateI] || '').trim() : null, country: ctryI >= 0 ? (r[ctryI] || '').trim().slice(0, 80) : null }); });
  return out;
}
async function get(url) { const r = await fetch(url, { headers: { 'user-agent': 'Orzio-AML-Screening/1.0' } }); if (!r.ok) throw new Error(`${url} answered ${r.status}`); return r.text(); }
async function store(sb, source, rows, meta) {
  const seen = new Set(); rows = rows.filter((r) => { const k = norm(r.name) + '|' + (r.ext_id || ''); if (!r.name || seen.has(k)) return false; seen.add(k); return true; }).map((r) => ({ ...r, name: r.name.slice(0, 300), name_norm: norm(r.name).slice(0, 300) })).filter((r) => r.name_norm.length >= 3);
  if (rows.length < 10) throw new Error(`only ${rows.length} names parsed; the file format may have changed`);
  await sb.from('sanctions_entries').delete().eq('source', source);
  for (let i = 0; i < rows.length; i += 1000) { const { error } = await sb.from('sanctions_entries').insert(rows.slice(i, i + 1000)); if (error) throw new Error(error.message); }
  await sb.from('sanctions_sources').upsert({ source, title: meta.title, url: meta.url, fetched_at: new Date().toISOString(), entries: rows.length, status: 'ok', note: null });
  return rows.length;
}
module.exports = async (req, res) => {
  const sb = admin(); const auth = String(req.headers.authorization || '');
  let allowed = !!process.env.CRON_SECRET && auth === 'Bearer ' + process.env.CRON_SECRET;
  if (!allowed && auth.startsWith('Bearer ')) { const { data } = await sb.auth.getUser(auth.slice(7)); if (data && data.user) { const { data: pa } = await sb.from('platform_admins').select('user_id').eq('user_id', data.user.id).maybeSingle(); allowed = !!pa; } }
  if (!allowed) return res.status(401).json({ error: 'Not allowed' });
  const out = {};
  const run = async (k, fn) => { try { out[k] = await fn(); } catch (e) { out[k] = 'failed: ' + e.message; await sb.from('sanctions_sources').upsert({ source: k, title: (SOURCES[k] || {}).title || k, url: (SOURCES[k] || {}).url || process.env.UAE_LOCAL_LIST_URL, status: 'failed', note: String(e.message).slice(0, 300) }); } };
  await run('un', async () => store(sb, 'un', parseUN(await get(SOURCES.un.url)), SOURCES.un));
  await run('ofac', async () => { const main = await get(SOURCES.ofac.url); let alt = ''; try { alt = await get(SOURCES.ofac.alt); } catch (e) { /* aliases optional */ } return store(sb, 'ofac', parseOFAC(main, alt), SOURCES.ofac); });
  await run('uk', async () => store(sb, 'uk', parseGenericCSV(await get(SOURCES.uk.url), 'uk'), SOURCES.uk));
  await run('eu', async () => store(sb, 'eu', parseGenericCSV(await get(SOURCES.eu.url), 'eu'), SOURCES.eu));
  if (process.env.UAE_LOCAL_LIST_URL) await run('uae', async () => store(sb, 'uae', parseGenericCSV(await get(process.env.UAE_LOCAL_LIST_URL), 'uae'), { title: 'UAE Local Terrorist List', url: process.env.UAE_LOCAL_LIST_URL }));
  return res.status(200).json(out);
};
module.exports.parse = { parseUN, parseOFAC, parseGenericCSV, norm };
