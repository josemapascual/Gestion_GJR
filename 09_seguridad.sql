-- =====================================================================
-- ERP TROPICAL BÁEZ · 09 · SEGURIDAD, USUARIOS Y ROLES
-- Base de la segregación de funciones. Ejecutar ANTES que el resto.
-- =====================================================================

create table if not exists erp_rol (
  codigo      text primary key,
  nombre      text not null,
  descripcion text
);

insert into erp_rol(codigo,nombre,descripcion) values
  ('GERENCIA',    'Gerencia',              'Dirección. Autoriza pagos y da de alta beneficiarios.'),
  ('CONTROLLER',  'Controller financiero', 'Bancos, conciliación, cartera, cierre. Aprueba pagos.'),
  ('OPERACIONES', 'Operaciones',           'Expedientes, kilos, stock, contenedores, logística.'),
  ('COMERCIAL',   'Comercial',             'Clientes, ventas, facturas de venta, liquidaciones.'),
  ('ADMIN',       'Administración',        'Documentación y archivo. Solo lectura del resto.')
on conflict (codigo) do nothing;

create table if not exists erp_usuario (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null unique,
  nombre      text not null,
  rol         text not null references erp_rol(codigo),
  activo      boolean not null default true,
  creado_en   timestamptz not null default now()
);

create index if not exists ix_erp_usuario_rol on erp_usuario(rol) where activo;

-- Funciones de apoyo para las políticas RLS -------------------------------
create or replace function erp_rol_actual() returns text
language sql stable security definer set search_path = public, auth as $$
  select u.rol from erp_usuario u where u.id = auth.uid() and u.activo
$$;

create or replace function erp_es(variadic roles text[]) returns boolean
language sql stable as $$ select erp_rol_actual() = any(roles) $$;

create or replace function erp_autenticado() returns boolean
language sql stable as $$ select erp_rol_actual() is not null $$;

comment on function erp_es is
  'erp_es(''GERENCIA'',''CONTROLLER'') -> true si el usuario actual tiene alguno de esos roles.';

-- Auditoría genérica -------------------------------------------------------
create or replace function erp_auditar() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_usuario text;
begin
  select coalesce(u.email,'sistema') into v_usuario from erp_usuario u where u.id = auth.uid();
  insert into erp_evento(tabla, registro_id, accion, usuario, detalle)
  values (tg_table_name,
          coalesce(new.id, old.id),
          tg_op,
          coalesce(v_usuario,'sistema'),
          case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end);
  return coalesce(new, old);
end $$;

comment on function erp_auditar is
  'Trigger de auditoría. Engancharlo a toda tabla con impacto económico.';
