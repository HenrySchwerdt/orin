/* orin-explorer: optional progressive enhancement. Every page works without it; it adds a symbol filter and drag-to-pan /
   ctrl-wheel zoom on the graphs. No network, no storage, no eval. Source of src/explorer_js.or (gen_assets.sh). */
(function () {
  'use strict';
  var filter = document.getElementById('ex-filter');
  if (filter) {
    var q = document.getElementById('ex-q');
    var kind = document.getElementById('ex-k');
    var count = document.getElementById('ex-count');
    var rows = Array.prototype.slice.call(document.querySelectorAll('.ex-table tbody tr'));
    filter.hidden = false;
    var apply = function () {
      var needle = q.value.trim().toLowerCase();
      var k = kind.value;
      var shown = 0;
      for (var i = 0; i < rows.length; i++) {
        var ok = (needle === '' || (rows[i].getAttribute('data-q') || '').indexOf(needle) >= 0) && (k === '' || rows[i].getAttribute('data-k') === k);
        rows[i].hidden = !ok;
        if (ok) { shown++; }
      }
      count.textContent = shown + ' of ' + rows.length;
    };
    q.addEventListener('input', apply);
    kind.addEventListener('change', apply);
    apply();
  }
  var boxes = document.querySelectorAll('.ex-scroll');
  Array.prototype.forEach.call(boxes, function (box) {
    var svg = box.querySelector('svg');
    if (!svg) { return; }
    var base = parseFloat(svg.getAttribute('width'));
    var scale = 1;
    var drag = null;
    var cap = box.parentNode.querySelector('figcaption');
    if (cap && box.parentNode.classList.contains('ex-figure-wide')) {
      var fit = document.createElement('button');
      fit.type = 'button';
      fit.className = 'ex-btn';
      fit.textContent = 'Fit to width';
      var fitted = false;
      fit.addEventListener('click', function () {
        fitted = !fitted;
        scale = 1;
        svg.style.width = '';
        svg.style.maxWidth = fitted ? '100%' : 'none';
        svg.style.height = 'auto';
        fit.textContent = fitted ? 'Actual size' : 'Fit to width';
      });
      cap.appendChild(fit);
    }
    box.addEventListener('wheel', function (ev) {
      if (!ev.ctrlKey && !ev.metaKey) { return; }
      ev.preventDefault();
      scale = Math.min(3, Math.max(0.4, scale * (ev.deltaY < 0 ? 1.1 : 0.9)));
      svg.style.maxWidth = 'none';
      svg.style.width = (base * scale) + 'px';
      svg.style.height = 'auto';
    }, { passive: false });
    box.addEventListener('mousedown', function (ev) {
      if (ev.button !== 0 || ev.target.closest('a')) { return; }
      drag = { x: ev.clientX, y: ev.clientY, l: box.scrollLeft, t: box.scrollTop };
      box.classList.add('ex-grab');
    });
    window.addEventListener('mousemove', function (ev) {
      if (!drag) { return; }
      box.scrollLeft = drag.l - (ev.clientX - drag.x);
      box.scrollTop = drag.t - (ev.clientY - drag.y);
    });
    window.addEventListener('mouseup', function () {
      drag = null;
      box.classList.remove('ex-grab');
    });
  });
})();
