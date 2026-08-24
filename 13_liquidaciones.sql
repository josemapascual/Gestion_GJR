-- =====================================================================
-- ERP TROPICAL BÁEZ · 13 · LIQUIDACIONES, CALIDAD Y RECLAMACIONES
-- Donde está el margen real. Sin esto, el resultado del contenedor es ficción.
-- =====================================================================

create table if not exists erp_liquidacion (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique,
  expediente_id  uuid not null references erp_expediente(id),
  cliente_id     uuid not null references erp_cliente(id),
  documento_id   uuid references erp_documento(id),      -- factura de venta previa
  fecha_recepcion date not null default current_date,
  referencia_cliente text,

  moneda          text not null,
  venta_bruta     numeric(14,2) not null default 0,
  deducciones     numeric(14,2) not null default 0,
  comision        numeric(14,2) not null default 0,
  reclamaciones   numeric(14,2) not null default 0,
  neto            numeric(14,2) not null default 0,
  kilos           numeric(12,3) not null default 0,
  neto_kg         numeric(12,4) generated always as
                    (case when kilos > 0 then round(neto / kilos, 4) end) stored,

  tipo_cambio     numeric(14,6) not null default 1,
  fecha_tc        date,
  fuente_tc       text,
  neto_eur        numeric(14,2),

  estado          text not null default 'RECIBIDA'
                  check (estado in ('ESPERADA','RECIBIDA','REVISADA','ACEPTADA','DISPUTADA','CERRADA')),
  revisada_por    uuid references erp_usuario(id),
  revisada_en     timestamptz,
  fichero_url     text,
  creado_en       timestamptz not null default now()
);

create index if not exists ix_liq_exp    on erp_liquidacion(expediente_id);
create index if not exists ix_liq_estado on erp_liquidacion(estado);

comment on column erp_liquidacion.neto_kg is
  'Indicador principal de decisión comercial: liquidación neta por kilo. No el precio de venta.';

create table if not exists erp_liquidacion_linea (
  id              uuid primary key default gen_random_uuid(),
  liquidacion_id  uuid not null references erp_liquidacion(id) on delete cascade,
  posicion        int not null,
  tipo            text not null check (tipo in ('VENTA','DEDUCCION','COMISION','RECLAMACION','AJUSTE')),
  concepto        text not null,
  calibre         text,
  categoria       text,
  formato         text,
  cajas           numeric(12,2),
  kilos           numeric(12,3),
  precio_unitario numeric(12,4),
  importe         numeric(14,2) not null,
  unique (liquidacion_id, posicion)
);

comment on table erp_liquidacion_linea is
  'Cada deducción del cliente, línea a línea. Es lo que permite auditarlas contra la tarifa del almacén.';

drop trigger if exists tg_liq_audit on erp_liquidacion;
create trigger tg_liq_audit after insert or update or delete on erp_liquidacion
  for each row execute function erp_auditar();

-- Recalcular totales de la liquidación desde sus líneas -----------------
create or replace function erp_liquidacion_recalcular() returns trigger
language plpgsql as $$
declare v_id uuid;
begin
  v_id := coalesce(new.liquidacion_id, old.liquidacion_id);
  update erp_liquidacion l set
    venta_bruta   = coalesce(s.venta,0),
    deducciones   = coalesce(s.deduc,0),
    comision      = coalesce(s.comis,0),
    reclamaciones = coalesce(s.reclam,0),
    kilos         = coalesce(s.kilos,0),
    neto          = coalesce(s.venta,0) - coalesce(s.deduc,0)
                    - coalesce(s.comis,0) - coalesce(s.reclam,0) + coalesce(s.ajuste,0)
  from (
    select sum(importe) filter (where tipo='VENTA')       as venta,
           sum(importe) filter (where tipo='DEDUCCION')   as deduc,
           sum(importe) filter (where tipo='COMISION')    as comis,
           sum(importe) filter (where tipo='RECLAMACION') as reclam,
           sum(importe) filter (where tipo='AJUSTE')      as ajuste,
           sum(kilos)   filter (where tipo='VENTA')       as kilos
    from erp_liquidacion_linea where liquidacion_id = v_id
  ) s
  where l.id = v_id;
  update erp_liquidacion set neto_eur = round(neto * tipo_cambio, 2) where id = v_id;
  return null;
end $$;

