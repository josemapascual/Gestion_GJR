-- =====================================================================
-- ERP TROPICAL BÁEZ · 11 · PROVEEDORES Y COMPRAS
-- El lado que hoy no existe. Sin esto no hay margen ni landed cost.
-- =====================================================================

create table if not exists erp_proveedor (
  id                uuid primary key default gen_random_uuid(),
  codigo            text not null unique,
  razon_social      text not null,
  nif               text,
  pais              text not null,
  tipo              text not null default 'MERCANCIA'
                    check (tipo in ('MERCANCIA','LOGISTICA','ALMACEN','ADUANAS','SERVICIOS')),
  ambito_fiscal     text not null default 'EXTRACOMUNITARIO'
                    check (ambito_fiscal in ('NACIONAL','INTRACOMUNITARIO','EXTRACOMUNITARIO')),
  vinculado         boolean not null default false,   -- true para GJR
  moneda_habitual   text not null default 'USD',
  dias_pago         int not null default 0,
  email             text,
  activo            boolean not null default true,
  creado_en         timestamptz not null default now()
);

comment on column erp_proveedor.vinculado is
  'Parte vinculada (art. 18 LIS). Marca las operaciones sujetas a política de precios de transferencia.';

-- Beneficiarios bancarios: alta reservada a GERENCIA -------------------
create table if not exists erp_proveedor_banco (
  id            uuid primary key default gen_random_uuid(),
  proveedor_id  uuid not null references erp_proveedor(id) on delete cascade,
  titular       text not null,
  iban          text,
  cuenta        text,
  bic           text,
  banco         text,
  pais_banco    text,
  moneda        text not null,
  verificado    boolean not null default false,
  verificado_por uuid references erp_usuario(id),
  verificado_en  timestamptz,
  activo        boolean not null default true,
  creado_en     timestamptz not null default now()
);

comment on table erp_proveedor_banco is
  'Vector de fraude nº1. Alta y modificación exclusivas de GERENCIA, con verificación contra documento original.';

drop trigger if exists tg_prov_banco_audit on erp_proveedor_banco;
create trigger tg_prov_banco_audit after insert or update or delete on erp_proveedor_banco
  for each row execute function erp_auditar();

-- ---------------------------------------------------------------------
-- PEDIDO DE COMPRA
-- ---------------------------------------------------------------------
create table if not exists erp_compra (
  id             uuid primary key default gen_random_uuid(),
  codigo         text not null unique,
  expediente_id  uuid references erp_expediente(id),
  proveedor_id   uuid not null references erp_proveedor(id),
  tipo           text not null default 'INTERNACIONAL'
                 check (tipo in ('AGRICOLA','PROCESADA','INTERNACIONAL','SERVICIO')),
  incoterm       text,
  lugar_incoterm text,
  fecha          date not null default current_date,
  moneda         text not null,
  estado         text not null default 'BORRADOR'
                 check (estado in ('BORRADOR','CONFIRMADO','RECIBIDO','FACTURADO','CERRADO','ANULADO')),
  creado_por     uuid references erp_usuario(id),
  creado_en      timestamptz not null default now()
);

create table if not exists erp_compra_linea (
  id            uuid primary key default gen_random_uuid(),
  compra_id     uuid not null references erp_compra(id) on delete cascade,
  posicion      int not null,
  producto_id   uuid references erp_producto(id),
  calibre       text,
  categoria     text,
  formato       text,
  cajas         numeric(12,2),
  kilos         numeric(12,3) not null check (kilos > 0),
  precio_kg     numeric(12,4) not null check (precio_kg >= 0),
  importe       numeric(14,2) generated always as (round(kilos * precio_kg, 2)) stored,
  unique (compra_id, posicion)
);

