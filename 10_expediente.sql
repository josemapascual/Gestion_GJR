-- =====================================================================
-- ERP TROPICAL BÁEZ · 10 · EXPEDIENTE — la espina dorsal del sistema
-- Un expediente = una operación completa, de la compra al resultado.
-- =====================================================================

create table if not exists erp_campana (
  id      uuid primary key default gen_random_uuid(),
  codigo  text not null unique,          -- '2027'
  inicio  date not null,
  fin     date not null,
  activa  boolean not null default true
);

create table if not exists erp_producto (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique,   -- 'PALTA-HASS'
  nombre         text not null,
  variedad       text,
  perecedero     boolean not null default true,
  vida_util_dias int,
  activo         boolean not null default true
);

insert into erp_producto(codigo,nombre,variedad) values
  ('PALTA-HASS','Palta','Hass'), ('MANGO','Mango',null),
  ('MANDARINA','Mandarina',null), ('UVA','Uva',null), ('ARANDANO','Arándano',null)
on conflict (codigo) do nothing;

create table if not exists erp_formato (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique,    -- 'CAJA-4', 'CAJA-10'
  descripcion   text not null,
  peso_neto_kg  numeric(10,3) not null check (peso_neto_kg > 0)
);

insert into erp_formato(codigo,descripcion,peso_neto_kg) values
  ('CAJA-4','Caja 4 kg',4), ('CAJA-10','Caja 10 kg',10)
on conflict (codigo) do nothing;

create table if not exists erp_calibre (
  id           uuid primary key default gen_random_uuid(),
  producto_id  uuid not null references erp_producto(id),
  codigo       text not null,            -- '12'..'32', 'SC'
  gramaje_min  int,
  gramaje_max  int,
  orden        int not null default 0,
  unique (producto_id, codigo)
);

-- ---------------------------------------------------------------------
-- EXPEDIENTE
-- ---------------------------------------------------------------------
create table if not exists erp_expediente (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null unique,     -- TB-27-0001
  canal         text not null check (canal in ('TRANSITO','ALMACEN')),
  estado        text not null default 'ABIERTO'
                check (estado in ('ABIERTO','EMBARCADO','EN_DESTINO','FACTURADO',
                                  'COBRADO','LIQUIDADO','CERRADO','ANULADO')),
  modalidad     text check (modalidad in ('PRECIO_FIJO','PMG_LIQUIDACION',
                                          'FIJO_ADELANTADO','ANTICIPO_LIQUIDACION')),
  campana_id    uuid references erp_campana(id),
  producto_id   uuid references erp_producto(id),
  fecha_apertura date not null default current_date,
  fecha_cierre   date,
  cerrado_por    uuid references erp_usuario(id),
  pais_iva       text,                    -- ES, NL...
  observaciones  text,
  creado_en      timestamptz not null default now(),
  creado_por     uuid references erp_usuario(id),
  constraint ck_exp_cierre check (
    (estado = 'CERRADO' and fecha_cierre is not null and cerrado_por is not null)
    or estado <> 'CERRADO')
);

create index if not exists ix_exp_estado  on erp_expediente(estado);
create index if not exists ix_exp_campana on erp_expediente(campana_id);

comment on table erp_expediente is
  'Unidad de análisis del negocio. Todo cuelga de aquí: compra, contenedor, venta, cobro, liquidación y resultado.';

-- Numeración automática TB-AA-NNNN ------------------------------------
create sequence if not exists sq_expediente;

create or replace function erp_expediente_codigo() returns trigger
language plpgsql as $$
begin
  if new.codigo is null then
    new.codigo := 'TB-' || to_char(current_date,'YY') || '-' ||
                  lpad(nextval('sq_expediente')::text, 4, '0');
  end if;
  return new;
end $$;

drop trigger if exists tg_expediente_codigo on erp_expediente;
create trigger tg_expediente_codigo before insert on erp_expediente
  for each row execute function erp_expediente_codigo();

drop trigger if exists tg_expediente_audit on erp_expediente;
create trigger tg_expediente_audit after insert or update or delete on erp_expediente
  for each row execute function erp_auditar();

-- ---------------------------------------------------------------------
-- Enganchar lo que ya existe al expediente (tipos detectados en runtime)
-- ---------------------------------------------------------------------
do $$
declare
  t_exp text;
  r record;
begin
  select format_type(at.atttypid, at.atttypmod) into t_exp
  from pg_attribute at
  where at.attrelid = 'public.erp_expediente'::regclass and at.attname = 'id';

  for r in
    select unnest(array['erp_contenedor','erp_documento','erp_albaran',
                        'erp_coste','erp_lote','erp_pallet']) as tabla
  loop
    if to_regclass('public.' || r.tabla) is not null then
      execute format(
        'alter table %I add column if not exists expediente_id %s references erp_expediente(id)',
        r.tabla, t_exp);
      execute format(
        'create index if not exists ix_%s_exp on %I(expediente_id)', r.tabla, r.tabla);
    end if;
  end loop;
end $$;

-- Atributos aduaneros y fiscales que faltaban en el pallet -------------
alter table erp_pallet add column if not exists estatuto_aduanero text
  check (estatuto_aduanero in ('T1','LIBRE_PRACTICA'));
alter table erp_pallet add column if not exists pais_iva text;

comment on column erp_pallet.estatuto_aduanero is
  'T1 = mercancía no despachada en depósito aduanero. Nunca se suma con LIBRE_PRACTICA en el mismo saldo.';
