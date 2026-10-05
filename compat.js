/* ══════════════════════════════════════════════════════════════
   compat.js · Compatibilidad con navegadores antiguos (iPad con iOS 12)
   Va el PRIMERO dentro de <head>, antes de cualquier otra librería:
       <script src="compat.js?v=1"></script>

   En navegadores actuales no hace nada: cada bloque comprueba si la
   función ya existe y solo la añade si falta. Escrito en ES5 a
   propósito, para que lo entienda cualquier Safari.

   Qué añade cuando falta:
   · ResizeObserver (lo exige Chart.js 4 para ajustar los gráficos)
   · Blob/File.arrayBuffer() y .text() (lectura de Excel)
   · replaceAll, at, findLast, Object.hasOwn, Promise.allSettled,
     structuredClone, crypto.randomUUID, replaceChildren
   · Separación entre botones cuando el navegador no aplica «gap»
     en contenedores flex (Safari anterior a 14.1)
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  var W = window;

  function definir(obj, nombre, fn) {
    if (!obj || obj[nombre]) return;
    try {
      Object.defineProperty(obj, nombre, { value: fn, writable: true, configurable: true });
    } catch (e) { obj[nombre] = fn; }
  }

  /* ── ResizeObserver ─────────────────────────────────────────── */
  if (typeof W.ResizeObserver !== 'function') {
    var observadores = [];
    var reloj = null;

    var medir = function (el) {
      var cs = W.getComputedStyle(el);
      var w = el.clientWidth - (parseFloat(cs.paddingLeft) || 0) - (parseFloat(cs.paddingRight) || 0);
      var h = el.clientHeight - (parseFloat(cs.paddingTop) || 0) - (parseFloat(cs.paddingBottom) || 0);
      return { width: w > 0 ? w : 0, height: h > 0 ? h : 0 };
    };

    var revisar = function () {
      for (var i = 0; i < observadores.length; i++) {
        var ob = observadores[i], avisos = [];
        for (var j = 0; j < ob._obj.length; j++) {
          var t = ob._obj[j], s = medir(t.el);
          if (s.width !== t.w || s.height !== t.h) {
            t.w = s.width; t.h = s.height;
            avisos.push({
              target: t.el,
              contentRect: { x: 0, y: 0, top: 0, left: 0, width: s.width, height: s.height,
                             right: s.width, bottom: s.height }
            });
          }
        }
        if (avisos.length) {
          try { ob._cb.call(ob, avisos, ob); }
          catch (err) { setTimeout(function () { throw err; }, 0); }
        }
      }
    };

    var arrancar = function () { if (!reloj) reloj = setInterval(revisar, 250); };
    var parar = function () {
      if (reloj && !observadores.length) { clearInterval(reloj); reloj = null; }
    };

    var RO = function (callback) {
      if (typeof callback !== 'function') throw new TypeError('ResizeObserver: callback');
      this._cb = callback; this._obj = [];
    };
    RO.prototype.observe = function (el) {
      if (!el) return;
      for (var i = 0; i < this._obj.length; i++) if (this._obj[i].el === el) return;
      this._obj.push({ el: el, w: -1, h: -1 });
      if (observadores.indexOf(this) < 0) observadores.push(this);
      arrancar();
      setTimeout(revisar, 0);
    };
    RO.prototype.unobserve = function (el) {
      this._obj = this._obj.filter(function (t) { return t.el !== el; });
      if (!this._obj.length) this.disconnect();
    };
    RO.prototype.disconnect = function () {
      this._obj = [];
      var i = observadores.indexOf(this);
      if (i >= 0) observadores.splice(i, 1);
      parar();
    };
    W.ResizeObserver = RO;
    W.addEventListener('resize', revisar);
    W.addEventListener('orientationchange', function () { setTimeout(revisar, 300); });
  }

  /* ── Lectura de archivos ────────────────────────────────────── */
  if (W.Blob) {
    var leer = function (blob, modo) {
      return new Promise(function (ok, ko) {
        var r = new FileReader();
        r.onload = function () { ok(r.result); };
        r.onerror = function () { ko(r.error); };
        if (modo === 'texto') r.readAsText(blob); else r.readAsArrayBuffer(blob);
      });
    };
    definir(Blob.prototype, 'arrayBuffer', function () { return leer(this, 'binario'); });
    definir(Blob.prototype, 'text', function () { return leer(this, 'texto'); });
  }

  /* ── Texto y listas ─────────────────────────────────────────── */
  definir(String.prototype, 'replaceAll', function (buscar, poner) {
    if (buscar instanceof RegExp) {
      if (!buscar.global) throw new TypeError('replaceAll exige una expresión con /g');
      return this.replace(buscar, poner);
    }
    return this.split(String(buscar)).join(typeof poner === 'function' ? poner(String(buscar)) : poner);
  });
  var at = function (n) {
    n = Math.trunc ? Math.trunc(n) || 0 : (n | 0);
    if (n < 0) n += this.length;
    return (n < 0 || n >= this.length) ? undefined : this[n];
  };
  definir(Array.prototype, 'at', at);
  definir(String.prototype, 'at', at);
  definir(Array.prototype, 'findLast', function (fn, ctx) {
    for (var i = this.length - 1; i >= 0; i--) if (fn.call(ctx, this[i], i, this)) return this[i];
    return undefined;
  });
  definir(Array.prototype, 'findLastIndex', function (fn, ctx) {
    for (var i = this.length - 1; i >= 0; i--) if (fn.call(ctx, this[i], i, this)) return i;
    return -1;
  });
  definir(Object, 'hasOwn', function (o, k) { return Object.prototype.hasOwnProperty.call(o, k); });
  definir(Object, 'fromEntries', function (it) {
    var o = {};
    Array.from(it).forEach(function (p) { o[p[0]] = p[1]; });
    return o;
  });

  /* ── Promesas y utilidades ──────────────────────────────────── */
  if (W.Promise) {
    definir(Promise, 'allSettled', function (lista) {
      return Promise.all(Array.from(lista).map(function (p) {
        return Promise.resolve(p).then(
          function (v) { return { status: 'fulfilled', value: v }; },
          function (e) { return { status: 'rejected', reason: e }; });
      }));
    });
  }
  definir(W, 'queueMicrotask', function (fn) { Promise.resolve().then(fn); });
  definir(W, 'structuredClone', function (v) {
    return v === undefined ? undefined : JSON.parse(JSON.stringify(v));
  });
  if (W.crypto && W.crypto.getRandomValues) {
    definir(W.crypto, 'randomUUID', function () {
      var b = W.crypto.getRandomValues(new Uint8Array(16));
      b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
      var h = Array.prototype.map.call(b, function (x) { return (x + 0x100).toString(16).slice(1); }).join('');
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-' + h.slice(12, 16) + '-' + h.slice(16, 20) + '-' + h.slice(20);
    });
  }
  if (W.Element) {
    definir(Element.prototype, 'replaceChildren', function () {
      while (this.firstChild) this.removeChild(this.firstChild);
      for (var i = 0; i < arguments.length; i++) {
        var n = arguments[i];
        this.appendChild(typeof n === 'string' ? document.createTextNode(n) : n);
      }
    });
  }
  if (W.MediaQueryList && !MediaQueryList.prototype.addEventListener) {
    MediaQueryList.prototype.addEventListener = function (t, fn) { if (t === 'change') this.addListener(fn); };
    MediaQueryList.prototype.removeEventListener = function (t, fn) { if (t === 'change') this.removeListener(fn); };
  }

  /* ── Separación de botones si el navegador no aplica «gap» en flex ── */
  function huecoFlexOk() {
    var d = document.createElement('div');
    d.style.cssText = 'display:flex;flex-direction:column;row-gap:1px;position:absolute;visibility:hidden';
    d.appendChild(document.createElement('div'));
    d.appendChild(document.createElement('div'));
    document.documentElement.appendChild(d);
    var ok = d.scrollHeight === 1;
    d.parentNode.removeChild(d);
    return ok;
  }
  try {
    if (!huecoFlexOk()) {
      document.documentElement.className += ' sin-hueco-flex';
      var css = document.createElement('style');
      css.textContent = [
        '.sin-hueco-flex .gjr-header > * + *, .sin-hueco-flex .gjr-acciones > * + *{margin-left:10px}',
        '.sin-hueco-flex #nvg-barra > * + *{margin-left:2px}',
        '.sin-hueco-flex .lab-filter-row > *, .sin-hueco-flex .status-pills > *{margin:0 8px 6px 0}',
        '.sin-hueco-flex .filters-row > *{margin:0 12px 8px 0}',
        '.sin-hueco-flex .dept-badges > * + *{margin-left:8px}',
        '.sin-hueco-flex .pest-row > * + *, .sin-hueco-flex .pagination > * + *{margin-left:8px}',
        '.sin-hueco-flex .badge-e .bdot{margin-right:4px}'
      ].join('\n');
      document.head.appendChild(css);
    }
  } catch (e) {}
})();
