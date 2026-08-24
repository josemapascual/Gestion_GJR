-- =====================================================================
-- ERP TROPICAL BÁEZ · 14 · LANDED COST, RENTABILIDAD, CIERRE Y ALERTAS
-- =====================================================================

alter table erp_coste add column if not exists proveedor_id uuid references erp_proveedor(id);
alter table erp_coste add column if not exists factura_compra_id uuid references erp_factura_compra(id);
alter table erp_coste add column if not exists categoria text
  check (categoria in ('MERCANCIA','FLETE','SEGURO','ADUANA','PORTUARIO',
                       'TRANSPORTE_INTERNO','ALMACEN','FINANCIERO','BANCARIO','OTRO'));
alter table erp_coste add column if not exists importe_eur numeric(14,2);
alter table erp_coste add column if not exists fecha_tc date;
alter table erp_coste add column if not exists fuente_tc text;

-- LANDED COST por expediente y por kilo --------------------------------
create or replace view erp_v_landed_cost as
with kilos as (
  -- Canal ALMACEN: kilos reales de pallet. Canal TRANSITO: kilos del pedido de compra.
  select e.id as expediente_id,
         coalesce(
           nullif((select sum(p.kilos_inicial) from erp_pallet p where p.expediente_id = e.id), 0),
           nullif((select sum(cl.kilos) from erp_compra_linea cl
                    join erp_compra c on c.id = cl.compra_id where c.expediente_id = e.id), 0),
           nullif((select sum(ll.kilos) from erp_liquidacion_linea ll
                    join erp_liquidacion l on l.id = ll.liquidacion_id
                   where l.expediente_id = e.id and ll.tipo = 'VENTA'), 0),
           0) as kilos
  from erp_expediente e
),
mercancia as (
  select fc.expediente_id, sum(fc.total_eur) as coste_mercancia
  from erp_factura_compra fc
  where fc.estado <> 'ANULADA'
  group by fc.expediente_id
),
costes as (
  select c.expediente_id,
         sum(coalesce(c.importe_eur, c.importe * coalesce(c.tipo_cambio,1)))                                   as costes_total,
         sum(coalesce(c.importe_eur, c.importe * coalesce(c.tipo_cambio,1)))
           filter (where c.categoria in ('FLETE','SEGURO','PORTUARIO','TRANSPORTE_INTERNO'))                   as costes_logisticos,
         sum(coalesce(c.importe_eur, c.importe * coalesce(c.tipo_cambio,1)))
           filter (where c.categoria = 'ADUANA')                                                               as costes_aduana,
         sum(coalesce(c.importe_eur, c.importe * coalesce(c.tipo_cambio,1)))
           filter (where c.categoria = 'ALMACEN')                                                              as costes_almacen,
         sum(coalesce(c.importe_eur, c.importe * coalesce(c.tipo_cambio,1)))
           filter (where c.categoria in ('BANCARIO','FINANCIERO'))                                             as costes_bancarios
  from erp_coste c
  group by c.expediente_id
)
select e.id as expediente_id, e.codigo, e.canal, e.estado,
       k.kilos,
       coalesce(m.coste_mercancia,0)                                as coste_mercancia,
       coalesce(c.costes_logisticos,0)                              as costes_logisticos,
       coalesce(c.costes_aduana,0)                                  as costes_aduana,
       coalesce(c.costes_almacen,0)                                 as costes_almacen,
       coalesce(c.costes_bancarios,0)                               as costes_bancarios,
       coalesce(m.coste_mercancia,0) + coalesce(c.costes_total,0)   as landed_cost,
       case when k.kilos > 0
            then round((coalesce(m.coste_mercancia,0) + coalesce(c.costes_total,0)) / k.kilos, 4)
       end                                                          as landed_cost_kg
from erp_expediente e
left join kilos     k on k.expediente_id = e.id
left join mercancia m on m.expediente_id = e.id
left join costes    c on c.expediente_id = e.id;

