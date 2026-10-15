// Orzio website behaviour: header, mobile menu, links to the app, the review-hub orbit, contact form.
(function () {
  // The app lives at /app on the same address (on other addresses / also opens it). Override with <meta name="orzio-app">.
  var meta = document.querySelector('meta[name="orzio-app"]');
  var APP = (meta && meta.content) || (location.origin + '/app');
  document.querySelectorAll('[data-app]').forEach(function (a) { var p = a.getAttribute('data-app'); a.href = APP + (p === 'signup' ? '?signup' : ''); });

  var top = document.querySelector('.top');
  if (top) {
    var onScroll = function () { top.classList.toggle('scrolled', window.scrollY > 8); };
    onScroll(); window.addEventListener('scroll', onScroll, { passive: true });
    var m = top.querySelector('.menu');
    if (m) m.addEventListener('click', function () { var o = top.classList.toggle('open'); m.setAttribute('aria-expanded', String(o)); });
  }
  var y = document.getElementById('yr'); if (y) y.textContent = new Date().getFullYear();

  // The review hub inside the Orzio orbit: agents prepare, you approve, the orbit closes.
  var orbit = document.querySelector('.orbit');
  if (orbit) {
    var tasks = [].slice.call(orbit.querySelectorAll('.task'));
    var arc = orbit.querySelector('.arc'), dot = orbit.querySelector('.dot'), count = orbit.querySelector('[data-count]');
    var R = 40, C = 2 * Math.PI * R, GAP = 0.22; // the brand mark is an open circle
    var reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var done = 0;
    function draw() {
      var share = GAP * (1 - done / tasks.length); // the gap shrinks as items are approved
      if (arc) { arc.style.strokeDasharray = C; arc.style.strokeDashoffset = String(C * share); }
      if (arc) arc.style.transform = 'rotate(' + (-45 + share * 180) + 'deg)'; // the gap stays centred on the teal dot, as in the logo
      if (count) count.textContent = done + ' of ' + tasks.length + ' approved';
    }
    tasks.forEach(function (t, i) {
      setTimeout(function () { t.classList.add('in'); }, reduce ? 0 : 350 + i * 260);
      var b = t.querySelector('button');
      b.addEventListener('click', function () {
        if (t.classList.contains('done')) return;
        t.classList.add('done'); b.textContent = 'Approved'; b.setAttribute('aria-pressed', 'true'); done++; draw();
        if (done === tasks.length) { var l = orbit.querySelector('[data-all]'); if (l) l.hidden = false; }
      });
    });
    draw();
  }

  // Contact form → /api/contact (falls back to email)
  var f = document.getElementById('contact');
  if (f) f.addEventListener('submit', function (e) {
    e.preventDefault(); var msg = document.getElementById('cmsg'); var btn = f.querySelector('button'); btn.disabled = true; msg.textContent = 'Sending…';
    var data = {}; new FormData(f).forEach(function (v, k) { data[k] = String(v); });
    fetch('/api/contact', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(data) })
      .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
      .then(function (x) { if (x.ok) { f.reset(); msg.textContent = 'Thank you. We will reply within one working day.'; } else { msg.textContent = x.j.error || 'It could not be sent. Email us instead.'; } btn.disabled = false; })
      .catch(function () { msg.textContent = 'No connection. Email us instead.'; btn.disabled = false; });
  });
})();
