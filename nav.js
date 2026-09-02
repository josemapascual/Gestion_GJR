/* ══════════════════════════════════════════════════════════════
   nav.js · Barra de módulos común
   Se añade a cualquier pantalla con una sola línea, antes de </body>:
       <script src="nav.js"></script>
   No toca el contenido de la página: se coloca encima y desplaza
   el resto 34px. Marca en qué módulo estás y deja saltar a otro
   sin volver al menú.
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var MODULOS = {
    tb: {
      etiqueta: 'Tropical Báez',
      inicio: 'tb.html',
      items: [
        ['Cuadro de mandos', 'cuadro_mando.html'],
        ['Compras',          'compras.html'],
        ['Ventas',           'facturacion_v21.html'],
        ['Almacén',          'almacen_v7.html'],
        ['Calidad',          'calidad.html'],
        ['Gestión',          'gestion.html'],
        ['Liquidaciones',    'analisis_liquidaciones_v1.html']
      ]
    },
    gjr: {
      etiqueta: 'Grupo Juan Ruiz',
      inicio: 'gjr.html',
      items: [
        ['Liquidaciones', 'liquidaciones_app_v6.html'],
        ['Trazabilidad',  'sistema_trazabilidad_grupo_juan_ruiz.html'],
        ['Defectos',      'dashboard_defectos_criticos.html'],
        ['Descarte',      'descarte.html'],
        ['CRM',           'crm.html'],
        ['Divisas',       'control_divisas.html'],
        ['Viáticos',      'viaticos.html']
      ]
    }
  };

  var ALTO = 34;
  var actual = (location.pathname.split('/').pop() || 'index.html').toLowerCase();

  // ¿A qué empresa pertenece esta pantalla?
  var empresa = 'tb';
  for (var k in MODULOS) {
    if (MODULOS[k].items.some(function (i) { return i[1].toLowerCase() === actual; })
        || MODULOS[k].inicio.toLowerCase() === actual) { empresa = k; }
  }
  if (actual === 'index.html' || actual === '') empresa = null;

  var esc = function (s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  };

  // ── Estilos ──────────────────────────────────────────────────
  var css = document.createElement('style');
  css.textContent = [
    '#nav-gjr{position:fixed;top:0;left:0;right:0;height:' + ALTO + 'px;z-index:99999;',
    '  background:#0E2412;color:rgba(255,255,255,.72);display:flex;align-items:center;',
    "  gap:2px;padding:0 10px;font:500 12px/1 'DM Sans',system-ui,sans-serif;",
    '  box-shadow:0 1px 0 rgba(255,255,255,.08);overflow-x:auto;scrollbar-width:none}',
    '#nav-gjr::-webkit-scrollbar{display:none}',
    '#nav-gjr a{color:inherit;text-decoration:none;padding:6px 10px;border-radius:4px;white-space:nowrap}',
    '#nav-gjr a:hover{background:rgba(255,255,255,.10);color:#fff}',
    '#nav-gjr a.on{background:rgba(255,255,255,.16);color:#fff;box-shadow:inset 0 -2px 0 #F9A825}',
    '#nav-gjr .emp{color:#fff;font-weight:600;padding:6px 10px 6px 4px;white-space:nowrap}',
    '#nav-gjr .sep{width:1px;height:16px;background:rgba(255,255,255,.16);margin:0 6px;flex:none}',
    '#nav-gjr .otra{margin-left:auto;padding-left:14px}',
    'body{padding-top:' + ALTO + 'px !important}',
    // los armazones existentes tienen elementos pegados arriba: se bajan
    '.topbar{top:' + ALTO + 'px !important}',
    '.tabs{top:' + (ALTO + 60) + 'px !important}',
    '.app{height:calc(100vh - ' + ALTO + 'px) !important}',
    '.encab{top:0 !important}',
    '@media print{#nav-gjr{display:none}body{padding-top:0 !important}}'
  ].join('\n');
  document.head.appendChild(css);

  // ── Barra ────────────────────────────────────────────────────
  var html = '<a href="index.html" title="Inicio">◄ Inicio</a><span class="sep"></span>';

  if (empresa) {
    var m = MODULOS[empresa];
    html += '<span class="emp">' + esc(m.etiqueta) + '</span>';
    html += m.items.map(function (i) {
      var on = i[1].toLowerCase() === actual ? ' class="on"' : '';
      return '<a href="' + i[1] + '"' + on + '>' + esc(i[0]) + '</a>';
    }).join('');
    var otra = empresa === 'tb' ? 'gjr' : 'tb';
    html += '<a class="otra" href="' + MODULOS[otra].inicio + '">'
          + esc(MODULOS[otra].etiqueta) + ' ►</a>';
  } else {
    html += '<span class="emp">Grupo Juan Ruiz · Tropical Báez</span>';
  }

  var barra = document.createElement('div');
  barra.id = 'nav-gjr';
  barra.innerHTML = html;

  function montar() {
    if (document.getElementById('nav-gjr')) return;
    document.body.insertBefore(barra, document.body.firstChild);
    var act = barra.querySelector('a.on');
    if (act && act.scrollIntoView) act.scrollIntoView({block: 'nearest', inline: 'center'});
  }
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', montar);
  } else {
    montar();
  }
})();