-- RESULTADO POR EXPEDIENTE ---------------------------------------------
create or replace view erp_v_resultado_expediente as
with venta as (
  select d.expediente_id,
         sum(d.total) as venta,
         count(*)     as n_facturas
  from erp_documento d
  where d.estado not in ('ANULADA','BORRADOR')
  group by d.expediente_id
),
liq as (
  select l.expediente_id,
         sum(l.neto_eur)      as liquidado_neto,
         sum(l.deducciones)   as deducciones,
         sum(l.comision)      as comisiones
  from erp_liquidacion l
  where l.estado in ('ACEPTADA','CERRADA')
  group by l.expediente_id
),
rec as (
  select r.expediente_id, sum(coalesce(r.importe_aceptado, r.importe_reclamado)) as reclamaciones
  from erp_reclamacion r where r.estado = 'ACEPTADA'
  group by r.expediente_id
)
select lc.expediente_id, lc.codigo, lc.canal, lc.estado, lc.kilos,
       coalesce(l.liquidado_neto, v.venta, 0)                       as ingreso,
       lc.coste_mercancia,
       lc.costes_logisticos, lc.costes_aduana, lc.costes_almacen, lc.costes_bancarios,
       coalesce(r.reclamaciones, 0)                                 as reclamaciones,
       lc.landed_cost, lc.landed_cost_kg,
       coalesce(l.liquidado_neto, v.venta, 0) - lc.coste_mercancia  as margen_comercial,
       coalesce(l.liquidado_neto, v.venta, 0) - lc.landed_cost
         - coalesce(r.reclamaciones, 0)                             as resultado,
       case when lc.kilos > 0 then
         round((coalesce(l.liquidado_neto, v.venta, 0) - lc.landed_cost
                - coalesce(r.reclamaciones,0)) / lc.kilos, 4) end   as resultado_kg,
       (l.liquidado_neto is not null)                               as definitivo
from erp_v_landed_cost lc
left join venta v on v.expediente_id = lc.expediente_id
left join liq   l on l.expediente_id = lc.expediente_id
left join rec   r on r.expediente_id = lc.expediente_id;

comment on view erp_v_resultado_expediente is
  'definitivo = false significa que el resultado es provisional porque falta la liquidación del cliente.';

-- TESORERÍA ------------------------------------------------------------
create or replace view erp_v_tesoreria as
select cb.id as cuenta_id, cb.banco, cb.entidad, cb.moneda,
       cb.saldo_inicial + coalesce(sum(m.importe), 0) as saldo,
       max(m.fecha)                                   as ultimo_movimiento,
       count(*) filter (where m.estado = 'SIN_CONCILIAR') as sin_conciliar
from erp_cuenta_bancaria cb
left join erp_banco_movimiento m on m.cuenta_id = cb.id
where coalesce(cb.activa, true)
group by cb.id, cb.banco, cb.entidad, cb.moneda, cb.saldo_inicial;

-- CARTERA --------------------------------------------------------------
create or replace view erp_v_cartera_cobro as
select d.id as documento_id, d.codigo, d.fecha, c.razon_social as cliente,
       d.moneda, d.total,
       d.total - coalesce((select sum(x.importe) from erp_cobro x where x.documento_id = d.id), 0) as pendiente,
       d.expediente_id
from erp_documento d
join erp_cliente c on c.id = d.cliente_id
where d.estado not in ('ANULADA','BORRADOR')
  and d.total - coalesce((select sum(x.importe) from erp_cobro x where x.documento_id = d.id), 0) > 0.01;

create or replace view erp_v_cartera_pago as
select fc.id as factura_id, fc.numero, fc.fecha, fc.fecha_vencimiento,
       p.razon_social as proveedor, fc.moneda, fc.total, fc.total_eur, fc.estado,
       current_date - fc.fecha_vencimiento as dias_vencido, fc.expediente_id
from erp_factura_compra fc
join erp_proveedor p on p.id = fc.proveedor_id
where fc.estado not in ('PAGADA','ANULADA');

-- CIERRE MENSUAL -------------------------------------------------------
create table if not exists erp_cierre (
  id        uuid primary key default gen_random_uuid(),
  periodo   text not null unique,          -- '2027-02'
  estado    text not null default 'ABIERTO'
            check (estado in ('ABIERTO','EN_REVISION','CERRADO')),
  cerrado_por uuid references erp_usuario(id),
  cerrado_en  timestamptz
);

