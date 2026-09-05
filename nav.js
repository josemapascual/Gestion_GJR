/* ══════════════════════════════════════════════════════════════
   nav.js · Barra de módulos común
   Se añade a cualquier pantalla con una sola línea, antes de </body>:
       <script src="nav.js"></script>

   Todas las clases llevan el prefijo nvg- para que NUNCA choquen
   con el CSS de la página que la aloja. (Antes usaba .emp y .sep,
   nombres que index.html también usaba para sus tarjetas: por eso
   salía un recuadro blanco con el texto invisible dentro.)
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  var MODULOS = {
    tb: {
      etiqueta: 'Tropical Báez',
      inicio: 'tb.html',
      items: [
        ['Partidas',         'tb.html'],
        ['Cuadro de mandos', 'cuadro_mando.html'],
        ['Compras',          'compras.html'],
        ['Almacén',          'almacen_v7.html'],
        ['Calidad',          'calidad.html'],
        ['Ventas',           'facturacion_v21.html'],
        ['Facturas',         'facturas.html'],
        ['Liquidaciones',    'analisis_liquidaciones_v1.html'],
        ['Gestión',          'gestion.html'],
        ['Manual',           'manual.html'],
        ['Facturar',         'manual_paola.html'],
        ['Regímenes',        'manual_facturacion.html']
      ]
    },
    gjr: {
      etiqueta: 'Grupo Juan Ruiz',
      inicio: 'gjr.html',
      items: [
        ['Trazabilidad',  'sistema_trazabilidad_grupo_juan_ruiz.html'],
        ['Defectos',      'dashboard_defectos_criticos.html'],
        ['Descarte',      'descarte.html'],
        ['Liquidaciones', 'liquidaciones_app_v6.html'],
        ['CRM',           'crm.html'],
        ['Divisas',       'control_divisas.html'],
        ['Viáticos',      'viaticos.html']
      ]
    }
  };

  var ALTO = 34;
  var actual = (location.pathname.split('/').pop() || 'index.html').toLowerCase();

  var empresa = null;
  for (var k in MODULOS) {
    if (MODULOS[k].items.some(function (i) { return i[1].toLowerCase() === actual; })
        || MODULOS[k].inicio.toLowerCase() === actual) { empresa = k; }
  }
  if (actual === 'index.html' || actual === '') empresa = null;

  var esc = function (s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  };

  var css = document.createElement('style');
  css.textContent = [
    '#nvg-barra{position:fixed;top:0;left:0;right:0;height:' + ALTO + 'px;z-index:99999;',
    '  background:#0E2412;display:flex;align-items:center;gap:2px;padding:0 10px;',
    "  font:500 12px/1 'DM Sans',system-ui,sans-serif;overflow-x:auto;scrollbar-width:none;",
    '  box-shadow:0 1px 0 rgba(255,255,255,.08)}',
    '#nvg-barra::-webkit-scrollbar{display:none}',
    '#nvg-barra *{background:none;border:0;border-radius:0;box-shadow:none;margin:0;',
    '  text-transform:none;letter-spacing:normal;font:inherit;color:rgba(255,255,255,.72)}',
    '#nvg-barra .nvg-i{display:inline-block;padding:6px 10px;border-radius:4px;',
    '  text-decoration:none;white-space:nowrap}',
    '#nvg-barra .nvg-i:hover{background:rgba(255,255,255,.10);color:#fff}',
    '#nvg-barra .nvg-i.nvg-on{background:rgba(255,255,255,.16);color:#fff;',
    '  box-shadow:inset 0 -2px 0 #F9A825}',
    '#nvg-barra .nvg-emp{color:#fff;font-weight:600;padding:6px 10px 6px 4px;white-space:nowrap}',
    '#nvg-barra .nvg-sep{width:1px;height:16px;background:rgba(255,255,255,.16);',
    '  flex:none;margin:0 6px}',
    '#nvg-barra .nvg-otra{margin-left:auto;padding-left:14px}',
    '#nvg-barra .nvg-sep2{width:1px;height:16px;background:rgba(255,255,255,.16);',
    '  flex:none;margin:0 8px}',
    '#nvg-barra .nvg-yo{color:rgba(255,255,255,.62);white-space:nowrap;padding:6px 2px}',
    '#nvg-barra .nvg-salir{color:rgba(255,255,255,.78)}',
    'body{padding-top:' + ALTO + 'px !important}',
    '.topbar{top:' + ALTO + 'px !important}',
    '.tabs{top:' + (ALTO + 50) + 'px !important}',
    '.app{height:calc(100vh - ' + ALTO + 'px) !important}',
    '@media print{#nvg-barra{display:none}body{padding-top:0 !important}}'
  ].join('\n');
  document.head.appendChild(css);

  var html = '<a class="nvg-i" href="index.html">◄ Inicio</a><span class="nvg-sep"></span>';

  if (empresa) {
    var m = MODULOS[empresa];
    html += '<span class="nvg-emp">' + esc(m.etiqueta) + '</span>';
    html += m.items.map(function (i) {
      var on = i[1].toLowerCase() === actual ? ' nvg-on' : '';
      return '<a class="nvg-i' + on + '" href="' + i[1] + '">' + esc(i[0]) + '</a>';
    }).join('');
    var otra = empresa === 'tb' ? 'gjr' : 'tb';
    html += '<a class="nvg-i nvg-otra" href="' + MODULOS[otra].inicio + '">'
          + esc(MODULOS[otra].etiqueta) + ' \u25BA</a>';
    html += '<span class="nvg-sep2"></span>';
  } else {
    html += '<a class="nvg-i" href="tb.html">Tropical B\u00e1ez</a>'
          + '<a class="nvg-i" href="gjr.html">Grupo Juan Ruiz</a>';
  }

  /* Identidad: se lee de la sesión que guarda Supabase en el navegador,
     así aparece igual en las 20 pantallas sin depender de cada módulo. */
  function correoSesion(){
    try{
      for (var i = 0; i < localStorage.length; i++){
        var k = localStorage.key(i);
        if (!/^sb-.*-auth-token$/.test(k)) continue;
        var v = localStorage.getItem(k) || '';
        if (v.indexOf('base64-') === 0) v = atob(v.slice(7));
        var s = JSON.parse(v);
        var u = (s && (s.user || (s.currentSession && s.currentSession.user))) || null;
        if (u && u.email) return u.email;
      }
    }catch(e){}
    return null;
  }

  var correo = correoSesion();
  html += '<span class="nvg-yo">' + (correo ? esc(correo) : 'Sin sesión') + '</span>';
  if (correo) html += '<button class="nvg-i nvg-salir" type="button">Salir</button>';

  var barra = document.createElement('div');
  barra.id = 'nvg-barra';
  barra.innerHTML = html;

  var bs = barra.querySelector('.nvg-salir');
  if (bs) bs.addEventListener('click', function(){
    try{
      for (var i = localStorage.length - 1; i >= 0; i--){
        var k = localStorage.key(i);
        if (/^sb-.*-auth-token$/.test(k)) localStorage.removeItem(k);
      }
      sessionStorage.clear();
    }catch(e){}
    location.href = 'index.html';
  });

  function montar() {
    if (document.getElementById('nvg-barra')) return;
    document.body.insertBefore(barra, document.body.firstChild);
    var act = barra.querySelector('.nvg-on');
    if (act && act.scrollIntoView) act.scrollIntoView({block: 'nearest', inline: 'center'});
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', montar);
  else montar();
})();
