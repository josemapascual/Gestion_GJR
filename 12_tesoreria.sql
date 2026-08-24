-- =====================================================================
-- ERP TROPICAL BÁEZ · 12 · TESORERÍA, PAGOS Y DIVISAS
-- Nada se marca "pagado" a mano. Todo contra evidencia bancaria.
-- =====================================================================

-- ---------------------------------------------------------------------
-- CUENTAS Y EXTRACTOS
-- ---------------------------------------------------------------------
alter table erp_cuenta_bancaria add column if not exists entidad text;
alter table erp_cuenta_bancaria add column if not exists activa boolean not null default true;
alter table erp_cuenta_bancaria add column if not exists saldo_inicial numeric(14,2) not null default 0;
alter table erp_cuenta_bancaria add column if not exists fecha_saldo_inicial date;
alter table erp_cuenta_bancaria add column if not exists formato_extracto text
  default 'CSV' check (formato_extracto in ('N43','CSV','MT940','MANUAL'));

create table if not exists erp_banco_extracto (
  id            uuid primary key default gen_random_uuid(),
  cuenta_id     uuid not null references erp_cuenta_bancaria(id),
  fecha_desde   date not null,
  fecha_hasta   date not null,
  saldo_inicial numeric(14,2) not null,
  saldo_final   numeric(14,2) not null,
  fichero_url   text not null,           -- el original, íntegro, no se sustituye
  formato       text not null,
  hash_fichero  text,
  importado_por uuid references erp_usuario(id),
  importado_en  timestamptz not null default now(),
  unique (cuenta_id, fecha_desde, fecha_hasta)
);

comment on table erp_banco_extracto is
  'El extracto original es el documento oficial. El sistema interno solo analiza y concilia.';

create table if not exists erp_banco_movimiento (
  id             uuid primary key default gen_random_uuid(),
  cuenta_id      uuid not null references erp_cuenta_bancaria(id),
  extracto_id    uuid references erp_banco_extracto(id),
  fecha          date not null,
  fecha_valor    date,
  concepto       text not null,
  referencia     text,
  moneda         text not null,
  importe        numeric(14,2) not null,        -- + cobro / - pago
  saldo          numeric(14,2),
  tipo_cambio    numeric(14,6),
  fecha_tc       date,
  fuente_tc      text,
  importe_eur    numeric(14,2),
  estado         text not null default 'SIN_CONCILIAR'
                 check (estado in ('SIN_CONCILIAR','CONCILIADO','IGNORADO','EN_REVISION')),
  hash_linea     text unique,                   -- evita reimportar el mismo movimiento
  creado_en      timestamptz not null default now()
);

create index if not exists ix_mov_cuenta_fecha on erp_banco_movimiento(cuenta_id, fecha desc);
create index if not exists ix_mov_pendiente    on erp_banco_movimiento(estado, fecha)
  where estado = 'SIN_CONCILIAR';

-- ---------------------------------------------------------------------
-- CIRCUITO DE PAGO: registro -> aprobación -> autorización -> ejecución
-- ---------------------------------------------------------------------
create table if not exists erp_pago (
  id                uuid primary key default gen_random_uuid(),
  codigo            text unique,
  factura_compra_id uuid references erp_factura_compra(id),
  proveedor_id      uuid not null references erp_proveedor(id),
  beneficiario_id   uuid references erp_proveedor_banco(id),
  cuenta_id         uuid references erp_cuenta_bancaria(id),
  expediente_id     uuid references erp_expediente(id),

  moneda            text not null,
  importe           numeric(14,2) not null check (importe > 0),
  tipo_cambio       numeric(14,6),
  fecha_tc          date,
  fuente_tc         text,
  importe_eur       numeric(14,2),
  comision          numeric(14,2) not null default 0,

  fecha_prevista    date not null,
  fecha_ejecucion   date,
  movimiento_id     uuid references erp_banco_movimiento(id),

  estado            text not null default 'SOLICITADO'
                    check (estado in ('SOLICITADO','APROBADO','AUTORIZADO','EJECUTADO',
                                      'CONCILIADO','RECHAZADO','ANULADO')),
  aprobado_por      uuid references erp_usuario(id),
  aprobado_en       timestamptz,
  autorizado_por    uuid references erp_usuario(id),
  autorizado_en     timestamptz,
  ejecutado_por     uuid references erp_usuario(id),
  motivo_rechazo    text,
  creado_en         timestamptz not null default now(),

  -- La separación de funciones, escrita en la base de datos
  constraint ck_pago_segregacion check (aprobado_por is distinct from autorizado_por)
);

create index if not exists ix_pago_estado on erp_pago(estado, fecha_prevista);

comment on constraint ck_pago_segregacion on erp_pago is
  'Quien aprueba no puede autorizar. La segregación no depende del navegador.';

drop trigger if exists tg_pago_audit on erp_pago;
create trigger tg_pago_audit after insert or update or delete on erp_pago
  for each row execute function erp_auditar();

