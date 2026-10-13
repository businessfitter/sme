// POST /api/ai — the app's AI agents call Claude through this function.
// The Anthropic key stays on the server. Every call is checked against the company's
// status, the person's rate limit and the plan's monthly quota, and is logged for usage.
const { verify, UUID } = require('./_auth');

const MODELS = {
  quick: process.env.ANTHROPIC_MODEL_QUICK || 'claude-haiku-5-5',
  default: process.env.ANTHROPIC_MODEL || 'claude-sonnet-5-5',
  complex: process.env.ANTHROPIC_MODEL_COMPLEX || 'claude-opus-5-5',
};
const MAX_TOKENS = 8192;            // per reply
const MAX_REQUEST_CHARS = 2_500_000; // about 2.5 MB of conversation and images per call
const MAX_IMAGES = 20;

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
    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-api-key': process.env.ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01' },
      body: JSON.stringify(payload),
    });
    const j = await r.json().catch(() => ({}));
    await finish(j, r.ok);
    if (!r.ok) return res.status(r.status === 429 ? 429 : 502).json({ error: { message: r.status === 429 ? 'The AI service is busy. Try again in a moment.' : 'The AI service returned an error. Try again.' } });
    return res.status(200).json({ content: j.content, stop_reason: j.stop_reason, usage: j.usage });
  } catch (e) {
    await finish(null, false);
    return res.status(502).json({ error: { message: 'Could not reach the AI service.' } });
  }
};
