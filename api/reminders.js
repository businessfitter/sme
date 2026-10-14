// Daily payment reminders (Vercel Cron calls this; see vercel.json). Needs CRON_SECRET, RESEND_API_KEY and EMAIL_FROM.
// For every active workspace and company with reminders switched on, it emails customers about invoices that are
// due soon, due today or overdue, once per stage, and records each reminder so the team sees it in Sales.
const { admin } = require('./_auth');
const { sendMail, EMAIL, htmlMail } = require('./_mail');
const day = (d) => new Date(d + 'T00:00:00Z').getTime();
module.exports = async (req, res) => {
  const secret = process.env.CRON_SECRET;
  if (!secret || String(req.headers.authorization || '') !== 'Bearer ' + secret) return res.status(401).json({ error: 'Not allowed' });
  const sb = admin(); const today = new Date().toISOString().slice(0, 10); const out = { sent: 0, skipped: 0, orgs: 0 };
  const { data: orgs } = await sb.from('orgs').select('id,status').in('status', ['active', 'trial', 'past_due']);
  for (const o of orgs || []) {
    out.orgs++;
    const get = async (col) => { const { data } = await sb.from('docs').select('path,data').eq('org_id', o.id).eq('collection', col).limit(20000); return (data || []).map((r) => ({ id: r.path.split('/').pop(), ...r.data })); };
    const ents = await get('setup/main/entities'); const cfgs = {}; ents.forEach((e) => { if (e.reminders && e.reminders.enabled) cfgs[e.id] = e; });
    if (!Object.keys(cfgs).length) continue;
    const [invs, moves, partners, sent] = await Promise.all([get('invoices'), get('moves'), get('partners'), get('reminders')]);
    const paid = {}; moves.filter((m) => m.state === 'posted').forEach((m) => (m.settles || []).forEach((x) => { paid[x.invoice_id] = (paid[x.invoice_id] || 0) + (+x.amount || 0); }));
    const done = new Set(sent.map((r) => r.id));
    for (const inv of invs) {
      const ent = cfgs[inv.entity || 'main']; if (!ent || inv.kind !== 'customer' || inv.status === 'cancelled' || !inv.due) continue;
      const due = Math.round(((+inv.total_base || 0) - (paid[inv.id] || 0)) * 100) / 100; if (due <= 0.01) continue;
      const R = ent.reminders; const diff = Math.round((day(inv.due) - day(today)) / 864e5);
      let stage = null;
      if (diff === +(R.before || 3)) stage = 'before'; else if (diff === 0 && R.on_due !== false) stage = 'due';
      else if (diff < 0) { const late = -diff; const steps = (R.after || [7, 14, 30]).map(Number).filter((x) => x <= late); if (steps.length) stage = 'after' + Math.max(...steps); }
      if (!stage) continue; const rid = `${inv.id}-${stage}`; if (done.has(rid)) continue;
      const p = partners.find((x) => x.kind === 'customer' && (x.entity || 'main') === (inv.entity || 'main') && String(x.name || '').trim().toLowerCase() === String(inv.partner || '').trim().toLowerCase());
      const to = p && (p.billing_email || p.email); if (!to || !EMAIL.test(to)) { out.skipped++; continue; }
      const cur = inv.currency || ent.currency || ''; const amt = `${cur} ${due.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
      const subject = stage === 'before' ? `Invoice ${inv.number} is due on ${inv.due}` : stage === 'due' ? `Invoice ${inv.number} is due today` : `Invoice ${inv.number} is overdue`;
      const text = `Dear ${inv.partner},\n\n${stage === 'before' ? `This is a friendly reminder that invoice ${inv.number} for ${amt} is due on ${inv.due}.` : stage === 'due' ? `Invoice ${inv.number} for ${amt} is due today.` : `Invoice ${inv.number} for ${amt} was due on ${inv.due} and is now ${-diff} days overdue.`}\n\nYou can pay by bank transfer, cheque or the payment link, and mark it as paid with your proof of payment in your customer portal.${ent.brand && ent.brand.iban ? `\n\nBank: ${ent.brand.bank || ''} · IBAN ${ent.brand.iban}${ent.brand.swift ? ' · SWIFT ' + ent.brand.swift : ''}` : ''}\n\nThank you,\n${ent.name || ''}`;
      const { data: ok } = await sb.rpc('email_gate', { p_org: o.id, p_user: null, p_kind: 'reminder', p_to: to }); if (!ok) break;
      const link = (ent.brand && /^https:\/\//.test(ent.brand.pay_link || '')) ? ent.brand.pay_link : (process.env.APP_URL ? process.env.APP_URL.replace(/\/$/, '') + '/' : '');
      const r = await sendMail({ to, subject, text, html: htmlMail(subject, text, link, link === (ent.brand && ent.brand.pay_link) ? 'Pay now' : 'Open your customer portal', ent.name), replyTo: ent.email && EMAIL.test(ent.email) ? ent.email : undefined });
      if (r.sent) { out.sent++; await sb.from('docs').upsert({ org_id: o.id, path: 'reminders/' + rid, collection: 'reminders', scope: o.id + ':reminders', data: { entity: inv.entity || 'main', invoice_id: inv.id, number: inv.number, partner: inv.partner, stage, amount: due, to, at: new Date().toISOString(), by: 'agent:collections' } }, { onConflict: 'org_id,path' }); }
    }
  }
  // compliance alerts: licences, obligations and UBO filings → CEO, Compliance Manager, assigned owner
  out.compliance = 0;
  for (const o of orgs || []) {
    const get = async (col) => { const { data } = await sb.from('docs').select('path,data').eq('org_id', o.id).eq('collection', col).limit(20000); return (data || []).map((r) => ({ id: r.path.split('/').pop(), ...r.data })); };
    const [ents, docsC, laws, access, sent] = await Promise.all([get('setup/main/entities'), get('comp_docs'), get('laws'), get('setup/main/access'), get('reminders')]);
    if (!docsC.length && !laws.length && !ents.some((e) => e.ubo)) continue;
    const done = new Set(sent.map((r) => r.id));
    const { data: owners } = await sb.from('members').select('user_id').eq('org_id', o.id).eq('role', 'owner');
    const roleUids = (r) => access.filter((a) => a.role === r).map((a) => a.id);
    const stage = (d) => { if (!d) return null; const n = Math.round((day(d) - day(today)) / 864e5); return n < 0 ? (n === -1 || n % 7 === 0 ? 'overdue' + (-n) : null) : n === 0 ? 'today' : [7, 30, 60].includes(n) ? String(n) : null; };
    const alerts = [];
    docsC.forEach((d) => { const s = stage(d.expiry); if (s) alerts.push({ ent: d.entity, key: `doc-${d.key}-${d.expiry}-${s}`, what: `${d.name} ${s.startsWith('overdue') ? 'expired on' : 'expires on'} ${d.expiry}`, owner: d.owner }); });
    laws.forEach((L) => (L.laws || []).forEach((l) => (l.obligations || []).forEach((ob) => { const s = stage(ob.next_due); if (s && s !== '60') alerts.push({ ent: L.entity || L.id, key: `ob-${l.id}-${String(ob.what).slice(0, 30)}-${ob.next_due}-${s}`, what: `${ob.what} (${l.name}) ${s.startsWith('overdue') ? 'was due' : 'is due'} ${ob.next_due}`, owner: ob.owner }); })));
    ents.forEach((e) => ((e.ubo || {}).ubos || []).forEach((x) => { const s = stage(x.id_expiry); if (s) alerts.push({ ent: e.id, key: `uboid-${x.name}-${x.id_expiry}-${s}`, what: `ID of beneficial owner ${x.name} expires ${x.id_expiry}` }); }));
    for (const a of alerts) {
      const rid = ('ca-' + a.key).replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 180); if (done.has(rid)) continue;
      const uids = [...new Set([...roleUids('ceo'), ...roleUids('compliance'), a.owner].filter(Boolean))]; if (!uids.length) (owners || []).forEach((x) => uids.push(x.user_id));
      const { data: profs } = await sb.from('profiles').select('id,email').in('id', uids);
      const ent = ents.find((e) => e.id === (a.ent || 'main')) || {};
      for (const pr of profs || []) {
        await sb.from('docs').upsert({ org_id: o.id, path: `notifications/${rid}-${pr.id.slice(0, 8)}`, collection: 'notifications', scope: o.id + ':notifications', data: { to: pr.id, title: 'Compliance reminder', body: a.what, link: 'calerts', at: new Date().toISOString(), by: 'agent:compliance', entity: a.ent || 'main' } }, { onConflict: 'org_id,path' });
        if (pr.email && EMAIL.test(pr.email)) { const { data: ok } = await sb.rpc('email_gate', { p_org: o.id, p_user: null, p_kind: 'compliance', p_to: pr.email }); if (ok) await sendMail({ to: pr.email, subject: `Compliance reminder: ${a.what}`.slice(0, 180), text: `${a.what}

${ent.name || ''} · Orzio compliance agent`, html: htmlMail('Compliance reminder', a.what, process.env.APP_URL ? process.env.APP_URL.replace(/\/$/, '') + '/#calerts' : '', 'Open compliance alerts', ent.name) }); }
      }
      await sb.from('docs').upsert({ org_id: o.id, path: 'reminders/' + rid, collection: 'reminders', scope: o.id + ':reminders', data: { entity: a.ent || 'main', kind: 'compliance', what: a.what, at: new Date().toISOString(), by: 'agent:compliance' } }, { onConflict: 'org_id,path' });
      out.compliance++;
    }
  }
  return res.status(200).json(out);
};