drop trigger if exists tg_liq_recalc on erp_liquidacion_linea;
create trigger tg_liq_recalc after insert or update or delete on erp_liquidacion_linea
  for each row execute function erp_liquidacion_recalcular();

-- ---------------------------------------------------------------------
-- CALIDAD
-- ---------------------------------------------------------------------
create table if not exists erp_inspeccion (
  id            uuid primary key default gen_random_uuid(),
  expediente_id uuid references erp_expediente(id),
  contenedor_id uuid references erp_contenedor(id),
  lote_id       uuid references erp_lote(id),
  momento       text not null check (momento in ('ORIGEN','EMBARQUE','LLEGADA','ALMACEN','CLIENTE')),
  fecha         date not null,
  inspector     text,
  materia_seca  numeric(6,2),
  temperatura   numeric(6,2),
  resultado     text check (resultado in ('CONFORME','OBSERVADO','NO_CONFORME')),
  observaciones text,
  fichero_url   text,
  creado_en     timestamptz not null default now()
);

create table if not exists erp_reclamacion (
  id              uuid primary key default gen_random_uuid(),
  codigo          text not null unique,
  expediente_id   uuid not null references erp_expediente(id),
  contenedor_id   uuid references erp_contenedor(id),
  lote_id         uuid references erp_lote(id),
  cliente_id      uuid references erp_cliente(id),
  fecha_aviso     date not null,
  fecha_limite    date,
  motivo          text not null,
  kilos_afectados numeric(12,3),
  importe_reclamado numeric(14,2),
  importe_aceptado  numeric(14,2),
  moneda          text not null default 'EUR',
  responsable     text check (responsable in ('ORIGEN','TRANSPORTE','ALMACEN','DESTINO','SIN_DETERMINAR')),
  repercutida_proveedor boolean not null default false,
  nota_credito_id uuid references erp_documento(id),
  estado          text not null default 'ABIERTA'
                  check (estado in ('ABIERTA','EN_ANALISIS','ACEPTADA','RECHAZADA','CERRADA')),
  fichero_url     text,
  creado_en       timestamptz not null default now()
);

create index if not exists ix_reclam_exp    on erp_reclamacion(expediente_id);
create index if not exists ix_reclam_abierta on erp_reclamacion(estado)
  where estado in ('ABIERTA','EN_ANALISIS');

comment on column erp_reclamacion.responsable is
  'Atribuir la responsabilidad es lo que permite repercutir a origen y medir qué proveedor cuesta dinero.';

drop trigger if exists tg_reclam_audit on erp_reclamacion;
create trigger tg_reclam_audit after insert or update or delete on erp_reclamacion
  for each row execute function erp_auditar();

-- ---------------------------------------------------------------------
-- REGLA DURA: no se cierra un expediente con cabos sueltos
-- ---------------------------------------------------------------------
create or replace function erp_cerrar_expediente(p_exp uuid)
returns jsonb language plpgsql security definer set search_path = public, auth as $$
declare v_pend int; v_liq int; v_cobro numeric; v_fact numeric;
begin
  if not erp_es('CONTROLLER') then
    raise exception 'Solo el Controller cierra expedientes';
  end if;

  select count(*) into v_pend from erp_reclamacion
   where expediente_id = p_exp and estado in ('ABIERTA','EN_ANALISIS');
  if v_pend > 0 then
    return jsonb_build_object('ok', false, 'motivo', 'Hay reclamaciones abiertas', 'n', v_pend);
  end if;

  select count(*) into v_liq from erp_liquidacion
   where expediente_id = p_exp and estado not in ('ACEPTADA','CERRADA');
  if v_liq > 0 then
    return jsonb_build_object('ok', false, 'motivo', 'Hay liquidaciones sin aceptar', 'n', v_liq);
  end if;

  select coalesce(sum(d.total),0) into v_fact from erp_documento d
   where d.expediente_id = p_exp and d.estado not in ('ANULADA','BORRADOR');
  select coalesce(sum(c.importe),0) into v_cobro from erp_cobro c
   join erp_documento d on d.id = c.documento_id where d.expediente_id = p_exp;

  if v_fact - v_cobro > 0.01 then
    return jsonb_build_object('ok', false, 'motivo', 'Quedan importes por cobrar',
                              'pendiente', round(v_fact - v_cobro, 2));
  end if;

  update erp_expediente
     set estado='CERRADO', fecha_cierre=current_date, cerrado_por=auth.uid()
   where id = p_exp;
  return jsonb_build_object('ok', true);
end $$;
