-- =====================================================================
-- ERP TROPICAL BÁEZ · 15 · POLÍTICAS RLS
-- El repositorio es público y la app se conecta desde el navegador.
-- Lo que no proteja RLS, no está protegido. Ejecutar SIEMPRE.
-- =====================================================================

do $$
declare t text;
begin
  foreach t in array array[
    'erp_usuario','erp_rol','erp_expediente','erp_campana','erp_producto','erp_calibre','erp_formato',
    'erp_proveedor','erp_proveedor_banco','erp_compra','erp_compra_linea',
    'erp_factura_compra','erp_factura_compra_linea',
    'erp_banco_extracto','erp_banco_movimiento','erp_pago','erp_conciliacion',
    'erp_fx_tipo','erp_fx_operacion',
    'erp_liquidacion','erp_liquidacion_linea','erp_inspeccion','erp_reclamacion',
    'erp_cierre','erp_cierre_partida','erp_alerta']
  loop
    if to_regclass('public.'||t) is not null then
      execute format('alter table %I enable row level security', t);
      execute format('alter table %I force row level security', t);
    end if;
  end loop;
end $$;

-- Patrón: LECTURA para todo usuario activo; ESCRITURA por rol ----------
do $$
declare t text;
begin
  foreach t in array array[
    'erp_expediente','erp_campana','erp_producto','erp_calibre','erp_formato',
    'erp_proveedor','erp_compra','erp_compra_linea','erp_factura_compra','erp_factura_compra_linea',
    'erp_banco_extracto','erp_banco_movimiento','erp_pago','erp_conciliacion',
    'erp_fx_tipo','erp_fx_operacion','erp_liquidacion','erp_liquidacion_linea',
    'erp_inspeccion','erp_reclamacion','erp_cierre','erp_cierre_partida','erp_alerta','erp_rol']
  loop
    if to_regclass('public.'||t) is not null then
      execute format('drop policy if exists p_%s_read on %I', t, t);
      execute format('create policy p_%s_read on %I for select using (erp_autenticado())', t, t);
    end if;
  end loop;
end $$;

-- Cada usuario ve su propia ficha; solo Gerencia gestiona usuarios ------
drop policy if exists p_usuario_self on erp_usuario;
create policy p_usuario_self on erp_usuario for select
  using (id = auth.uid() or erp_es('GERENCIA','CONTROLLER'));

drop policy if exists p_usuario_admin on erp_usuario;
create policy p_usuario_admin on erp_usuario for all
  using (erp_es('GERENCIA')) with check (erp_es('GERENCIA'));

-- OPERACIONES: expedientes, mercancía, costes ---------------------------
drop policy if exists p_exp_write on erp_expediente;
create policy p_exp_write on erp_expediente for all
  using (erp_es('OPERACIONES','CONTROLLER','GERENCIA'))
  with check (erp_es('OPERACIONES','CONTROLLER','GERENCIA'));

drop policy if exists p_compra_write on erp_compra;
create policy p_compra_write on erp_compra for all
  using (erp_es('OPERACIONES','CONTROLLER','GERENCIA'))
  with check (erp_es('OPERACIONES','CONTROLLER','GERENCIA'));

drop policy if exists p_compra_linea_write on erp_compra_linea;
create policy p_compra_linea_write on erp_compra_linea for all
  using (erp_es('OPERACIONES','CONTROLLER','GERENCIA'))
  with check (erp_es('OPERACIONES','CONTROLLER','GERENCIA'));

-- CONTROLLER: bancos, facturas de compra, conciliación -------------------
drop policy if exists p_fc_write on erp_factura_compra;
create policy p_fc_write on erp_factura_compra for all
  using (erp_es('CONTROLLER','GERENCIA')) with check (erp_es('CONTROLLER','GERENCIA'));

drop policy if exists p_mov_write on erp_banco_movimiento;
create policy p_mov_write on erp_banco_movimiento for all
  using (erp_es('CONTROLLER')) with check (erp_es('CONTROLLER'));

drop policy if exists p_extracto_write on erp_banco_extracto;
create policy p_extracto_write on erp_banco_extracto for all
  using (erp_es('CONTROLLER')) with check (erp_es('CONTROLLER'));

drop policy if exists p_conc_write on erp_conciliacion;
create policy p_conc_write on erp_conciliacion for all
  using (erp_es('CONTROLLER')) with check (erp_es('CONTROLLER'));

drop policy if exists p_fx_write on erp_fx_operacion;
create policy p_fx_write on erp_fx_operacion for all
  using (erp_es('CONTROLLER','GERENCIA')) with check (erp_es('CONTROLLER','GERENCIA'));

-- BENEFICIARIOS BANCARIOS: exclusivo de GERENCIA -------------------------
drop policy if exists p_prov_banco_read on erp_proveedor_banco;
create policy p_prov_banco_read on erp_proveedor_banco for select
  using (erp_es('GERENCIA','CONTROLLER'));

drop policy if exists p_prov_banco_write on erp_proveedor_banco;
create policy p_prov_banco_write on erp_proveedor_banco for all
  using (erp_es('GERENCIA')) with check (erp_es('GERENCIA'));

-- PAGOS: se crean por Controller. Los cambios de estado van por función --
drop policy if exists p_pago_write on erp_pago;
create policy p_pago_write on erp_pago for insert
  with check (erp_es('CONTROLLER') and estado = 'SOLICITADO');

drop policy if exists p_pago_update on erp_pago;
create policy p_pago_update on erp_pago for update
  using (erp_es('CONTROLLER','GERENCIA')) with check (erp_es('CONTROLLER','GERENCIA'));

-- COMERCIAL: liquidaciones y reclamaciones -------------------------------
drop policy if exists p_liq_write on erp_liquidacion;
create policy p_liq_write on erp_liquidacion for all
  using (erp_es('COMERCIAL','CONTROLLER','GERENCIA'))
  with check (erp_es('COMERCIAL','CONTROLLER','GERENCIA'));

drop policy if exists p_liq_linea_write on erp_liquidacion_linea;
create policy p_liq_linea_write on erp_liquidacion_linea for all
  using (erp_es('COMERCIAL','CONTROLLER','GERENCIA'))
  with check (erp_es('COMERCIAL','CONTROLLER','GERENCIA'));

drop policy if exists p_reclam_write on erp_reclamacion;
create policy p_reclam_write on erp_reclamacion for all
  using (erp_es('COMERCIAL','OPERACIONES','CONTROLLER','GERENCIA'))
  with check (erp_es('COMERCIAL','OPERACIONES','CONTROLLER','GERENCIA'));

-- CIERRE: solo Controller ------------------------------------------------
drop policy if exists p_cierre_write on erp_cierre;
create policy p_cierre_write on erp_cierre for all
  using (erp_es('CONTROLLER')) with check (erp_es('CONTROLLER'));

drop policy if exists p_cierre_part_write on erp_cierre_partida;
create policy p_cierre_part_write on erp_cierre_partida for all
  using (erp_es('CONTROLLER','GERENCIA')) with check (erp_es('CONTROLLER','GERENCIA'));

-- MAESTROS: Gerencia y Controller ---------------------------------------
do $$
declare t text;
begin
  foreach t in array array['erp_campana','erp_producto','erp_calibre','erp_formato','erp_proveedor'] loop
    execute format('drop policy if exists p_%s_write on %I', t, t);
    execute format('create policy p_%s_write on %I for all using (erp_es(''GERENCIA'',''CONTROLLER'')) with check (erp_es(''GERENCIA'',''CONTROLLER''))', t, t);
  end loop;
end $$;
