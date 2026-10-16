// POST /api/ai — the app's AI agents call Claude through this function.
// The Anthropic key stays on the server. Every call is checked against the company's
// status, the person's rate limit and the plan's monthly quota, and is logged for usage.
const { verify, UUID } = require('./_auth');

const MODELS = {
  quick: process.env.ANTHROPIC_MODEL_QUICK || 'claude-haiku-5-5',
  default: process.env.ANTHROPIC_MODEL || 'claude-sonnet-5-5',
  complex: process.env.ANTHROPIC_MODEL_COMPLEX || 'claude-opus-5-5',
};
const MAX_TOKENS = 16000;           // per reply (long statements are also read in parts)
const MAX_REQUEST_CHARS = 2_500_000; // about 2.5 MB of conversation and images per call
const MAX_IMAGES = 20;

// tolerate a key pasted with spaces, line breaks or quotes around it
const aiKey = () => String(process.env.ANTHROPIC_API_KEY || '').trim().replace(/^['"]|['"]$/g, '').trim();
function clean(body) {
  const msgs = Array.isArray(body.messages) ? body.messages.slice(-200) : [];
  const messages = msgs
    .filter((m) => m && (m.role === 'user' || m.role === 'assistant') && (typeof m.content === 'string' || Array.isArray(m.content)))
    .map((m) => ({ role: m.role, content: m.content }));
  const tools = Array.isArray(body.tools)
    ? body.tools.slice(0, 32).filter((t) => t && typeof t.name === 'string').map((t) => ({
        name: t.name.slice(0, 64),
        description: String(t.description || '').slice(0, 4000),
        input_schema: t.input_schema && typeof t.input_schema === 'object' ? t.input_schema : { type: 'object', properties: {} },
      }))
    : [];
  return { messages, tools };
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: { message: 'Use POST.' } });
  if (!process.env.ANTHROPIC_API_KEY) return res.status(503).json({ error: { message: 'AI features are not switched on for this service yet.' } });

  let who;
  try { who = await verify((req.headers.authorization || '').replace(/^Bearer\s+/i, '')); }
  catch (e) { return res.status(e.status || 401).json({ error: { message: e.message } }); }

  // Industry packs: a platform admin runs Orzio's agents once per industry and country (no workspace, no customer quota)
  if (String(req.headers['x-mode'] || '') === 'pack') return packRun(req, res, who);

  const org = String(req.headers['x-org'] || '');
  if (!UUID.test(org)) return res.status(400).json({ error: { message: 'No company selected.' } });

  let body;
  try { body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {}); }
  catch (e) { return res.status(400).json({ error: { message: 'Bad request.' } }); }
  const { messages, tools } = clean(body);
  if (!messages.length) return res.status(400).json({ error: { message: 'No messages.' } });
  const size = JSON.stringify(messages).length + JSON.stringify(tools).length + String(body.system || '').length;
  if (size > MAX_REQUEST_CHARS) return res.status(413).json({ error: { message: 'This request is too large for the AI agent. Try fewer or smaller pages.' } });
  const images = messages.reduce((n, m) => n + (Array.isArray(m.content) ? m.content.filter((c) => c && (c.type === 'image' || c.type === 'document')).length : 0), 0);
  if (images > MAX_IMAGES) return res.status(413).json({ error: { message: `The AI agent can read up to ${MAX_IMAGES} pages or images at a time.` } });
  let tier = MODELS[body.tier] ? body.tier : 'default';

  // Gate: membership, company status, rate limit, monthly quota (all in the database)
  const { data: gate, error: gErr } = await who.sb.rpc('ai_begin', { p_org: org, p_user: who.user.id, p_tier: tier });
  if (gErr || !gate) return res.status(503).json({ error: { message: 'Usage check failed. Try again shortly.' } });
  if (!gate.ok) return res.status(gate.status || 403).json({ error: { message: gate.message } });
  // the most expensive model is for paying staff only
  if (tier === 'complex' && (gate.role === 'portal' || gate.trial)) tier = 'default';

  const payload = { model: MODELS[tier], max_tokens: Math.max(256, Math.min(+body.max_tokens || MAX_TOKENS, MAX_TOKENS)), messages };
  if (tools.length) payload.tools = tools;
  if (typeof body.system === 'string') payload.system = body.system.slice(0, 20000);

  const finish = (j, ok) => who.sb.rpc('ai_finish', {
    p_id: gate.log_id, p_model: payload.model,
    p_in: (j && j.usage && j.usage.input_tokens) || 0, p_out: (j && j.usage && j.usage.output_tokens) || 0, p_ok: ok,
  }).then(() => {}, () => {});

  try {
    let r, j;
    // overloaded or a passing server error: try again a couple of times before giving up
    for (let attempt = 0; attempt < 3; attempt++) {
      r = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-api-key': aiKey(), 'anthropic-version': '2023-06-01' },
        body: JSON.stringify(payload),
      });
      j = await r.json().catch(() => ({}));
      if (r.ok || ![500, 502, 503, 504, 529].includes(r.status)) break;
      await new Promise((ok) => setTimeout(ok, 1500 * (attempt + 1)));
    }
    await finish(j, r.ok);
    if (!r.ok) {
      const why = String((j && j.error && j.error.message) || '');
      console.error('[ai] anthropic', r.status, payload.model, why.slice(0, 500));
      return res.status(r.status === 429 ? 429 : 502).json({ error: { message: aiReason(r.status, why), status: r.status } });
    }
    return res.status(200).json({ content: j.content, stop_reason: j.stop_reason, usage: j.usage });
  } catch (e) {
    await finish(null, false);
    return res.status(502).json({ error: { message: 'Could not reach the AI service.' } });
  }
};

