/* ══════════════════════════════════════════════════════════════
   acceso.js · Acceso único con usuario de Supabase
   Va en el <head> de TODAS las pantallas, antes que cualquier otro script:
       <script src="acceso.js?v=1"></script>

   QUÉ HACE
   1. Sin sesión iniciada, ninguna pantalla se muestra: lleva al acceso
      (index.html) y, al entrar, vuelve a la pantalla pedida.
   2. Comprueba que el usuario está dado de alta y activo en erp_usuario
      y que tiene permiso para ese módulo.
   3. Las pantallas de GJR guardan en la nube (gjr_kv) con llamadas
      directas; aquí se les pone el token del usuario, de modo que la
      base solo acepta a usuarios con sesión.
   4. Mantiene la sesión renovada mientras la pantalla esté abierta.
   ══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  var SB_URL = 'https://riidmxztyxldnojjkncx.supabase.co';
  var SB_KEY = 'sb_publishable_ZbMZbTdBcYnGceF_woayjQ_CCCEHRYS';
  var CLAVE  = 'sb-riidmxztyxldnojjkncx-auth-token';
  var LIB    = 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.js';

  var pagina = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
  var ES_ACCESO = (pagina === 'index.html' || pagina === '');

  /* Módulo de cada pantalla (mismas claves que el índice). Las que no
     están aquí (manuales) las ve cualquier usuario con sesión. */
  var MODULO = {
    'tb.html': 'partidas', 'cuadro_mando.html': 'cuadro', 'compras.html': 'compras',
    'almacen_v7.html': 'almacen', 'calidad.html': 'calidad', 'facturacion_v22.html': 'ventas',
    'fiscal.html': 'fiscal', 'facturas.html': 'facturas', 'analisis_liquidaciones_v1.html': 'liqui_tb',
    'gestion.html': 'gestion',
    'sistema_trazabilidad_grupo_juan_ruiz.html': 'traza', 'dashboard_defectos_criticos.html': 'defectos',
    'descarte.html': 'descarte', 'liquidaciones_app_v6.html': 'liqui_gjr', 'crm.html': 'crm',
    'control_divisas.html': 'divisas', 'viaticos.html': 'viaticos',
    'reporte_gerencial.html': 'reporte', 'manual_reporte.html': 'manual_rep'
  };

  function irAlAcceso(motivo) {
    var q = '?volver=' + encodeURIComponent(pagina + location.search + location.hash);
    if (motivo) q += '&motivo=' + encodeURIComponent(motivo);
    location.replace('index.html' + q);
  }

  /* Sesión guardada (lectura rápida, sin esperar a la librería) */
  function sesionGuardada() {
    try {
      var v = localStorage.getItem(CLAVE);
      if (!v) return null;
      if (v.indexOf('base64-') === 0) v = decodeURIComponent(escape(atob(v.slice(7))));
      var s = JSON.parse(v);
      return (s && (s.access_token || (s.currentSession && s.currentSession))) ? (s.currentSession || s) : null;
    } catch (e) { return null; }
  }

  var guardada = sesionGuardada();
  if (!ES_ACCESO) {
    /* Nada se ve hasta comprobar quién es */
    document.documentElement.style.visibility = 'hidden';
    if (!guardada || !guardada.refresh_token) { irAlAcceso(); return; }
  }

  /* ── Cliente de Supabase ──────────────────────────────────────── */
  var cliente = null;
  var resolverListo;
  var listo = new Promise(function (r) { resolverListo = r; });

  function crearCliente() {
    try {
      cliente = window.supabase.createClient(SB_URL, SB_KEY, {
        auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: ES_ACCESO }
      });
    } catch (e) { cliente = null; }
    resolverListo(cliente);
  }
  if (window.supabase && window.supabase.createClient) crearCliente();
  else {
    var s = document.createElement('script');
    s.src = LIB;
    s.onload = crearCliente;
    s.onerror = function () { resolverListo(null); };
    (document.head || document.documentElement).appendChild(s);
  }

  /* Token vigente del usuario (renovado si hace falta) */
  function token() {
    var g = sesionGuardada();
    var ahora = Math.floor(Date.now() / 1000);
    if (g && g.access_token && g.expires_at && g.expires_at - ahora > 60 && !cliente) {
      return Promise.resolve(g.access_token);
    }
    return listo.then(function (c) {
      if (!c) { var g2 = sesionGuardada(); return g2 ? g2.access_token : null; }
      return c.auth.getSession().then(function (r) {
        return r && r.data && r.data.session ? r.data.session.access_token : null;
      });
    });
  }

  /* ── Llamadas directas a la base (módulos GJR): con el token del usuario ── */
  var fetchOriginal = window.fetch ? window.fetch.bind(window) : null;
  if (fetchOriginal) {
    window.fetch = function (entrada, init) {
      try {
        var url = typeof entrada === 'string' ? entrada : (entrada && entrada.url) || '';
        if (url.indexOf(SB_URL + '/rest/v1/') === 0 || url.indexOf(SB_URL + '/storage/v1/') === 0) {
          var h = new Headers((init && init.headers) || (entrada && entrada.headers) || {});
          var a = h.get('Authorization') || '';
          if (!a || a === 'Bearer ' + SB_KEY) {
            return token().then(function (t) {
              if (t) h.set('Authorization', 'Bearer ' + t);
              var ini = {};
              if (init) for (var k in init) ini[k] = init[k];
              ini.headers = h;
              return fetchOriginal(entrada, ini);
            });
          }
        }
      } catch (e) {}
      return fetchOriginal(entrada, init);
    };
  }

  /* ── Perfil del usuario y permisos ────────────────────────────── */
  function sinFuncion(e) {
    return e && (e.code === 'PGRST202' || /Could not find the function|does not exist/i.test(e.message || ''));
  }
  var perfil = null;
  function mostrar() { document.documentElement.style.visibility = ''; }

  function comprobar() {
    return listo.then(function (c) {
      if (!c) {
        /* Sin librería (sin conexión): solo con una sesión aún vigente */
        var g = sesionGuardada();
        if (!ES_ACCESO && (!g || (g.expires_at && g.expires_at * 1000 < Date.now()))) irAlAcceso();
        else mostrar();
        return null;
      }
      return c.auth.getSession().then(function (r) {
        var ses = r && r.data && r.data.session;
        if (!ses) { if (!ES_ACCESO) irAlAcceso(); return null; }
        return c.rpc('erp_mi_perfil').then(function (p) {
          if (p.error && sinFuncion(p.error)) {
            /* La base aún no tiene el script 19: se entra sin límites de módulo
               (los datos siguen protegidos por los permisos de la base). */
            p = { data: { id: ses.user.id, email: ses.user.email, nombre: ses.user.email, rol: null, modulos: null, cambiar_clave: false } };
          }
          if (p.error || !p.data) {
            /* Sin alta en el ERP o desactivado: fuera */
            if (!ES_ACCESO) {
              return c.auth.signOut().then(function () { irAlAcceso('sin_alta'); });
            }
            return null;
          }
          perfil = p.data;
          try {
            sessionStorage.setItem('gjr_nombre', perfil.nombre || perfil.email);
            sessionStorage.setItem('gjr_user', (perfil.email || '').split('@')[0]);
          } catch (e) {}
          if (!ES_ACCESO) {
            if (perfil.cambiar_clave) { irAlAcceso('cambiar_clave'); return perfil; }
            var mod = MODULO[pagina];
            if (mod && perfil.modulos && perfil.modulos.indexOf(mod) < 0) { irAlAcceso('sin_permiso'); return perfil; }
            mostrar();
          }
          try { document.dispatchEvent(new CustomEvent('gjr:acceso', { detail: perfil })); } catch (e) {}
          return perfil;
        });
      });
    }).catch(function () { if (!ES_ACCESO) irAlAcceso(); return null; });
  }
  var comprobado = comprobar();

  function salir() {
    var fin = function () {
      try {
        for (var i = localStorage.length - 1; i >= 0; i--) {
          var k = localStorage.key(i);
          if (/^sb-.*-auth-token(\.\d+)?$/.test(k)) localStorage.removeItem(k);
        }
        sessionStorage.clear();
      } catch (e) {}
      location.href = 'index.html';
    };
    listo.then(function (c) { return c ? c.auth.signOut() : null; }).then(fin, fin);
  }

  /* Lectura de una clave de la nube GJR (para datos que ya no van en el código) */
  function leerNube(clave) {
    return fetch(SB_URL + '/rest/v1/gjr_kv?select=datos&id=eq.' + encodeURIComponent(clave), {
      headers: { apikey: SB_KEY, Authorization: 'Bearer ' + SB_KEY }
    }).then(function (r) { return r.ok ? r.json() : []; }).then(function (f) {
      var d = f && f[0] && f[0].datos;
      if (!d || d.value === undefined) return null;
      try { return typeof d.value === 'string' ? JSON.parse(d.value) : d.value; } catch (e) { return d.value; }
    });
  }

  window.GJRAcceso = {
    listo: listo, comprobado: comprobado, salir: salir, token: token, leerNube: leerNube,
    perfil: function () { return perfil; }, modulo: function (p) { return MODULO[p || pagina]; },
    MODULO: MODULO, sinFuncion: sinFuncion
  };
})();
