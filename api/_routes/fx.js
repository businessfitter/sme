// GET /api/fx — live exchange rates against the US dollar, cached for 30 minutes.
// Source: open.er-api.com (free, no key). With FX_API_KEY set, the keyed ExchangeRate-API feed is used (updated more often).
// FX_FIXTURE (JSON of rates) is for local tests, where the network is closed.
let cache = null;
module.exports = async (req, res) => {
  res.setHeader('content-type', 'application/json');
  try {
    if (!cache || Date.now() - cache.t > 30 * 60e3) {
      let d;
      if (process.env.FX_FIXTURE) d = { rates: JSON.parse(process.env.FX_FIXTURE), at: new Date().toISOString(), source: 'Test rates' };
      else {
        const key = process.env.FX_API_KEY;
        const url = key ? `https://v6.exchangerate-api.com/v6/${encodeURIComponent(key)}/latest/USD` : 'https://open.er-api.com/v6/latest/USD';
        const r = await fetch(url, { headers: { accept: 'application/json' } });
        const j = await r.json();
        const rates = j.rates || j.conversion_rates;
        if (!r.ok || !rates) throw new Error('rates unavailable');
        d = { rates, at: j.time_last_update_unix ? new Date(j.time_last_update_unix * 1000).toISOString() : new Date().toISOString(), source: 'ExchangeRate-API market rates' };
      }
      cache = { t: Date.now(), d: { base: 'USD', ...d } };
    }
    res.setHeader('cache-control', 'public, max-age=900');
    res.statusCode = 200; res.end(JSON.stringify(cache.d));
  } catch (e) { res.statusCode = 503; res.end(JSON.stringify({ error: 'Live exchange rates are not available right now.' })); }
};
