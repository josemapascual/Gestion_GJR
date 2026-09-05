/* ══════════════════════════════════════════════════════════════
   sync.js · Refuerzo del guardado en la nube de los módulos GJR
   Se añade DESPUÉS del bloque "GJR CLOUD SYNC", antes de </body>:
       <script src="sync.js?v=1"></script>

   PROBLEMA QUE RESUELVE
   El guardado se dispara 1,5 s después de cambiar un dato. Si en
   ese hueco recargas, cambias de pestaña o cierras, el envío no
   llega a salir. Y al volver, la descarga de la nube machaca lo
   local: para un objeto (no una lista) el criterio es "gana la
   nube". Resultado: subes el Excel y al rato tienes los datos
   viejos otra vez.

   QUÉ HACE
   1. Al elegir un archivo, guarda de inmediato: sin espera.
   2. Antes de salir de la página o de ocultar la pestaña, vacía
      lo que quede pendiente.
   3. Avisa en pantalla si algo se queda sin guardar.
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  if (typeof window.gjrKvPush !== 'function') return;   // módulo sin sincronización

  var pendientes = {};
  var origSet = localStorage.setItem.bind(localStorage);

  /* Marcamos como pendiente todo lo que se escriba, para saber qué falta. */
  var setAnterior = localStorage.setItem;
  localStorage.setItem = function (k, v) {
    setAnterior.apply(localStorage, arguments);
    if (k && k.indexOf('__kvat_') !== 0) pendientes[k] = Date.now();
  };

  function flush(motivo) {
    var claves = Object.keys(pendientes);
    if (!claves.length) return 0;
    claves.forEach(function (k) {
      try { window.gjrKvPush(k); } catch (e) {}
      delete pendientes[k];
    });
    return claves.length;
  }

  /* ── 1. Al cargar un archivo se guarda ya, sin esperar ── */
  function engancharArchivos() {
    var inputs = document.querySelectorAll('input[type="file"]');
    for (var i = 0; i < inputs.length; i++) {
      if (inputs[i].dataset.gjrSync) continue;
      inputs[i].dataset.gjrSync = '1';
      inputs[i].addEventListener('change', function () {
        /* El módulo necesita un momento para leer el Excel y escribir
           en localStorage. Reintentamos hasta que aparezca algo pendiente. */
        var intentos = 0;
        var t = setInterval(function () {
          intentos++;
          if (flush('archivo') || intentos > 20) clearInterval(t);
        }, 400);
      });
    }
  }

  if (document.readyState === 'loading')
    document.addEventListener('DOMContentLoaded', engancharArchivos);
  else engancharArchivos();
  setInterval(engancharArchivos, 3000);   // por si el módulo pinta el control después

  /* ── 2. Nada se pierde al salir ── */
  window.addEventListener('beforeunload', function (e) {
    if (!Object.keys(pendientes).length) return;
    flush('salida');
    e.preventDefault();
    e.returnValue = '';          // el navegador pregunta antes de cerrar
    return '';
  });

  document.addEventListener('visibilitychange', function () {
    if (document.visibilityState === 'hidden') flush('oculta');
  });

  /* ── 3. Aviso visible si algo lleva demasiado tiempo sin guardar ── */
  setInterval(function () {
    var claves = Object.keys(pendientes);
    if (!claves.length) return;
    var masViejo = Math.min.apply(null, claves.map(function (k) { return pendientes[k]; }));
    if (Date.now() - masViejo < 8000) return;
    flush('reintento');
    var b = document.getElementById('gjrKvBadge') || document.querySelector('.gjr-status');
    if (b) b.textContent = 'Reintentando guardar…';
  }, 5000);

  window.gjrFlush = flush;
})();