create table if not exists erp_cierre_partida (
  id          uuid primary key default gen_random_uuid(),
  cierre_id   uuid not null references erp_cierre(id) on delete cascade,
  bloque      text not null check (bloque in ('BANCOS','FACTURAS','COBROS','PAGOS',
                                              'KILOS','STOCK','FX','CONTABILIDAD','ROSENDO')),
  concepto    text not null,
  saldo_erp   numeric(14,2),
  saldo_externo numeric(14,2),
  diferencia  numeric(14,2) generated always as (coalesce(saldo_erp,0) - coalesce(saldo_externo,0)) stored,
  estado      text not null default 'PENDIENTE'
              check (estado in ('PENDIENTE','REVISADO','CONCILIADO','CERRADO')),
  responsable uuid references erp_usuario(id),
  nota        text
);

-- ALERTAS --------------------------------------------------------------
create table if not exists erp_alerta (
  id            uuid primary key default gen_random_uuid(),
  codigo        text not null,
  severidad     text not null default 'MEDIA' check (severidad in ('BAJA','MEDIA','ALTA','CRITICA')),
  titulo        text not null,
  detalle       jsonb,
  expediente_id uuid references erp_expediente(id),
  destinatario  text references erp_rol(codigo),
  estado        text not null default 'ABIERTA' check (estado in ('ABIERTA','VISTA','RESUELTA','IGNORADA')),
  creado_en     timestamptz not null default now(),
  resuelto_en   timestamptz
);

create index if not exists ix_alerta_abierta on erp_alerta(destinatario, severidad)
  where estado = 'ABIERTA';

-- Generador de alertas: se llama desde un cron de Supabase --------------
create or replace function erp_generar_alertas() returns int
language plpgsql security definer set search_path = public, auth as $$
declare n int := 0;
begin
  -- movimiento bancario sin identificar más de 7 días
  insert into erp_alerta(codigo, severidad, titulo, detalle, destinatario)
  select 'MOV_SIN_IDENTIFICAR', 'ALTA',
         'Movimiento bancario sin conciliar hace más de 7 días',
         jsonb_build_object('movimiento_id', m.id, 'importe', m.importe, 'fecha', m.fecha),
         'CONTROLLER'
  from erp_banco_movimiento m
  where m.estado = 'SIN_CONCILIAR' and m.fecha < current_date - 7
    and not exists (select 1 from erp_alerta a
                     where a.codigo='MOV_SIN_IDENTIFICAR' and a.estado='ABIERTA'
                       and (a.detalle->>'movimiento_id')::uuid = m.id);
  get diagnostics n = row_count;

  -- factura de cliente vencida
  insert into erp_alerta(codigo, severidad, titulo, detalle, destinatario, expediente_id)
  select 'COBRO_VENCIDO', 'ALTA', 'Factura de cliente vencida',
         jsonb_build_object('documento', c.codigo, 'pendiente', c.pendiente, 'cliente', c.cliente),
         'GERENCIA', c.expediente_id
  from erp_v_cartera_cobro c
  where c.fecha < current_date - 45
    and not exists (select 1 from erp_alerta a
                     where a.codigo='COBRO_VENCIDO' and a.estado='ABIERTA'
                       and a.detalle->>'documento' = c.codigo);

  -- margen negativo
  insert into erp_alerta(codigo, severidad, titulo, detalle, destinatario, expediente_id)
  select 'MARGEN_NEGATIVO', 'CRITICA', 'Expediente con resultado negativo',
         jsonb_build_object('expediente', r.codigo, 'resultado', round(r.resultado,2)),
         'GERENCIA', r.expediente_id
  from erp_v_resultado_expediente r
  where r.resultado < 0 and r.estado <> 'ANULADO'
    and not exists (select 1 from erp_alerta a
                     where a.codigo='MARGEN_NEGATIVO' and a.estado='ABIERTA'
                       and a.detalle->>'expediente' = r.codigo);

  -- pago sin factura
  insert into erp_alerta(codigo, severidad, titulo, detalle, destinatario)
  select 'PAGO_SIN_FACTURA', 'CRITICA', 'Pago solicitado sin factura de proveedor',
         jsonb_build_object('pago_id', p.id, 'importe', p.importe), 'CONTROLLER'
  from erp_pago p
  where p.factura_compra_id is null and p.estado not in ('ANULADO','RECHAZADO')
    and not exists (select 1 from erp_alerta a
                     where a.codigo='PAGO_SIN_FACTURA' and a.estado='ABIERTA'
                       and (a.detalle->>'pago_id')::uuid = p.id);

  return n;
end $$;
