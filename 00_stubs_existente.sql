-- STUBS: simulan el esquema ya existente en Supabase para validar las migraciones.
-- NO se ejecuta en producción.
create extension if not exists "pgcrypto";
create schema if not exists auth;
create table auth.users(id uuid primary key default gen_random_uuid(), email text);
create or replace function auth.uid() returns uuid language sql stable as $$ select null::uuid $$;

create table erp_empresa(id uuid primary key default gen_random_uuid(), codigo text, razon_social text, regimen text, pais text);
create table erp_cliente(id uuid primary key default gen_random_uuid(), razon_social text, nif text, pais text, regimen_iva_id uuid);
create table erp_regimen_iva(id uuid primary key default gen_random_uuid(), codigo text, descripcion text);
create table erp_serie(id uuid primary key default gen_random_uuid(), codigo text, contador int);
create table erp_cuenta_bancaria(id uuid primary key default gen_random_uuid(), banco text, iban text, bic text, moneda text);
create table erp_almacen(id uuid primary key default gen_random_uuid(), codigo text, nombre text, pais text);
create table erp_transportista(id uuid primary key default gen_random_uuid(), nombre text);
create table erp_lote(id uuid primary key default gen_random_uuid(), codigo text, productor text);
create table erp_contenedor(id uuid primary key default gen_random_uuid(), codigo text, estado text, etd date, eta date);
create table erp_pallet(id uuid primary key default gen_random_uuid(), contenedor_id uuid references erp_contenedor(id), lote_id uuid references erp_lote(id), almacen_id uuid references erp_almacen(id), estado text, cajas_actual numeric, kilos_actual numeric, kilos_inicial numeric);
create table erp_pallet_linea(id uuid primary key default gen_random_uuid(), pallet_id uuid references erp_pallet(id), calibre text, categoria text, cajas numeric, kilos numeric);
create table erp_pallet_codigo(id uuid primary key default gen_random_uuid(), pallet_id uuid references erp_pallet(id), tipo text, codigo text, emisor text, creado_por text);
create table erp_documento(id uuid primary key default gen_random_uuid(), empresa_id uuid references erp_empresa(id), cliente_id uuid references erp_cliente(id), serie_id uuid references erp_serie(id), codigo text, tipo text, estado text, fecha date, moneda text, total numeric, motivo_anulacion text);
create table erp_documento_linea(id uuid primary key default gen_random_uuid(), documento_id uuid references erp_documento(id), posicion int, tipo_linea text, descripcion text, cantidad numeric, unidad text, precio_unitario numeric, descuento_pct numeric, calibre text, categoria text, lote text, variedad text, pais_origen text, cajas numeric, peso_caja_kg numeric, orden int);
create table erp_albaran(id uuid primary key default gen_random_uuid(), cliente_id uuid references erp_cliente(id), codigo text, estado text, fecha date);
create table erp_albaran_linea(id uuid primary key default gen_random_uuid(), albaran_id uuid references erp_albaran(id), pallet_id uuid references erp_pallet(id), kilos numeric, calibre text);
create table erp_cobro(id uuid primary key default gen_random_uuid(), documento_id uuid references erp_documento(id), fecha date, importe numeric, medio text, referencia text);
create table erp_coste(id uuid primary key default gen_random_uuid(), contenedor_id uuid references erp_contenedor(id), concepto text, descripcion text, fecha date, importe numeric, moneda text, tipo_cambio numeric, proveedor text, creado_por text);
create table erp_doc_checklist(id uuid primary key default gen_random_uuid(), contenedor_id uuid references erp_contenedor(id), documento text, presente boolean);
create table erp_evento(id uuid primary key default gen_random_uuid(), tabla text, registro_id uuid, accion text, usuario text, detalle jsonb, creado_en timestamptz default now());
