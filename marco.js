/* ══════════════════════════════════════════════════════════════
   marco.js · Armazón de Tropical Báez para los módulos de GJR
   Se añade con una línea, antes de </body> y DESPUÉS de nav.js:
       <script src="marco.js?v=1"></script>

   No mueve ni un solo elemento del módulo: solo añade el menú
   lateral y la barra de estado, y coloca la cabecera que ya
   existe en su sitio. El contenido, las pestañas y todo el
   JavaScript del módulo siguen exactamente igual.
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var ANCHO = 214, ALTO_NAV = 34, ALTO_CAB = 50, ALTO_PIE = 24;

  var MENU = [
    ['Grupo Juan Ruiz', [
      ['Trazabilidad',  'sistema_trazabilidad_grupo_juan_ruiz.html'],
      ['Defectos',      'dashboard_defectos_criticos.html'],
      ['Descarte',      'descarte.html'],
      ['Liquidaciones', 'liquidaciones_app_v6.html']
    ]],
    ['Comercial', [
      ['CRM',      'crm.html'],
      ['Divisas',  'control_divisas.html']
    ]],
    ['Administración', [
      ['Viáticos', 'viaticos.html']
    ]],
    ['Ir a', [
      ['Tropical Báez', 'tb.html'],
      ['Índice',        'index.html']
    ]]
  ];

  var actual = (location.pathname.split('/').pop() || '').toLowerCase();
  var PROPIAS = ['sistema_trazabilidad_grupo_juan_ruiz.html','dashboard_defectos_criticos.html',
                 'descarte.html','liquidaciones_app_v6.html','crm.html',
                 'control_divisas.html','viaticos.html','gjr.html'];
  if (PROPIAS.indexOf(actual) === -1) return;   // fuera de GJR no se toca nada

  var esc = function (s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  };

  /* ── Geometría ── */
  var st = document.createElement('style');
  st.textContent = [
    'body{padding-left:' + ANCHO + 'px !important;',
    '  padding-top:' + (ALTO_NAV + ALTO_CAB) + 'px !important;',
    '  padding-bottom:' + ALTO_PIE + 'px !important;min-height:100vh}',

    /* La cabecera que ya tiene el módulo pasa a ser la barra superior */
    '.gjr-header{position:fixed !important;top:' + ALTO_NAV + 'px !important;',
    '  left:' + ANCHO + 'px !important;right:0 !important;height:' + ALTO_CAB + 'px !important;',
    '  min-height:' + ALTO_CAB + 'px !important;max-height:' + ALTO_CAB + 'px !important;',
    '  z-index:60;margin:0 !important;overflow:hidden !important;',
    '  display:flex !important;align-items:center !important;flex-wrap:nowrap !important;',
    '  gap:12px !important;padding:0 16px !important}',
    /* El título en una sola línea; si no cabe, se recorta */
    '.gjr-header > div:first-of-type,.gjr-header .gjr-titulo{min-width:0;flex:0 1 auto}',
    '.gjr-header h1{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;',
    '  font-size:15px !important;line-height:1.2 !important;margin:0 !important}',
    '.gjr-header-sub,.gjr-header .sub,.gjr-header .gjr-sub,.gjr-header span{',
    '  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:block;',
    '  max-width:300px;font-size:11px !important;line-height:1.3 !important;margin:0 !important;',
    '  color:rgba(255,255,255,.6) !important}',
    /* Los botones nunca se encogen ni se parten */
    '.gjr-acciones{flex:none !important;margin-left:auto !important;flex-wrap:nowrap !important}',
    '.gjr-header img{flex:none}',
    '@media(max-width:1200px){.gjr-header-sub,.gjr-header .sub,',
    '  .gjr-header .gjr-sub,.gjr-header span{display:none !important}}',
    /* El campo de archivo que ya tiene su propio botón, oculto */
    '.mrc-oculto{display:none !important}',

    /* Las pestañas del módulo quedan pegadas justo debajo */
    '.tabs,.tab-bar,.nav-tabs{position:sticky !important;top:0 !important;z-index:40}',

    /* ── Menú lateral ── */
    '#mrc-lat{position:fixed;left:0;top:' + ALTO_NAV + 'px;bottom:' + ALTO_PIE + 'px;',
    '  width:' + ANCHO + 'px;background:#1D4423;overflow-y:auto;padding:9px 0 20px;z-index:70;',
    "  font-family:'DM Sans',system-ui,sans-serif}",
    '#mrc-lat .g{color:rgba(255,255,255,.38);font-size:9.5px;font-weight:600;',
    '  letter-spacing:.11em;text-transform:uppercase;padding:13px 16px 5px}',
    '#mrc-lat a{display:flex;align-items:center;gap:8px;color:rgba(255,255,255,.78);',
    '  font-size:13px;padding:8px 16px;text-decoration:none;border-left:3px solid transparent}',
    '#mrc-lat a:hover{background:rgba(255,255,255,.07);color:#fff}',
    '#mrc-lat a.on{background:rgba(255,255,255,.12);color:#fff;border-left-color:#F9A825;font-weight:500}',
    '#mrc-lat .marca{display:flex;align-items:center;padding:12px 16px 14px;',
    '  border-bottom:1px solid rgba(255,255,255,.10);margin-bottom:4px}',
    '#mrc-lat .marca img{height:26px;filter:brightness(0) invert(1)}',

    /* ── Barra de estado ── */
    '#mrc-pie{position:fixed;left:0;right:0;bottom:0;height:' + ALTO_PIE + 'px;background:#122E16;',
    "  color:rgba(255,255,255,.55);font:400 11px/1 'DM Sans',system-ui,sans-serif;",
    '  display:flex;align-items:center;gap:16px;padding:0 16px;z-index:70}',
    '#mrc-pie .pt{width:6px;height:6px;border-radius:50%;background:#43A047;display:inline-block}',
    '#mrc-pie .der{margin-left:auto}',

    '@media(max-width:900px){',
    '  body{padding-left:0 !important;padding-top:' + (ALTO_NAV + ALTO_CAB) + 'px !important}',
    '  .gjr-header{left:0 !important}',
    '  #mrc-lat{left:-' + ANCHO + 'px;transition:left .2s ease}',
    '  #mrc-lat.abierto{left:0;box-shadow:4px 0 22px rgba(0,0,0,.3)}',
    '  #mrc-menu{display:inline-flex !important}}',
    '#mrc-menu{display:none;position:fixed;left:8px;top:' + (ALTO_NAV + 9) + 'px;z-index:80;',
    '  background:rgba(255,255,255,.12);border:1px solid rgba(255,255,255,.22);color:#fff;',
    '  border-radius:4px;width:32px;height:32px;align-items:center;justify-content:center;font-size:15px}',

    '@media print{#mrc-lat,#mrc-pie,#mrc-menu{display:none}',
    '  body{padding:0 !important}.gjr-header{position:static !important}}'
  ].join('\n');
  document.head.appendChild(st);

  /* ── Menú ── */
  var logo = (document.querySelector('.gjr-logo img, .gjr-header img') || {}).src || '';
  var lat = document.createElement('nav');
  lat.id = 'mrc-lat';
  lat.innerHTML =
    '<div class="marca">' + (logo ? '<img src="' + esc(logo) + '" alt="Grupo Juan Ruiz">' : '')
    + '</div>'
    + MENU.map(function (g) {
        return '<div class="g">' + esc(g[0]) + '</div>'
          + g[1].map(function (i) {
              var on = i[1].toLowerCase() === actual ? ' class="on"' : '';
              return '<a href="' + i[1] + '"' + on + '>' + esc(i[0]) + '</a>';
            }).join('');
      }).join('');

  /* ── Barra de estado ── */
  var titulo = (document.querySelector('.gjr-header h1') || {}).textContent || '';
  var pie = document.createElement('footer');
  pie.id = 'mrc-pie';
  pie.innerHTML = '<span><span class="pt"></span> Conectado</span>'
    + '<span>' + esc(titulo.trim()) + '</span>'
    + '<span class="der">Grupo Juan Ruiz S.A.C.</span>';

  /* ── Botón del menú en pantallas estrechas ── */
  var bot = document.createElement('button');
  bot.id = 'mrc-menu'; bot.type = 'button'; bot.textContent = '☰';
  bot.addEventListener('click', function () { lat.classList.toggle('abierto'); });

  /* Cuando el módulo ya tiene una etiqueta que abre el selector
     ("Cargar Excel"), el campo de archivo sobra: son dos botones para
     lo mismo. Se oculta el campo y manda la etiqueta, que es la que
     el módulo diseñó. */
  function unificarCarga() {
    var labels = document.querySelectorAll('label[for]');
    for (var i = 0; i < labels.length; i++) {
      var destino = document.getElementById(labels[i].getAttribute('for'));
      if (destino && destino.type === 'file') destino.classList.add('mrc-oculto');
    }
  }

  function montar() {
    if (document.getElementById('mrc-lat')) return;
    unificarCarga();
    document.body.appendChild(lat);
    document.body.appendChild(pie);
    document.body.appendChild(bot);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar);
  else montar();
})();