-- Aprobar (Controller) -------------------------------------------------
create or replace function erp_aprobar_pago(p_pago uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v jsonb; v_fc uuid; v_estado_fc text; v_benef uuid;
begin
  if not erp_es('CONTROLLER') then
    raise exception 'Solo el Controller aprueba pagos';
  end if;

  select factura_compra_id, beneficiario_id into v_fc, v_benef from erp_pago where id = p_pago;

  if v_fc is null then
    return jsonb_build_object('ok', false, 'motivo', 'Pago sin factura de proveedor asociada');
  end if;

  select estado into v_estado_fc from erp_factura_compra where id = v_fc;
  if v_estado_fc not in ('VALIDADA','APROBADA') then
    return jsonb_build_object('ok', false, 'motivo', 'La factura no está validada');
  end if;

  if v_benef is null or not exists (
      select 1 from erp_proveedor_banco where id = v_benef and verificado and activo) then
    return jsonb_build_object('ok', false, 'motivo', 'Beneficiario bancario no verificado');
  end if;

  if exists (select 1 from erp_pago
              where factura_compra_id = v_fc and id <> p_pago
                and estado in ('APROBADO','AUTORIZADO','EJECUTADO','CONCILIADO')) then
    return jsonb_build_object('ok', false, 'motivo', 'Ya existe otro pago vivo para esta factura');
  end if;

  update erp_pago set estado='APROBADO', aprobado_por=auth.uid(), aprobado_en=now()
   where id = p_pago;
  return jsonb_build_object('ok', true);
end $$;

-- Autorizar (Gerencia) -------------------------------------------------
create or replace function erp_autorizar_pago(p_pago uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_estado text; v_aprob uuid;
begin
  if not erp_es('GERENCIA') then
    raise exception 'Solo Gerencia autoriza pagos';
  end if;

  select estado, aprobado_por into v_estado, v_aprob from erp_pago where id = p_pago;

  if v_estado <> 'APROBADO' then
    return jsonb_build_object('ok', false, 'motivo', 'El pago no está aprobado por el Controller');
  end if;
  if v_aprob = auth.uid() then
    return jsonb_build_object('ok', false, 'motivo', 'Quien aprueba no puede autorizar');
  end if;

  update erp_pago set estado='AUTORIZADO', autorizado_por=auth.uid(), autorizado_en=now()
   where id = p_pago;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- CONCILIACIÓN
-- ---------------------------------------------------------------------
create table if not exists erp_conciliacion (
  id             uuid primary key default gen_random_uuid(),
  movimiento_id  uuid not null references erp_banco_movimiento(id),
  tipo           text not null check (tipo in ('COBRO','PAGO','TRASPASO','FX','COMISION','OTRO')),
  cobro_id       uuid references erp_cobro(id),
  pago_id        uuid references erp_pago(id),
  importe        numeric(14,2) not null,
  diferencia     numeric(14,2) not null default 0,
  motivo_diferencia text,
  conciliado_por uuid references erp_usuario(id),
  conciliado_en  timestamptz not null default now(),
  constraint ck_conc_diferencia check (diferencia = 0 or motivo_diferencia is not null)
);

comment on constraint ck_conc_diferencia on erp_conciliacion is
  'Una diferencia sin motivo no se guarda. Es lo que evita que los descuadres se entierren.';

-- ---------------------------------------------------------------------
-- DIVISAS
-- ---------------------------------------------------------------------
create table if not exists erp_fx_tipo (
  id        uuid primary key default gen_random_uuid(),
  fecha     date not null,
  par       text not null,                -- 'EURUSD'
  tipo      numeric(14,6) not null,
  fuente    text not null default 'BCE',
  es_gestion boolean not null default false,
  periodo   text,                          -- '2027-02' cuando es_gestion
  unique (fecha, par, fuente, es_gestion)
);

comment on column erp_fx_tipo.es_gestion is
  'Tipo de gestión fijo del mes. La diferencia contra el tipo real es resultado de tesorería, nunca margen comercial.';

create table if not exists erp_fx_operacion (
  id              uuid primary key default gen_random_uuid(),
  fecha           date not null,
  cuenta_origen   uuid references erp_cuenta_bancaria(id),
  cuenta_destino  uuid references erp_cuenta_bancaria(id),
  moneda_origen   text not null,
  importe_origen  numeric(14,2) not null check (importe_origen > 0),
  moneda_destino  text not null,
  importe_destino numeric(14,2) not null check (importe_destino > 0),
  tipo_aplicado   numeric(14,6) generated always as
                    (round(importe_destino / nullif(importe_origen,0), 6)) stored,
  tipo_mercado    numeric(14,6),
  comision        numeric(14,2) not null default 0,
  mov_origen_id   uuid references erp_banco_movimiento(id),
  mov_destino_id  uuid references erp_banco_movimiento(id),
  creado_en       timestamptz not null default now()
);

-- Coste real de cambiar divisa en cada banco: spread + comisión
create or replace view erp_v_fx_coste as
select f.id, f.fecha,
       co.banco  as banco_origen,
       f.moneda_origen, f.importe_origen, f.moneda_destino, f.importe_destino,
       f.tipo_aplicado, f.tipo_mercado,
       round((f.tipo_mercado - f.tipo_aplicado) / nullif(f.tipo_mercado,0) * 100, 4) as spread_pct,
       round(f.importe_origen * (f.tipo_mercado - f.tipo_aplicado), 2)               as coste_spread,
       f.comision,
       round(f.importe_origen * (f.tipo_mercado - f.tipo_aplicado), 2) + f.comision  as coste_total,
       round((round(f.importe_origen * (f.tipo_mercado - f.tipo_aplicado), 2) + f.comision)
             / nullif(f.importe_origen,0) * 100, 4)                                  as coste_total_pct
from erp_fx_operacion f
left join erp_cuenta_bancaria co on co.id = f.cuenta_origen;

comment on view erp_v_fx_coste is
  'Compara Cajamar, iBanFirst y Revolut. Separa spread de comisión, que es lo que los bancos mezclan.';
