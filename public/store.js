/* Orzio live shop widget — add to any website:
 *   <div data-orzio-shop></div>                                   full shop: products, live stock, cart and checkout
 *   <span data-orzio-stock="SKU-123"></span>                      live stock for one product on your own product page
 *   <script src="https://YOUR-ORZIO-ADDRESS/store.js" data-key="STORE-KEY" async></script>
 * Stock refreshes every 20 seconds (data-refresh="10" to change). Prices and stock always come from Orzio.
 */
(function () {
  var me = document.currentScript || document.querySelector('script[src*="store.js"][data-key]');
  if (!me) return;
  var KEY = me.getAttribute('data-key') || new URLSearchParams(location.search).get('k') || '';
  var BASE = new URL(me.src, location.href).origin;
  var EVERY = Math.max(5, +(me.getAttribute('data-refresh') || 20)) * 1000;
  var cat = null, cart = {}, mode = 'shop', msg = '', done = null;
  try { cart = JSON.parse(localStorage.getItem('oz-cart-' + KEY) || '{}'); } catch (e) { cart = {}; }
  var esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); };
  var money = function (v) { return (cat ? cat.currency + ' ' : '') + Number(v || 0).toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 }); };
  var save = function () { try { localStorage.setItem('oz-cart-' + KEY, JSON.stringify(cart)); } catch (e) { /* private mode */ } };
  var css = '.oz-shop{font:15px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif;color:#14213A}.oz-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(190px,1fr));gap:14px}'
    + '.oz-card{border:1px solid #E1E6EE;border-radius:14px;padding:12px;background:#fff;display:flex;flex-direction:column;gap:6px}.oz-card img{width:100%;aspect-ratio:1;object-fit:cover;border-radius:10px;background:#F4F6FA}'
    + '.oz-name{font-weight:600}.oz-price{font-weight:700}.oz-was{text-decoration:line-through;color:#8A94A6;font-weight:400;margin-left:6px}.oz-stock{font-size:12px;color:#1C7C4A}.oz-stock.low{color:#B45309}.oz-stock.out{color:#B3261E}'
    + '.oz-btn{appearance:none;border:0;border-radius:10px;padding:9px 14px;font:600 14px inherit;background:#0F766E;color:#fff;cursor:pointer}.oz-btn:disabled{opacity:.45;cursor:not-allowed}.oz-btn.ghost{background:#EEF2F6;color:#14213A}'
    + '.oz-bar{display:flex;justify-content:space-between;align-items:center;gap:10px;margin:0 0 14px}.oz-cart{border:1px solid #E1E6EE;border-radius:14px;padding:14px;background:#fff;max-width:560px}'
    + '.oz-row{display:flex;justify-content:space-between;gap:10px;padding:6px 0;border-bottom:1px solid #F0F2F6}.oz-f{display:flex;flex-direction:column;gap:3px;margin:8px 0;font-size:13px;color:#5A6577}'
    + '.oz-f input,.oz-f select,.oz-f textarea{font:inherit;padding:9px 10px;border:1px solid #D5DBE5;border-radius:9px;color:#14213A}.oz-msg{color:#B3261E;font-weight:500;margin:8px 0}.oz-ok{color:#1C7C4A;font-weight:600}.oz-live{font-size:12px;color:#5A6577}';
  var st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);
  function stockLabel(n) { return n <= 0 ? '<span class="oz-stock out">Out of stock</span>' : n <= 5 ? '<span class="oz-stock low">Only ' + n + ' left</span>' : '<span class="oz-stock">In stock</span>'; }
  function count() { return Object.keys(cart).reduce(function (s, k) { return s + cart[k]; }, 0); }
  function item(id) { return (cat && cat.items || []).filter(function (i) { return i.id === id; })[0]; }
  function render() {
    document.querySelectorAll('[data-orzio-stock]').forEach(function (el) { var sku = el.getAttribute('data-orzio-stock'); var it = (cat && cat.items || []).filter(function (i) { return i.sku === sku; })[0]; el.innerHTML = it ? stockLabel(it.available) : ''; el.setAttribute('data-available', it ? it.available : 0); });
    document.querySelectorAll('[data-orzio-shop]').forEach(function (box) {
      if (!cat) { box.innerHTML = '<div class="oz-shop">Loading…</div>'; return; }
      var h = '<div class="oz-shop"><div class="oz-bar"><b>' + esc(cat.store || cat.company) + '</b><span class="oz-live">Live stock · updated ' + new Date(cat.updated_at).toLocaleTimeString() + '</span><button class="oz-btn ghost" data-a="cart">Cart (' + count() + ')</button></div>';
      if (done) h += '<div class="oz-cart"><p class="oz-ok">Thank you. Your order ' + esc(done.number) + ' is placed.</p><p>Total ' + money(done.total) + '. We will call you to confirm delivery.</p><button class="oz-btn ghost" data-a="shop">Continue shopping</button></div>';
      else if (mode === 'cart') {
        var ids = Object.keys(cart).filter(function (k) { return item(k); }); var sub = ids.reduce(function (s, k) { return s + cart[k] * item(k).price; }, 0); var sh = cat.shipping || {}; var fee = sh.free_over && sub >= sh.free_over ? 0 : (+sh.flat || 0);
        h += '<div class="oz-cart">' + (ids.length ? ids.map(function (k) { var it = item(k); return '<div class="oz-row"><span>' + esc(it.name) + ' × ' + cart[k] + (cart[k] > it.available ? ' <span class="oz-stock out">only ' + it.available + ' left</span>' : '') + '</span><span>' + money(cart[k] * it.price) + ' <button class="oz-btn ghost" data-a="rm" data-id="' + esc(k) + '">×</button></span></div>'; }).join('')
          + '<div class="oz-row"><span>Delivery' + (sh.free_over ? ' (free over ' + money(sh.free_over) + ')' : '') + '</span><span>' + money(fee) + '</span></div><div class="oz-row"><b>Total</b><b>' + money(sub + fee) + '</b></div>'
          + '<label class="oz-f">Name<input id="oz-n" autocomplete="name"></label><label class="oz-f">Phone<input id="oz-p" type="tel" autocomplete="tel"></label><label class="oz-f">Email<input id="oz-e" type="email" autocomplete="email"></label>'
          + '<label class="oz-f">Delivery address<textarea id="oz-a" rows="2" autocomplete="street-address"></textarea></label><label class="oz-f">City<input id="oz-c" autocomplete="address-level2"></label><label class="oz-f">Country code<input id="oz-k" maxlength="2" placeholder="AE" autocomplete="country"></label>'
          + '<label class="oz-f">Payment<select id="oz-pay">' + (cat.payments || ['cod']).map(function (p) { return '<option value="' + esc(p) + '">' + ({ cod: 'Cash on delivery', bank: 'Bank transfer', card: 'Card payment link' }[p] || esc(p)) + '</option>'; }).join('') + '</select></label>'
          + (msg ? '<p class="oz-msg">' + esc(msg) + '</p>' : '') + '<button class="oz-btn" data-a="order">Place order</button> <button class="oz-btn ghost" data-a="shop">Keep shopping</button>' : '<p>Your cart is empty.</p><button class="oz-btn ghost" data-a="shop">Back to the shop</button>') + '</div>';
      } else h += '<div class="oz-grid">' + (cat.items || []).map(function (it) { return '<div class="oz-card">' + (it.image ? '<img src="' + esc(it.image) + '" alt="">' : '') + '<div class="oz-name">' + esc(it.name) + '</div>' + (it.description ? '<div style="font-size:13px;color:#5A6577">' + esc(it.description) + '</div>' : '')
          + '<div class="oz-price">' + money(it.price) + (it.compare_at > it.price ? '<span class="oz-was">' + money(it.compare_at) + '</span>' : '') + '</div>' + stockLabel(it.available)
          + '<button class="oz-btn" data-a="add" data-id="' + esc(it.id) + '"' + (it.available <= (cart[it.id] || 0) ? ' disabled' : '') + '>Add to cart</button></div>'; }).join('') + '</div>';
      box.innerHTML = h + '</div>';
    });
  }
  function load() { if (!KEY) return; fetch(BASE + '/api/store?k=' + encodeURIComponent(KEY)).then(function (r) { return r.ok ? r.json() : null; }).then(function (j) { if (j) { cat = j; render(); } }).catch(function () {}); }
  document.addEventListener('click', function (e) {
    var b = e.target.closest && e.target.closest('.oz-shop [data-a]'); if (!b) return; var a = b.getAttribute('data-a'), id = b.getAttribute('data-id');
    if (a === 'add') { var it = item(id); if (it && (cart[id] || 0) < it.available) { cart[id] = (cart[id] || 0) + 1; save(); } }
    if (a === 'rm') { delete cart[id]; save(); }
    if (a === 'cart') { mode = 'cart'; done = null; } if (a === 'shop') { mode = 'shop'; done = null; msg = ''; }
    if (a === 'order') {
      var g = function (x) { var el = document.getElementById(x); return el ? el.value : ''; };
      b.disabled = true; msg = '';
      fetch(BASE + '/api/store?k=' + encodeURIComponent(KEY), { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ lines: Object.keys(cart).map(function (k) { return { id: k, qty: cart[k] }; }), payment: g('oz-pay'), customer: { name: g('oz-n'), phone: g('oz-p'), email: g('oz-e'), address: g('oz-a'), city: g('oz-c'), country: g('oz-k') } }) })
        .then(function (r) { return r.json().then(function (j) { return { ok: r.ok, j: j }; }); })
        .then(function (x) { if (!x.ok) { msg = x.j.error || 'The order could not be placed.'; load(); } else { done = x.j; cart = {}; save(); load(); } render(); })
        .catch(function () { msg = 'No connection. Try again.'; render(); });
      return;
    }
    render();
  });
  render(); load(); setInterval(function () { if (!document.hidden) load(); }, EVERY);
})();
