// One Vercel function for the smaller endpoints (Vercel Hobby allows 12 functions per deployment).
// /api/<name> runs api/_routes/<name>.js. ai, reminders and sanctions stay separate for their longer time limits.
const ROUTES = {
  blob: () => require('./_routes/blob'), booking: () => require('./_routes/booking'), config: () => require('./_routes/config'),
  connector: () => require('./_routes/connector'), contact: () => require('./_routes/contact'), domain: () => require('./_routes/domain'),
  donor: () => require('./_routes/donor'), fx: () => require('./_routes/fx'), email: () => require('./_routes/email'), quote: () => require('./_routes/quote'),
  rfq: () => require('./_routes/rfq'), share: () => require('./_routes/share'), sign: () => require('./_routes/sign'),
  store: () => require('./_routes/store'), users: () => require('./_routes/users'), signup: () => require('./_routes/signup'), worldcheck: () => require('./_routes/worldcheck'),
};
module.exports = async (req, res) => {
  const name = String((req.query && req.query.route) || '');
  if (!Object.prototype.hasOwnProperty.call(ROUTES, name)) { res.statusCode = 404; res.setHeader('content-type', 'application/json'); return res.end('{"error":"Not found"}'); }
  if (req.query) delete req.query.route;
  return ROUTES[name]()(req, res);
};
