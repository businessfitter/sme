// GET /api/config — hands the browser the public settings.
// Only the URL and the anon (public) key are sent; the service role key never leaves the server.
module.exports = (req, res) => {
  const cfg = {
    url: process.env.SUPABASE_URL || '',
    anon: process.env.SUPABASE_ANON_KEY || '',
    appName: process.env.APP_NAME || 'Orzio',
    termsUrl: process.env.TERMS_URL || '',
    privacyUrl: process.env.PRIVACY_URL || '',
    // Browser key for Google Maps (restrict it to your domain in Google Cloud). Optional: without it the map uses OpenStreetMap.
    mapsKey: process.env.GOOGLE_MAPS_API_KEY || '',
  };
  res.setHeader('Content-Type', 'application/javascript; charset=utf-8');
  res.setHeader('Cache-Control', 'no-store');
  res.status(200).send('window.__SUPA=' + JSON.stringify(cfg) + ';');
};