-- ---------------------------------------------------------------------
-- FACTURA DE PROVEEDOR (cuentas a pagar)
-- ---------------------------------------------------------------------
create table if not exists erp_factura_compra (
  id               uuid primary key default gen_random_uuid(),
  proveedor_id     uuid not null references erp_proveedor(id),
  compra_id        uuid references erp_compra(id),
  expediente_id    uuid references erp_expediente(id),
  numero           text not null,               -- el del proveedor
  fecha            date not null,
  fecha_vencimiento date not null,
  concepto         text,

  -- multimoneda: nunca se pierde el original
  moneda           text not null,
  base             numeric(14,2) not null,
  iva_pct          numeric(6,3) not null default 0,
  iva_importe      numeric(14,2) not null default 0,
  total            numeric(14,2) not null,
  tipo_cambio      numeric(14,6) not null default 1,
  fecha_tc         date,
  fuente_tc        text,
  total_eur        numeric(14,2) not null,

  regimen_iva      text not null default 'IMPORTACION'
                   check (regimen_iva in ('NACIONAL','INTRACOMUNITARIO','IMPORTACION',
                                          'INVERSION_SUJETO_PASIVO','NO_SUJETA','EXENTA')),
  estado           text not null default 'REGISTRADA'
                   check (estado in ('REGISTRADA','VALIDADA','APROBADA','AUTORIZADA',
                                     'PAGADA','PAGADA_PARCIAL','ANULADA','DISPUTADA')),
  validada_por     uuid references erp_usuario(id),
  validada_en      timestamptz,
  fichero_url      text,
  creado_en        timestamptz not null default now(),

  constraint uq_fc_proveedor_numero unique (proveedor_id, numero),
  constraint ck_fc_total check (total >= 0 and total_eur >= 0)
);

create index if not exists ix_fc_venc   on erp_factura_compra(fecha_vencimiento)
  where estado not in ('PAGADA','ANULADA');
create index if not exists ix_fc_estado on erp_factura_compra(estado);
create index if not exists ix_fc_exp    on erp_factura_compra(expediente_id);

comment on constraint uq_fc_proveedor_numero on erp_factura_compra is
  'Control antifraude: impide registrar dos veces la misma factura del mismo proveedor.';

create table if not exists erp_factura_compra_linea (
  id                uuid primary key default gen_random_uuid(),
  factura_compra_id uuid not null references erp_factura_compra(id) on delete cascade,
  posicion          int not null,
  descripcion       text not null,
  producto_id       uuid references erp_producto(id),
  calibre           text,
  kilos             numeric(12,3),
  precio_kg         numeric(12,4),
  importe           numeric(14,2) not null,
  unique (factura_compra_id, posicion)
);

drop trigger if exists tg_fc_audit on erp_factura_compra;
create trigger tg_fc_audit after insert or update or delete on erp_factura_compra
  for each row execute function erp_auditar();

-- Control: la factura no se valida si los kilos no cuadran con el pedido
create or replace function erp_validar_factura_compra(p_factura uuid, p_tolerancia numeric default 0.02)
returns jsonb
language plpgsql security definer set search_path = public, auth as $$
declare
  v_compra uuid; v_kilos_fac numeric; v_kilos_ped numeric; v_desv numeric;
begin
  if not erp_es('CONTROLLER','GERENCIA') then
    raise exception 'Solo el Controller o Gerencia pueden validar facturas de compra';
  end if;

  select compra_id into v_compra from erp_factura_compra where id = p_factura;
  select coalesce(sum(kilos),0) into v_kilos_fac from erp_factura_compra_linea where factura_compra_id = p_factura;

  if v_compra is null then
    update erp_factura_compra set estado='VALIDADA', validada_por=auth.uid(), validada_en=now()
     where id = p_factura;
    return jsonb_build_object('ok', true, 'aviso', 'Factura sin pedido asociado');
  end if;

  select coalesce(sum(kilos),0) into v_kilos_ped from erp_compra_linea where compra_id = v_compra;
  v_desv := case when v_kilos_ped = 0 then 0 else abs(v_kilos_fac - v_kilos_ped) / v_kilos_ped end;

  if v_desv > p_tolerancia then
    return jsonb_build_object('ok', false, 'motivo', 'Desviación de kilos fuera de tolerancia',
                              'kilos_factura', v_kilos_fac, 'kilos_pedido', v_kilos_ped,
                              'desviacion_pct', round(v_desv*100, 2));
  end if;

  update erp_factura_compra set estado='VALIDADA', validada_por=auth.uid(), validada_en=now()
   where id = p_factura;
  return jsonb_build_object('ok', true, 'kilos_factura', v_kilos_fac, 'kilos_pedido', v_kilos_ped);
end $$;