// the AI provider's error in words the person (or the platform admin) can act on
function aiReason(status, why) {
  const w = why.toLowerCase();
  if (/credit balance|billing|purchase credits/.test(w)) return 'The AI service has run out of credit. The platform administrator needs to top up the Anthropic account (Plans & Billing).';
  if (status === 401 || /api key|authentication|x-api-key/.test(w)) return 'The AI key on the server is not valid (Anthropic says: ' + (why || 'invalid key').slice(0, 120) + '). Check ANTHROPIC_API_KEY in Vercel → Settings → Environment Variables is set for Production, then redeploy.';
  if (status === 403) return 'The AI key on the server is not allowed to do this. The platform administrator needs to check the Anthropic account.';
  if (status === 404 || /model/.test(w) && /not.?found|does not exist|invalid/.test(w)) return 'The AI model set on the server is not available. The platform administrator needs to check the ANTHROPIC_MODEL settings in Vercel.';
  if (status === 429) return 'The AI service is busy. Try again in a moment.';
  if (status === 529 || status >= 500) return 'The AI service is overloaded right now. Try again in a minute.';
  if (/image|pdf|document/.test(w) && /(too large|exceed|could not process|invalid)/.test(w)) return 'The AI could not read this file. Try a smaller file, fewer pages, or export the statement as CSV or Excel.';
  if (/prompt is too long|too many tokens|context/.test(w)) return 'This file is too long for one read. Upload a shorter period (for example one month) or a CSV/Excel export.';
  return 'The AI service could not process this request' + (why ? ': ' + why.slice(0, 200) : '.');
}

async function packRun(req, res, who) {
  const { data: adm } = await who.sb.from('platform_admins').select('user_id').eq('user_id', who.user.id).maybeSingle();
  if (!adm) return res.status(403).json({ error: { message: 'Platform admins only.' } });
  let body;
  try { body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {}); }
  catch (e) { return res.status(400).json({ error: { message: 'Bad request.' } }); }
  const { messages } = clean(body);
  if (!messages.length) return res.status(400).json({ error: { message: 'No messages.' } });
  const tier = MODELS[body.tier] ? body.tier : 'complex';
  const payload = { model: MODELS[tier], max_tokens: Math.max(1024, Math.min(+body.max_tokens || 16000, 32000)), messages };
  if (typeof body.system === 'string') payload.system = body.system.slice(0, 40000);
  try {
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': aiKey(), 'anthropic-version': '2023-06-01' },
      body: JSON.stringify(payload),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) return res.status(r.status === 429 ? 429 : 502).json({ error: { message: (j.error && j.error.message) || 'The AI service returned an error.' } });
    return res.status(200).json({ content: j.content, stop_reason: j.stop_reason, usage: j.usage, model: payload.model });
  } catch (e) {
    return res.status(502).json({ error: { message: 'Could not reach the AI service.' } });
  }
}
