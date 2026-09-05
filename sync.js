/* ══════════════════════════════════════════════════════════════
   sync.js · Refuerzo del guardado en la nube de los módulos GJR
   Va DESPUÉS del bloque "GJR CLOUD SYNC":
       <script src="sync.js?v=2"></script>

   EL FALLO
   Al guardar, el módulo apunta la hora del RELOJ DEL NAVEGADOR.
   Al descargar, compara esa hora con la del SERVIDOR, que siempre
   es un poco posterior. Resultado: la nube parece más nueva
   siempre. Mientras eso coincida con lo local no pasa nada, pero
   en la ventana entre que cargas un Excel y sale el envío (1,5 s),
   cualquier descarga —y se dispara al cambiar de pestaña— sustituye
   tus datos nuevos por la copia vieja de la nube. Y luego el envío
   sube esa copia vieja. Por eso «se actualiza pero no se memoriza».

   QUÉ HACE
   1. Al cargar un archivo, guarda de inmediato.
   2. Vigila 45 s: si algo devuelve el valor al anterior, lo repone.
   3. Vacía lo pendiente antes de salir o de ocultar la pestaña.
   4. Lo dice en pantalla, en vez de fallar en silencio.
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  if (typeof window.gjrKvPush !== 'function') return;

  var pendientes = {};      // clave -> momento en que se tocó
  var autoritativo = {};    // clave -> valor que debe prevalecer
  var vigilarHasta = 0;
  var origSet = Object.getOwnPropertyDescriptor(Storage.prototype, 'setItem')
                ? Storage.prototype.setItem.bind(localStorage)
                : localStorage.setItem.bind(localStorage);

  var setPrevio = localStorage.setItem;
  localStorage.setItem = function (k, v) {
    setPrevio.apply(localStorage, arguments);
    if (k && k.indexOf('__kvat_') !== 0) pendientes[k] = Date.now();
  };

  function avisar(txt, mal) {
    var b = document.getElementById('gjrKvBadge') || document.querySelector('.gjr-status');
    if (!b) return;
    b.textContent = txt;
    if (mal) b.style.color = '#FFB4AB';
  }

  function flush() {
    var ks = Object.keys(pendientes);
    if (!ks.length) return 0;
    ks.forEach(function (k) {
      try {
        autoritativo[k] = localStorage.getItem(k);
        window.gjrKvPush(k);
      } catch (e) {}
      delete pendientes[k];
    });
    vigilarHasta = Date.now() + 45000;
    avisar('Guardando\u2026');
    setTimeout(function () { avisar('Nube \u2713'); }, 2500);
    return ks.length;
  }

  /* ── 1. Guardar en cuanto se carga un archivo ── */
  function engancharArchivos() {
    var ins = document.querySelectorAll('input[type="file"]');
    for (var i = 0; i < ins.length; i++) {
      if (ins[i].dataset.gjrSync) continue;
      ins[i].dataset.gjrSync = '1';
      ins[i].addEventListener('change', function () {
        var n = 0;
        var t = setInterval(function () {
          n++;
          if (flush() || n > 30) clearInterval(t);   // hasta 12 s por si el Excel tarda
        }, 400);
      });
    }
  }
  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', engancharArchivos);
  else engancharArchivos();
  setInterval(engancharArchivos, 3000);

  /* ── 2. Vigilancia: si la descarga pisa lo recién cargado, se repone ──
     No podemos impedir que la descarga se ejecute, pero sí deshacerla. */
  setInterval(function () {
    if (Date.now() > vigilarHasta) return;
    Object.keys(autoritativo).forEach(function (k) {
      var ahora = localStorage.getItem(k);
      if (ahora === autoritativo[k]) return;
      origSet(k, autoritativo[k]);          // reponemos sin marcar pendiente
      try { window.gjrKvPush(k); } catch (e) {}
      avisar('Recuperando tus datos\u2026', true);
      setTimeout(function () { avisar('Nube \u2713'); }, 2500);
    });
  }, 1200);

  /* ── 3. Nada se pierde al salir ── */
  window.addEventListener('beforeunload', function (e) {
    if (!Object.keys(pendientes).length) return;
    flush();
    e.preventDefault(); e.returnValue = ''; return '';
  });
  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flush();
  });

  /* ── 4. Reintento si algo se atasca ── */
  setInterval(function () {
    var ks = Object.keys(pendientes);
    if (!ks.length) return;
    var viejo = Math.min.apply(null, ks.map(function (k) { return pendientes[k]; }));
    if (Date.now() - viejo > 8000) { avisar('Reintentando guardar\u2026', true); flush(); }
  }, 5000);

  window.gjrFlush = flush;
})();
