/* tb_fiscal_engine.js — Motor de determinación de IVA de Tropical Báez (v2)
 * Tres capas separadas:
 *   1. Datos      → si falta un dato crítico: «REVISIÓN FISCAL NECESARIA» con la lista exacta.
 *   2. Ley        → la matriz (erp_fiscal_regla) decide el tratamiento solo con hechos de la operación.
 *   3. Habilitación → las identificaciones de TB (ES propia, NL vía Exonero, escenarios) deciden si
 *                     TB puede emitirla hoy. Si no: NO_HABILITADA, con el tratamiento completo y qué
 *                     identificación la permitiría (ampliar licencia, NIF NL propio…).
 * Solo el estado OK numera la factura. Sin dependencias.
 * Uso: const ctx = await TBFiscal.cargarContexto(supabase); TBFiscal.determinar(hechos, ctx)
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.TBFiscal = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const MOTOR_VERSION = '2.2.0';
  const REVISION = 'REVISIÓN FISCAL NECESARIA';
  const NO_HABILITADA = 'OPERACIÓN NO HABILITADA CON LAS IDENTIFICACIONES ACTUALES';
  const ESTADOS_ADUANEROS = ['LIBRE_PRACTICA', 'DEPOSITO_ADUANERO', 'NO_DESPACHADA', 'EN_ORIGEN'];
  const TIPOS_CLIENTE = ['B2B_VAT', 'B2B_SIN_VAT', 'B2C'];
  const EVENTOS = ['VENTA', 'TRANSFERENCIA', 'COMPRA', 'IMPORTACION'];
  const ENTRADAS_NL = ['IMPORTACION', 'COMPRA_LOCAL', 'ADQUISICION_UE'];
  const SINONIMOS_ENTRADA = { TRANSFERENCIA: 'ADQUISICION_UE', COMPRA_UE: 'ADQUISICION_UE' };
  const ESTADOS_NO_RECTIFICABLES = ['BORRADOR', 'ANULADA', 'RECHAZADA', 'CONVERTIDA'];
  const JURIS = ['ES', 'NL'];

  // ---------------------------------------------------------------- utilidades
  const r2 = (n) => Math.round((Number(n) + Number.EPSILON) * 100) / 100;
  const vigente = (row, fecha) =>
    (!row.vigente_desde || row.vigente_desde <= fecha) && (!row.vigente_hasta || fecha <= row.vigente_hasta);
  const dias = (a, b) => Math.floor((Date.parse(b) - Date.parse(a)) / 86400000);
  const prefijoVat = (vat) => (vat || '').replace(/[\s.\-]/g, '').toUpperCase().slice(0, 2);
  const masAnios = (f, n) => { const d = new Date(f + 'T00:00:00Z'); d.setUTCFullYear(d.getUTCFullYear() + n); return d.toISOString().slice(0, 10); };
  const fechaEs = (f) => { const p = String(f || '').slice(0, 10).split('-'); return p.length === 3 ? p[2] + '/' + p[1] + '/' + p[0] : (f || ''); };

  // ---------------------------------------------------------------- carga desde Supabase
  async function cargarContexto(sb) {
    const t = async (tabla, filtro) => {
      let q = sb.from(tabla).select('*');
      if (filtro) q = filtro(q);
      const { data, error } = await q;
      if (error) throw new Error(`${tabla}: ${error.message}`);
      return data || [];
    };
    const [territorios, tipos, textos, incoterms, config, representantes, identificaciones, coberturas, reglas] =
      await Promise.all([
        t('erp_fiscal_territorio'), t('erp_fiscal_tipo_iva'), t('erp_fiscal_texto_legal'),
        t('erp_fiscal_incoterm'), t('erp_fiscal_config'), t('erp_fiscal_representante'),
        t('erp_fiscal_identificacion'), t('erp_fiscal_cobertura'), t('erp_fiscal_regla', (q) => q.eq('activo', true))
      ]);
    const cfg = {};
    config.forEach((c) => { cfg[c.clave] = c.valor; });
    return { territorios, tipos, textos, incoterms, config: cfg, representantes, identificaciones, coberturas, reglas };
  }

  // ---------------------------------------------------------------- identificaciones
  // Devuelve [] si la identificación puede emitir en esa fecha; si no, los motivos.
  function motivosIdentificacion(i, fecha, ctx, simular) {
    if (simular && simular === i.codigo) return [];   // simulación: se supone operativa
    const m = [];
    const rep = i.representante_codigo ? (ctx.representantes || []).find((r) => r.codigo === i.representante_codigo) : null;
    if (i.estado !== 'ACTIVA') m.push(`estado ${i.estado}`);
    if (fecha && !vigente(i, fecha)) m.push('fuera de vigencia');
    if (!i.vat || /PENDIENTE/.test(i.vat)) m.push('sin NIF-IVA para la factura');
    if (i.modalidad === 'REP_LIMITADA' && !i.numero_representacion) m.push('sin subnúmero de representación');
    if (i.representante_codigo) {
      if (!rep || rep.activo === false) m.push(`representante ${i.representante_codigo} inexistente o inactivo`);
      else {
        if (!rep.direccion) m.push('falta dirección del representante');
        if (!rep.vat_number) m.push('falta NIF-IVA del representante');
        if (fecha && !vigente(rep, fecha)) m.push('representación no vigente');
        if (rep.garantia_requerida) {
          if (!rep.garantia_importe) m.push('falta importe de la garantía');
          if (!rep.garantia_vencimiento || (fecha && rep.garantia_vencimiento < fecha)) m.push('garantía sin vencimiento o vencida');
        }
      }
    }
    return m;
  }

  // ---------------------------------------------------------------- motor
  function determinar(h, ctx) {
    h = h || {};
    const faltan = [];
    const avisos = [];
    const falta = (campo, motivo) => faltan.push({ campo, motivo });
    const cfg = ctx.config || {};
    const terr = (c) => ctx.territorios.find((x) => x.codigo === c) || null;
    const idents = ctx.identificaciones || [];

    const evento = h.evento || 'VENTA';
    const fecha = h.fecha_devengo;
    const m = h.mercancia || {};
    const cli = h.cliente || {};
    const prov = h.proveedor || {};
    const tr = h.transporte || {};
    const ad = h.aduana || {};
    const esp = h.especiales || {};
    const ovr = h.override || {};
    const simular = h.simular_identificacion || null;

    const rect = h.rectificacion || null;

    // 0. Fuera de alcance: documento sin líneas de mercancía (comisiones, servicios) --------
    const lineasIn = h.lineas || [];
    if (lineasIn.length && lineasIn.every((l) => l.tipo === 'SERVICIO') && !rect)
      return { estado: 'NO_APLICA', mensaje: 'Solo servicios: la matriz de mercancías no aplica; el documento conserva su régimen.',
        motor_version: MOTOR_VERSION, faltantes: [], avisos: [], hechos: h };

    // 1. Datos mínimos ---------------------------------------------------------------
    if (m.mezcla && m.mezcla.length)
      falta('mercancia.mezcla', `El documento mezcla mercancía en situaciones fiscales distintas (${m.mezcla.join(' / ')}). Emitir una factura por almacén y estatuto aduanero.`);
    if (rect) {
      // Rectificativa por diferencias: misma operación y mismo devengo que la factura original
      if (!rect.documento_id && !rect.documento) falta('rectificacion.documento', 'Falta la factura que se rectifica.');
      if (!rect.motivo) falta('rectificacion.motivo', 'Falta el motivo de la rectificación (p. ej., precio definitivo según la liquidación del cliente).');
      if (rect.estado_original && ESTADOS_NO_RECTIFICABLES.includes(rect.estado_original))
        falta('rectificacion.documento', `La factura ${rect.documento || ''} está ${rect.estado_original}: solo se rectifica una factura emitida.`);
      if (rect.fecha_expedicion && fecha && rect.fecha_expedicion > masAnios(fecha, 4))
        falta('rectificacion.plazo', `Han pasado más de cuatro años desde el devengo de ${rect.documento || 'la factura original'} (${fechaEs(fecha)}): art. 15.3 RD 1619/2012.`);
      if (lineasIn.length && lineasIn.every((l) => l.tipo === 'SERVICIO'))
        falta('rectificacion.lineas', 'La rectificativa de una venta de mercancía debe llevar la diferencia en una línea de mercancía.');
    }
    if (!EVENTOS.includes(evento)) falta('evento', `Evento desconocido: ${evento}.`);
    if (!fecha) falta('fecha_devengo', 'Falta la fecha de devengo (entrega, puesta a disposición o despacho).');
    if (!m.ubicacion) falta('mercancia.ubicacion', 'Falta el país donde está físicamente la mercancía en el momento de la operación.');
    if (!ESTADOS_ADUANEROS.includes(m.estado_aduanero))
      falta('mercancia.estado_aduanero', 'Falta el estado aduanero de la mercancía (libre práctica, depósito aduanero, no despachada o en origen).');
    if (!m.categoria_iva) falta('mercancia.categoria_iva', 'Falta la categoría de IVA del producto.');
    const enUE = m.estado_aduanero === 'LIBRE_PRACTICA';
    if (['VENTA', 'TRANSFERENCIA'].includes(evento) && !h.destino) falta('destino', 'Falta el país de destino.');
    if (evento === 'COMPRA' && enUE && !h.destino) falta('destino', 'Falta el país de llegada de la mercancía comprada.');

    const tU = m.ubicacion ? terr(m.ubicacion) : null;
    const tD = h.destino ? terr(h.destino) : null;
    if (m.ubicacion && !tU) falta('mercancia.ubicacion', `Territorio no parametrizado: ${m.ubicacion}.`);
    if (h.destino && !tD) falta('destino', `Territorio no parametrizado: ${h.destino}.`);

    if (evento === 'VENTA') {
      if (!TIPOS_CLIENTE.includes(cli.tipo)) falta('cliente.tipo', 'Falta el tipo de cliente (empresa con NIF-IVA, empresa sin NIF-IVA o particular).');
      if (!cli.pais_establecimiento) falta('cliente.pais_establecimiento', 'Falta el país donde está establecido el cliente.');
      if (cli.tipo === 'B2B_VAT' && !cli.vat) falta('cliente.vat', 'Cliente empresa sin NIF-IVA informado.');
    }
    if (evento === 'COMPRA' && !prov.pais_establecimiento)
      falta('proveedor.pais_establecimiento', 'Falta el país donde está establecido el proveedor.');
    if (evento === 'IMPORTACION' && !ad.regimen_importacion)
      falta('aduana.regimen_importacion', 'Falta el régimen de importación (40, 42 o DEPOSITO).');
    if (evento === 'IMPORTACION' && m.estado_aduanero === 'LIBRE_PRACTICA')
      falta('mercancia.estado_aduanero', 'Una importación parte de mercancía no despachada o en depósito, no en libre práctica.');

    // 2. Flujo ----------------------------------------------------------------------
    let flujo = null;
    if (tU && m.estado_aduanero) {
      if (evento === 'IMPORTACION') flujo = 'IMPORTACION';
      else if (m.estado_aduanero === 'EN_ORIGEN') flujo = 'FUERA_UE';
      // No despachada: si ya está físicamente en un EM (puerto, depósito temporal) la entrega
      // se localiza allí bajo régimen aduanero; si está en origen o en el mar, fuera del IVA UE.
      else if (m.estado_aduanero === 'NO_DESPACHADA') flujo = tU.estado_miembro ? 'DEPOSITO' : 'FUERA_UE';
      else if (m.estado_aduanero === 'DEPOSITO_ADUANERO') flujo = 'DEPOSITO';
      else if (!tU.estado_miembro) falta('mercancia.ubicacion', `Mercancía en libre práctica en ${tU.nombre}, fuera del IVA UE: TB no tiene identificación fiscal allí.`);
      else if (tD) flujo = tD.estado_miembro ? (tD.estado_miembro === tU.estado_miembro ? 'INTERIOR' : 'INTRA_UE') : 'EXTRA_UE';
    }
    if (evento === 'COMPRA' && flujo === 'EXTRA_UE')
      falta('destino', 'Compra en la UE con destino fuera de la UE: registrar la compra con llegada al país de salida y la exportación como venta o traslado.');

    // 3. Transporte e Incoterm ----------------------------------------------------------
    const inc = tr.incoterm ? ctx.incoterms.find((x) => x.codigo === tr.incoterm) : null;
    if (tr.incoterm && !inc) falta('transporte.incoterm', `Incoterm no parametrizado: ${tr.incoterm}.`);
    const hayMovimiento = ['INTRA_UE', 'EXTRA_UE', 'FUERA_UE'].includes(flujo) || evento === 'TRANSFERENCIA';
    if (hayMovimiento && evento === 'VENTA' && !tr.incoterm) falta('transporte.incoterm', 'Falta el Incoterm.');
    let transportePor = tr.por || (inc ? inc.transporte_principal : null) || (evento === 'TRANSFERENCIA' ? 'VENDEDOR' : null);
    if (tr.por && inc && tr.por !== inc.transporte_principal)
      avisos.push(`El transporte declarado (${tr.por}) no coincide con el que implica ${inc.codigo} (${inc.transporte_principal}). Prevalece el declarado.`);
    if (hayMovimiento && evento !== 'COMPRA' && flujo !== 'FUERA_UE' && !transportePor)
      falta('transporte.por', 'Falta quién organiza el transporte (TB o el comprador).');

    // 4. Aduana -----------------------------------------------------------------------
    let importador = 'NO_APLICA';
    let exportador = 'NO_APLICA';
    if (flujo === 'FUERA_UE' && evento === 'VENTA') {
      importador = ad.importador || null;
      if (!importador) falta('aduana.importador', 'Venta antes del despacho: falta quién importa (TB o el cliente).');
    }
    if (flujo === 'EXTRA_UE') {
      importador = tr.incoterm === 'DDP' ? 'TB' : 'CLIENTE';
      // Exportador aduanero: el que dice el documento; si no, TB cuando transporta o cuando el
      // Incoterm deja el despacho de exportación al vendedor (todos salvo EXW).
      exportador = ad.exportador || ((transportePor === 'VENDEDOR' || (inc && inc.despacho_exportacion === 'VENDEDOR')) ? 'TB' : null);
      if (!exportador) falta('aduana.exportador', 'Exportación: falta el exportador aduanero (debe estar establecido en la UE).');
    }
    if (flujo === 'IMPORTACION') importador = 'TB';

    // 5. Jurisdicción (la decide la ubicación de la mercancía, no la elección del usuario) --
    let perfil = null;
    const emU = tU && tU.estado_miembro;
    const emD = tD && tD.estado_miembro;
    if (flujo === 'FUERA_UE') perfil = 'ES';
    else if (evento === 'COMPRA' && flujo === 'INTRA_UE') {
      if (esp.triangular) {
        perfil = 'ES';
        if (emU === 'ES' || emD === 'ES') falta('especiales.triangular', 'Triangular: ni la salida ni la llegada pueden ser España (TB está identificada allí).');
      }
      else if (JURIS.includes(emD)) perfil = emD;
      else falta('destino', `Compra con llegada a ${tD ? tD.nombre : h.destino}: TB no tiene identificación de IVA allí.`);
    } else if (emU) {
      if (esp.triangular && evento === 'VENTA') {
        perfil = 'ES';
        if (emU === 'ES') falta('especiales.triangular', 'Triangular con salida desde España: TB no puede actuar como intermediario con NIF español.');
        if (emD === 'ES') falta('especiales.triangular', 'Triangular con llegada a España: TB está identificada en el EM de llegada.');
      } else if (JURIS.includes(emU)) perfil = emU;
      else falta('perfil_vendedor', `La operación se localiza en ${tU.nombre} y TB no tiene identificación de IVA allí.`);
    }
    if (h.perfil_solicitado && perfil && h.perfil_solicitado !== perfil)
      falta('perfil_vendedor', `Se ha elegido operar desde ${h.perfil_solicitado} pero la mercancía está en ${m.ubicacion}: corresponde la identificación ${perfil}.`);

    // Origen del stock en NL (decide la cobertura de una licencia limitada)
    let entradaNL = m.entrada_nl || (['40', '42'].includes(ad.regimen_importacion) ? 'IMPORTACION' : null);
    if (entradaNL && SINONIMOS_ENTRADA[entradaNL]) entradaNL = SINONIMOS_ENTRADA[entradaNL];
    const movimientoInterno = evento === 'TRANSFERENCIA' && flujo === 'INTERIOR';
    if (perfil === 'NL' && ['VENTA', 'TRANSFERENCIA'].includes(evento) && flujo !== 'DEPOSITO' && !movimientoInterno) {
      if (!entradaNL) falta('mercancia.entrada_nl', 'Falta cómo entró la mercancía en NL: importada por TB, comprada en NL o llegada desde otro país UE.');
      else if (!ENTRADAS_NL.includes(entradaNL)) falta('mercancia.entrada_nl', `Valor no válido: ${entradaNL}.`);
    }
    const esImportada = entradaNL === 'IMPORTACION' || evento === 'IMPORTACION';

    // 6. VIES y override ----------------------------------------------------------------
    const vies = cli.vies || {};
    let viesEstado = vies.estado || null;
    if (viesEstado === 'VALIDO' && vies.fecha && fecha && dias(vies.fecha, fecha) > Number(cfg.vies_max_dias ?? 7))
      viesEstado = 'CADUCADO';
    const vatMsDistinto = cli.vat && tU ? prefijoVat(cli.vat) !== tU.estado_miembro : null;
    const icsOk = cli.tipo === 'B2B_VAT' && viesEstado === 'VALIDO' && vatMsDistinto === true;
    if (ovr.forzar_iva_origen && (!ovr.usuario || !ovr.motivo))
      falta('override', 'La autorización para facturar con IVA de origen requiere usuario y motivo.');

    if (faltan.length) return bloqueo(faltan, avisos, h, { flujo, perfil });

    // 7. Hechos de la operación (no dependen de cómo esté registrada TB en NL) ---------------
    const esId = idents.find((i) => i.jurisdiccion === 'ES' && i.estado === 'ACTIVA') || {};
    const roi = esId.roi_alta === true && (!esId.roi_desde || !fecha || fecha >= esId.roi_desde);
    const base = {
      evento, perfil, flujo,
      zona_destino: tD ? tD.zona : null,
      cliente_tipo: cli.tipo || null,
      vies: viesEstado,
      vat_ms_distinto: vatMsDistinto,
      ics_requisitos_ok: icsOk,
      transporte_por: transportePor,
      importador: flujo === 'FUERA_UE' && evento === 'VENTA' ? importador : null,
      regimen_importacion: ad.regimen_importacion || null,
      cliente_nl_establecido: cli.pais_establecimiento === 'NL' || !!cli.establecimiento_permanente_nl,
      cliente_establecido_tai: cli.pais_establecimiento === 'ES',
      exp_valida: transportePor === 'VENDEDOR' || cli.pais_establecimiento !== 'ES',
      proveedor_establecido_local: evento === 'COMPRA' ? (prov.pais_establecimiento === emU || !!prov.establecido_local) : null,
      re: !!cli.recargo_equivalencia,
      ddp: tr.incoterm === 'DDP',
      consigna: !!esp.consigna,
      triangular: !!esp.triangular,
      cadena: !!esp.operacion_en_cadena,
      distancia_destino: perfil === 'NL' || !!cfg.ventas_distancia_umbral_superado,
      roi: esId.roi_alta === false ? false : (esId.roi_alta === true ? roi : null),
      oss: esId.oss_alta === true ? true : (esId.oss_alta === false ? false : null),
      diferimiento: esId.diferimiento_iva_importacion === true,
      override_iva_origen: !!ovr.forzar_iva_origen
    };

    // 8. Selección de regla (la ley) ----------------------------------------------------------
    const seleccionar = (hechos) => {
      const cumple = (cond) => Object.keys(cond).every((k) => Array.isArray(cond[k]) && cond[k].includes(hechos[k] ?? null));
      const cand = (ctx.reglas || [])
        .filter((r) => r.activo !== false && vigente(r, fecha) && cumple(r.condiciones))
        .sort((a, b) => a.prioridad - b.prioridad);
      if (!cand.length) return { error: `Ninguna regla cubre esta combinación: ${JSON.stringify(hechos)}. Añadir regla o revisar datos.` };
      const emp = cand.filter((r) => r.prioridad === cand[0].prioridad);
      if (emp.length > 1) return { error: `Reglas ambiguas con la misma prioridad: ${emp.map((r) => r.codigo).join(', ')}.` };
      return { regla: cand[0] };
    };

    // 9. Habilitación (qué identificación de TB puede ejecutarla) -------------------------------
    const idsDe = (jur) => idents.filter((i) => i.jurisdiccion === jur && i.estado !== 'BAJA')
      .sort((a, b) => (a.prioridad ?? 10) - (b.prioridad ?? 10));
    const operativa = (i) => motivosIdentificacion(i, fecha, ctx, simular).length === 0;
    const cubre = (i, code) => {
      const c = i.coberturas || [];
      return c.includes('*') || c.includes(code) || (esImportada && c.includes(code + '@IMPORT'));
    };
    const cobDesc = (code) => ((ctx.coberturas || []).find((c) => c.codigo === code) || {}).descripcion || code;

    const habilita = (res, cand, hipotetico) => {
      const ok = (i) => hipotetico ? true : operativa(i);
      let ident = cand;
      if (res.factura_con && res.factura_con !== perfil)
        ident = idsDe(res.factura_con).find((i) => ok(i)) || null;
      if (res.factura_con && !ident) return { ok: false, motivo: `Se factura con la identificación ${res.factura_con} y no hay ninguna operativa.` };
      let via = null;
      if (res.cobertura && !(ident && cubre(ident, res.cobertura))) {
        const soloImp = ident && (ident.coberturas || []).includes(res.cobertura + '@IMPORT') && !esImportada;
        const txt = ident ? `${ident.codigo} no cubre: ${cobDesc(res.cobertura)}${soloImp ? ' (solo la cubre para mercancía importada por TB)' : ''}.`
                          : `Sin identificación ${perfil} operativa para: ${cobDesc(res.cobertura)}.`;
        if (res.cobertura_bloquea !== false) return { ok: false, motivo: txt };
        via = 'SIN_IDENTIFICACION';
      }
      if (res.requiere_destino) {
        const jur = emD;
        const code = `${jur}_${res.requiere_destino}`;
        if (!JURIS.includes(jur)) return { ok: false, motivo: `La operación exige identificación de IVA de TB en ${tD.nombre}.`, destino: jur };
        if (!idsDe(jur).some((i) => ok(i) && cubre(i, code)))
          return { ok: false, motivo: `En ${tD.nombre} TB debe declarar una adquisición intracomunitaria y ninguna identificación ${jur} operativa la cubre.`, destino: jur, code };
      }
      return { ok: true, ident, via };
    };

    const viaDeduccion = (res, ident, via) => {
      if (!['COMPRA', 'IMPORTACION'].includes(evento) || ['NO_SUJETA', 'EXENTA_PLENA', 'SUSPENSION_ADUANERA', 'TIPO_CERO'].includes(res.calificacion)) return null;
      if (res.autoliquidacion) return 'Autoliquidación: devengado y deducible en la misma declaración.';
      if (perfil === 'ES') return 'IVA soportado deducible en el modelo 303.';
      if (via === 'SIN_IDENTIFICACION')
        return 'Sin identificación NL que permita deducir: el btw es coste, salvo devolución a no establecidos (modelo 360), que no procede si TB realiza entregas en NL en ese periodo (art. 3 Dir. 2008/9/CE).';
      return `Btw soportado deducible en la btw-aangifte (${ident ? ident.codigo : 'NL'}).`;
    };

    // Recorre las identificaciones operativas de la jurisdicción (y «ninguna» al final)
    const motivosHab = [];
    idsDe(perfil).forEach((i) => {
      const mi = motivosIdentificacion(i, fecha, ctx, simular);
      if (mi.length && i.estado !== 'ESCENARIO') motivosHab.push({ identificacion: i.codigo, motivo: mi.join('; ') });
    });
    const candidatos = idsDe(perfil).filter(operativa).concat([null]);
    let primera = null;
    let reserva = null;
    for (const cand of candidatos) {
      const hechos = Object.assign({}, base, { art23: cand ? !!cand.licencia_art23 : null });
      const sel = seleccionar(hechos);
      if (sel.error) { falta('matriz', sel.error); return bloqueo(faltan, avisos, h, hechos); }
      const res = sel.regla.resultado;
      if (res.revision) { falta(`regla:${sel.regla.codigo}`, res.revision); return bloqueo(faltan, avisos, h, hechos, sel.regla); }
      if (res.no_habilitada)
        return Object.assign(bloqueo([], avisos, h, hechos, sel.regla), {
          estado: 'NO_HABILITADA', mensaje: NO_HABILITADA,
          motivos_habilitacion: [{ identificacion: null, motivo: res.no_habilitada }], habilitarian: [] });
      const hb = habilita(res, cand, false);
      // Cobertura no bloqueante (compras): se prefiere una identificación que sí la cubra
      if (hb.ok && hb.via === 'SIN_IDENTIFICACION') {
        if (!reserva) reserva = { regla: sel.regla, hechos, hb };
        continue;
      }
      if (hb.ok) {
        const estado = simular && hb.ident && hb.ident.codigo === simular ? 'SIMULACION' : 'OK';
        return construir(sel.regla, hechos, hb.ident, estado, { via: viaDeduccion(res, hb.ident, hb.via), motivosHab: [], habilitarian: [] });
      }
      if (cand || !motivosHab.length) motivosHab.push({ identificacion: cand ? cand.codigo : null, motivo: hb.motivo });
      if (!primera) primera = { regla: sel.regla, hechos, hb };
    }

    if (reserva)
      return construir(reserva.regla, reserva.hechos, reserva.hb.ident, 'OK',
        { via: viaDeduccion(reserva.regla.resultado, reserva.hb.ident, reserva.hb.via), motivosHab: [], habilitarian: [] });

    // 10. No habilitada: tratamiento completo + qué identificación la permitiría ------------------
    const habilitarian = [];
    let muestra = null;
    const jurEsc = primera.hb.destino && JURIS.includes(primera.hb.destino) ? primera.hb.destino : perfil;
    idsDe(jurEsc).filter((i) => !operativa(i)).forEach((i) => {
      if (jurEsc !== perfil) {                       // falta identificación en destino (transferencias)
        if (cubre(i, primera.hb.code)) habilitarian.push(i.codigo);
        return;
      }
      const hechos = Object.assign({}, base, { art23: !!i.licencia_art23 });
      const sel = seleccionar(hechos);
      if (!sel.regla || sel.regla.resultado.revision || sel.regla.resultado.no_habilitada) return;
      if (habilita(sel.regla.resultado, i, true).ok) {
        habilitarian.push(i.codigo);
        if (!muestra) muestra = { regla: sel.regla, hechos, ident: i };
      }
    });
    const ref = muestra || { regla: primera.regla, hechos: primera.hechos, ident: null };
    return construir(ref.regla, ref.hechos, ref.ident, 'NO_HABILITADA', { motivosHab, habilitarian, via: null });

    // ---------------------------------------------------------------------------------------
    function construir(regla, hechos, ident, estado, extra) {
      const res = regla.resultado;
      const av = avisos.slice();
      const fl = [];
      const autoliq = !!res.autoliquidacion;
      const buscaTipo = (spec, categoria) => {
        const pais = spec.pais === 'DESTINO' ? emD : spec.pais;
        const c = spec.categoria.replace('MERCANCIA', categoria);
        const row = ctx.tipos.find((t) => t.pais === pais && t.categoria === c && vigente(t, fecha));
        if (!row) fl.push({ campo: 'tipo_iva', motivo: `No hay tipo de IVA vigente para ${pais} / ${c} el ${fecha}. Parametrizarlo en erp_fiscal_tipo_iva.` });
        return row ? Number(row.porcentaje) : null;
      };

      // Importes por categoría de IVA (cada línea de mercancía puede traer la suya)
      const lineas = h.lineas || [];
      if (lineas.some((l) => l.tipo === 'SERVICIO'))
        av.push('Hay líneas de servicio: la matriz solo cubre entregas de bienes; esas líneas conservan su régimen actual.');
      const grupos = {};
      lineas.filter((l) => (l.tipo || 'MERCANCIA') === 'MERCANCIA').forEach((l) => {
        const c = l.categoria_iva || m.categoria_iva;
        const b = l.base != null ? Number(l.base) : Number(l.cantidad || 0) * Number(l.precio || 0) * (1 - Number(l.descuento_pct || 0) / 100);
        grupos[c] = (grupos[c] || 0) + b;
      });
      if (!Object.keys(grupos).length) grupos[m.categoria_iva] = 0;
      const desglose = Object.keys(grupos).map((c) => {
        const base = r2(grupos[c]);
        const pct = res.tasa ? buscaTipo(res.tasa, c) : 0;
        const rp = res.recargo ? buscaTipo(res.recargo, c) : 0;
        return { categoria: c, base, pct, cuota: r2(base * (pct || 0) / 100), recargo_pct: rp, cuota_recargo: r2(base * (rp || 0) / 100) };
      });
      const baseImp = r2(desglose.reduce((s, d) => s + d.base, 0));
      const cuota = r2(desglose.reduce((s, d) => s + d.cuota, 0));
      const cuotaRe = r2(desglose.reduce((s, d) => s + d.cuota_recargo, 0));
      const pct = desglose.length === 1 ? desglose[0].pct : null;
      const rePct = desglose.length === 1 ? desglose[0].recargo_pct : null;
      if (desglose.length > 1) av.push('Varias categorías de IVA en el documento: ver desglose por categoría.');

      let calificacion = res.calificacion;
      if (calificacion === 'SUJETA' && desglose.every((d) => d.pct === 0)) {
        calificacion = 'SUJETA_TIPO_CERO';
        av.push('Tipo 0% vigente: la operación es SUJETA y no exenta.');
      }

      const rep = ident && ident.representante_codigo ? (ctx.representantes || []).find((r) => r.codigo === ident.representante_codigo) : null;
      const idioma = h.idioma || 'es';
      const subs = { rep_nombre: rep ? rep.nombre : '', rep_direccion: rep ? rep.direccion || '' : '', rep_vat: rep ? rep.vat_number || '' : '', pais_destino: tD ? tD.nombre : '',
        factura_rectificada: rect ? rect.documento || '' : '', fecha_rectificada: rect ? fechaEs(rect.fecha) : '', motivo_rect: rect ? rect.motivo || '' : '' };
      const codigos = (res.textos || []).slice();
      if (rect) codigos.unshift('TX_RECT');
      if (rep && ['VENTA', 'TRANSFERENCIA'].includes(evento) && !codigos.includes('TX_NL_REP')) codigos.push('TX_NL_REP');
      const textos = codigos.map((cod) => {
        const vs = ctx.textos.filter((t) => t.codigo === cod && vigente(t, fecha) && t.estado_validacion !== 'RETIRADO');
        const t = vs.find((x) => x.idioma === idioma) || vs.find((x) => x.idioma === 'en') || vs[0];
        if (!t) { fl.push({ campo: 'texto_legal', motivo: `Falta el texto legal ${cod}.` }); return ''; }
        if (t.estado_validacion !== 'VALIDADO') {
          if (cfg.bloquear_textos_no_validados) fl.push({ campo: 'texto_legal', motivo: `El texto ${cod} está pendiente de validación por el asesor.` });
          else av.push(`Texto legal ${cod} pendiente de validación por el asesor.`);
        }
        return t.texto.replace(/\{(\w+)\}/g, (_, k) => subs[k] ?? '');
      }).filter(Boolean);

      if (rect && estado === 'OK' && ident) {
        if (rect.identificacion_original && ident.codigo !== rect.identificacion_original)
          fl.push({ campo: 'rectificacion.identificacion', motivo: `La factura original se emitió con ${rect.identificacion_original}; la rectificativa debe emitirse con la misma identificación fiscal (hoy correspondería ${ident.codigo}).` });
        else if (!rect.identificacion_original && rect.pais_emisor_original && rect.pais_emisor_original !== ident.jurisdiccion)
          fl.push({ campo: 'rectificacion.identificacion', motivo: `La factura original se emitió con la identificación ${rect.pais_emisor_original}; la matriz asigna ${ident.jurisdiccion}. Revisar la factura original antes de rectificarla.` });
      }
      if (fl.length && estado === 'OK') return bloqueo(faltan.concat(fl), av, h, hechos, regla);
      (res.avisos || []).forEach((a) => av.push(a));
      if (regla.estado_validacion !== 'VALIDADO') av.push(`Regla ${regla.codigo} pendiente de validación por el asesor.`);
      if (extra.via && /^Sin identificación/.test(extra.via)) av.push(extra.via);
      const documentos = (res.documentos || []).slice();
      if (rect) {
        if (!documentos.includes('LIQ_VENTA')) documentos.push('LIQ_VENTA');
        av.push(`Rectificativa por diferencias de ${rect.documento || 'la factura original'}: serie específica y tipo de IVA del devengo original (${fechaEs(fecha)}; art. 90.Dos LIVA).`);
        if (perfil === 'ES' && pct > 0) av.push('La diferencia de IVA se declara en el modelo 303 del periodo de esta rectificativa (art. 89.Cinco LIVA).');
        if (perfil === 'ES' && res.flags.m349_icp) av.push('Modelo 349: consignar la diferencia en el apartado de rectificaciones, con el periodo de la operación original.');
        if (perfil === 'NL' && res.flags.m349_icp) av.push('Opgaaf ICP: la diferencia va en el apartado de correcciones, con el periodo de la entrega original.');
        if (res.tipo_operacion === 'EXPORTACION') av.push('Exportación: si cambia el valor declarado en el DUA, valorar su rectificación con el agente de aduanas.');
        if (res.tipo_operacion === 'VENTA_NO_SUJETA_LOCALIZACION') av.push('Venta antes del despacho: el cliente importador debe ajustar el valor en aduana de su importación.');
        if (cuotaRe) av.push('Cliente en recargo de equivalencia: la diferencia también lleva recargo.');
      }

      const vatTB = ident && estado !== 'NO_HABILITADA' ? ident.vat : null;
      const esVenta = ['VENTA', 'TRANSFERENCIA'].includes(evento);
      return {
        estado,
        mensaje: estado === 'NO_HABILITADA' ? NO_HABILITADA : null,
        motor_version: MOTOR_VERSION,
        matriz_version: cfg.matriz_version || null,
        regla_codigo: regla.codigo,
        regla_version: regla.version,
        evento,
        fecha_devengo: fecha,
        pais_origen_mercancia: m.pais_origen || null,
        pais_ubicacion: m.ubicacion,
        estado_aduanero: m.estado_aduanero,
        pais_destino: h.destino || null,
        perfil_vendedor: perfil,
        identificacion_codigo: estado === 'NO_HABILITADA' ? null : (ident ? ident.codigo : null),
        identificacion_modalidad: estado === 'NO_HABILITADA' ? null : (ident ? ident.modalidad : null),
        tratamiento_calculado_con: estado === 'NO_HABILITADA' && ident ? ident.codigo : null,
        cobertura_requerida: res.cobertura || null,
        habilitarian: extra.habilitarian,
        motivos_habilitacion: extra.motivosHab,
        vat_vendedor: esVenta ? vatTB : (prov.vat || null),
        vat_comprador: esVenta ? (evento === 'VENTA' ? cli.vat || null : null) : vatTB,
        proveedor_vat: prov.vat || null,
        vies_estado: viesEstado,
        vies_consulta_id: vies.consulta_id || null,
        cliente_tipo: cli.tipo || null,
        incoterm: tr.incoterm || null,
        transporte_por: transportePor,
        importador,
        exportador,
        tipo_operacion: res.tipo_operacion,
        calificacion,
        untdid_5305: res.untdid_5305,
        tipo_iva_pct: pct,
        recargo_pct: rePct,
        desglose_iva: desglose,
        base_imponible: baseImp,
        cuota_iva: autoliq ? 0 : cuota,
        cuota_recargo: cuotaRe,
        cuota_autoliquidada: autoliq ? cuota : 0,
        total: r2(baseImp + (autoliq ? 0 : cuota) + cuotaRe),
        via_deduccion: extra.via,
        textos_legales: textos.join('\n'),
        declaraciones: res.declaraciones || [],
        documentos_archivo: documentos,
        requiere_vies: !!res.flags.vies,
        requiere_349_icp: !!res.flags.m349_icp,
        requiere_aduana: !!res.flags.aduana,
        requiere_mrn_salida: !!res.flags.mrn_salida,
        interviene_rep_nl: !!rep,
        representante_codigo: rep ? rep.codigo : null,
        faltantes: fl,
        avisos: av,
        hechos: h,
        override_por: ovr.forzar_iva_origen ? ovr.usuario : null,
        override_motivo: ovr.forzar_iva_origen ? ovr.motivo : null,
        rectificacion: rect ? { documento: rect.documento || null, documento_id: rect.documento_id || null, fecha: rect.fecha || null,
          metodo: rect.metodo || 'DIFERENCIAS', motivo: rect.motivo || null } : null,
        untdid_1001: rect ? '384' : (esVenta ? '380' : null)
      };
    }
  }

  function bloqueo(faltan, avisos, h, derivado, regla) {
    return {
      estado: 'REVISION_FISCAL',
      mensaje: REVISION,
      motor_version: MOTOR_VERSION,
      regla_codigo: regla ? regla.codigo : null,
      regla_version: regla ? regla.version : null,
      faltantes: faltan,
      avisos,
      derivado: derivado || null,
      hechos: h
    };
  }

  // Qué identificación cubre cada operación: base para decidir si ampliar la licencia de Exonero
  function mapaHabilitacion(ctx, jurisdiccion) {
    const jur = jurisdiccion || 'NL';
    const ids = (ctx.identificaciones || []).filter((i) => i.jurisdiccion === jur && i.estado !== 'BAJA');
    return (ctx.coberturas || []).filter((c) => c.jurisdiccion === jur).map((c) => {
      const fila = { cobertura: c.codigo, descripcion: c.descripcion };
      ids.forEach((i) => {
        const cb = i.coberturas || [];
        fila[i.codigo] = cb.includes('*') || cb.includes(c.codigo) ? 'CUBRE'
          : cb.includes(c.codigo + '@IMPORT') ? 'SOLO_IMPORTADA' : 'NO';
      });
      return fila;
    });
  }

  // Fila para erp_fiscal_determinacion (el documento solo se numera si estado = 'OK')
  function aSnapshot(r, documentoId, usuario) {
    const cols = ['estado', 'matriz_version', 'regla_codigo', 'regla_version', 'evento', 'fecha_devengo',
      'pais_origen_mercancia', 'pais_ubicacion', 'estado_aduanero', 'pais_destino', 'perfil_vendedor',
      'identificacion_codigo', 'cobertura_requerida', 'habilitarian', 'motivos_habilitacion', 'via_deduccion',
      'vat_vendedor', 'vat_comprador', 'proveedor_vat', 'vies_estado', 'vies_consulta_id', 'cliente_tipo', 'incoterm',
      'transporte_por', 'importador', 'exportador', 'tipo_operacion', 'calificacion', 'untdid_5305', 'tipo_iva_pct',
      'recargo_pct', 'base_imponible', 'cuota_iva', 'cuota_recargo', 'cuota_autoliquidada', 'desglose_iva', 'total', 'textos_legales',
      'declaraciones', 'documentos_archivo', 'requiere_vies', 'requiere_349_icp', 'requiere_aduana', 'requiere_mrn_salida',
      'interviene_rep_nl', 'representante_codigo', 'faltantes', 'avisos', 'hechos', 'override_por', 'override_motivo'];
    const row = { documento_id: documentoId || null, creado_por: usuario || null };
    cols.forEach((c) => { if (r[c] !== undefined) row[c] = r[c]; });
    return row;
  }

  return { determinar, cargarContexto, aSnapshot, mapaHabilitacion, REVISION, NO_HABILITADA, MOTOR_VERSION };
});
