-- =====================================================================
-- 09_matriz_fiscal_tb.sql  ·  Matriz fiscal de IVA de Tropical Báez
-- Añade el motor de determinación fiscal a la facturación (erp_*).
-- No modifica tablas existentes salvo añadir una columna opcional en
-- erp_documento (bloque 9). Idempotente: se puede ejecutar dos veces.
-- =====================================================================

-- ============ 1. TERRITORIOS ============
create table if not exists erp_fiscal_territorio (
  codigo          text primary key,                 -- ISO 3166 o subterritorio (ES-CN, XI, FR-GP…)
  nombre          text not null,
  estado_miembro  text,                             -- EM a efectos de IVA (ES, NL, EL, XI…); null = fuera del IVA UE
  zona            text not null check (zona in ('ES_TAI','ES_CN','ES_CEML','NL','UE','XI','UE_EXCLUIDO','TERCERO')),
  union_aduanera  boolean not null,
  prefijo_vat     text,
  nota            text
);

-- ============ 2. TIPOS DE IVA CON VIGENCIA ============
create table if not exists erp_fiscal_tipo_iva (
  id             bigint generated always as identity primary key,
  pais           text not null,                     -- ES, NL (añadir otros EM solo si se venden B2C a distancia)
  categoria      text not null,                     -- ALIM_NATURAL, RE_ALIM_NATURAL, GENERAL…
  porcentaje     numeric(5,2) not null check (porcentaje >= 0),
  clase          text not null check (clase in ('GENERAL','REDUCIDO','SUPERREDUCIDO','CERO','RECARGO')),
  vigente_desde  date not null,
  vigente_hasta  date,
  base_legal     text not null,
  unique (pais, categoria, vigente_desde),
  check (vigente_hasta is null or vigente_hasta >= vigente_desde)
);

-- ============ 3. TEXTOS LEGALES, DOCUMENTOS, DECLARACIONES, INCOTERMS ============
create table if not exists erp_fiscal_texto_legal (
  id                 bigint generated always as identity primary key,
  codigo             text not null,
  idioma             text not null check (idioma in ('es','en','nl')),
  texto              text not null,                 -- admite {rep_nombre} {rep_direccion} {rep_vat} {pais_destino}
  base_legal         text not null,
  estado_validacion  text not null default 'PROPUESTO' check (estado_validacion in ('PROPUESTO','VALIDADO','RETIRADO')),
  validado_por       text,
  validado_en        date,
  vigente_desde      date not null,
  vigente_hasta      date,
  unique (codigo, idioma, vigente_desde)
);

create table if not exists erp_fiscal_documento_req (
  codigo      text primary key,
  nombre      text not null,
  base_legal  text,
  momento     text not null check (momento in ('ANTES_EMITIR','AL_EMITIR','POSTERIOR')),
  plazo_dias  int
);

create table if not exists erp_fiscal_declaracion (
  codigo    text primary key,
  pais      text not null,
  nombre    text not null,
  presenta  text,
  nota      text
);

create table if not exists erp_fiscal_incoterm (
  codigo                text primary key,
  transporte_principal  text not null check (transporte_principal in ('VENDEDOR','COMPRADOR')),
  despacho_exportacion  text not null check (despacho_exportacion in ('VENDEDOR','COMPRADOR')),
  despacho_importacion  text not null check (despacho_importacion in ('VENDEDOR','COMPRADOR')),
  nota                  text
);

create table if not exists erp_fiscal_cobertura (
  codigo        text primary key,
  jurisdiccion  text not null check (jurisdiccion in ('ES','NL')),
  descripcion   text not null
);

create table if not exists erp_fiscal_config (
  clave        text primary key,
  valor        jsonb not null,
  descripcion  text
);

-- ============ 4. MÓDULO «FISCAL REPRESENTATIVE NL» (datos del representante) ============
create table if not exists erp_fiscal_representante (
  codigo                    text primary key,
  nombre                    text not null,
  direccion                 text,
  pais                      text not null default 'NL',
  vat_number                text,                   -- NIF-IVA propio del representante (art. 226.15 Directiva)
  tipo_representacion       text not null check (tipo_representacion in ('LIMITADA','GENERAL')),
  declaraciones             text[] not null default '{}',   -- códigos de erp_fiscal_declaracion que presenta
  documentacion_requerida   text[] not null default '{}',   -- códigos de erp_fiscal_documento_req que exige
  garantia_requerida        boolean not null default false,
  garantia_tipo             text,                   -- aval bancario, depósito…
  garantia_importe          numeric(14,2),
  garantia_entidad          text,
  garantia_vencimiento      date,
  vigente_desde             date,
  vigente_hasta             date,
  contacto                  text,
  activo                    boolean not null default true,
  notas                     text,
  actualizado_en            timestamptz not null default now()
);

-- ============ 5. IDENTIFICACIONES FISCALES DE TB (con qué número factura y qué cubre) ============
-- La capa fiscal decide el tratamiento; esta tabla decide si TB puede ejecutarlo hoy.
-- Varias identificaciones por jurisdicción: la ACTIVA de menor prioridad que cubra la operación factura.
-- ESCENARIO = identificación hipotética (ampliar licencia, NIF NL propio) para simular y comparar.
create table if not exists erp_fiscal_identificacion (
  codigo                        text primary key,
  jurisdiccion                  text not null check (jurisdiccion in ('ES','NL')),
  modalidad                     text not null check (modalidad in ('PROPIA','REP_LIMITADA','REP_GENERAL','DIRECTA')),
  estado                        text not null check (estado in ('ACTIVA','EN_TRAMITE','ESCENARIO','BAJA')),
  prioridad                     int not null default 10,
  empresa                       text not null,
  nif                           text,
  vat                           text,               -- NIF-IVA que figura en la factura (LFV: el btw-id asignado al representante)
  numero_representacion         text,               -- LFV: subnúmero de omzetbelasting con el que opera TB
  representante_codigo          text references erp_fiscal_representante(codigo),
  coberturas                    text[] not null default '{}',   -- códigos de erp_fiscal_cobertura; '*' = todo; sufijo @IMPORT = solo mercancía importada por TB
  licencia_art23                boolean not null default false, -- verlegging del IVA a la importación en NL
  licencia_art23_ref            text,
  roi_alta                      boolean,            -- ES: Registro de Operadores Intracomunitarios
  roi_desde                     date,
  sii                           boolean,
  oss_alta                      boolean,            -- ES: ventanilla única (régimen de la Unión)
  redeme                        boolean,
  diferimiento_iva_importacion  boolean,
  vigente_desde                 date,
  vigente_hasta                 date,
  notas                         text,
  actualizado_en                timestamptz not null default now(),
  check (modalidad not in ('REP_LIMITADA','REP_GENERAL') or representante_codigo is not null)
);

-- Vista del módulo «Fiscal Representative NL»: representante + licencia con la que opera TB
create or replace view erp_fiscal_rep_nl_v with (security_invoker = true) as
select r.codigo as representante, r.nombre, r.direccion, r.vat_number as vat_representante,
       i.codigo as identificacion, i.modalidad, i.estado, i.vat as vat_factura, i.numero_representacion as subnumero,
       r.tipo_representacion, i.coberturas as operaciones_cubiertas, i.licencia_art23, i.licencia_art23_ref,
       r.declaraciones, r.documentacion_requerida, r.garantia_requerida, r.garantia_tipo, r.garantia_importe,
       r.garantia_entidad, r.garantia_vencimiento, coalesce(i.vigente_desde, r.vigente_desde) as vigente_desde,
       coalesce(i.vigente_hasta, r.vigente_hasta) as vigente_hasta, r.contacto, r.notas
from erp_fiscal_identificacion i
join erp_fiscal_representante r on r.codigo = i.representante_codigo;

-- Mapa de habilitación: qué identificación cubre cada operación (para decidir si ampliar la licencia)
create or replace view erp_fiscal_mapa_habilitacion with (security_invoker = true) as
select c.codigo as cobertura, c.descripcion, i.codigo as identificacion, i.modalidad, i.estado,
       case when '*' = any(i.coberturas) or c.codigo = any(i.coberturas) then 'CUBRE'
            when (c.codigo || '@IMPORT') = any(i.coberturas) then 'SOLO_MERCANCIA_IMPORTADA_POR_TB'
            else 'NO_CUBRE' end as situacion
from erp_fiscal_cobertura c
join erp_fiscal_identificacion i on i.jurisdiccion = c.jurisdiccion and i.estado <> 'BAJA';

-- ============ 6. REGLAS (LA MATRIZ) ============
create table if not exists erp_fiscal_regla (
  id                 bigint generated always as identity primary key,
  codigo             text not null,
  version            int not null default 1,
  prioridad          int not null,                  -- menor = se evalúa antes; <100 = bloqueos
  descripcion        text not null,
  condiciones        jsonb not null,                -- {hecho: [valores admitidos]} — todas deben cumplirse
  resultado          jsonb not null,                -- tratamiento o {"revision": "motivo"}
  base_legal         text not null,
  estado_validacion  text not null default 'PROPUESTO' check (estado_validacion in ('PROPUESTO','VALIDADO','RETIRADO')),
  vigente_desde      date not null,
  vigente_hasta      date,
  activo             boolean not null default true,
  creado_en          timestamptz not null default now(),
  unique (codigo, version)
);
create index if not exists erp_fiscal_regla_prio on erp_fiscal_regla (prioridad) where activo;

-- ============ 7. DETERMINACIÓN POR DOCUMENTO (INMUTABLE) ============
create table if not exists erp_fiscal_determinacion (
  id                      bigint generated always as identity primary key,
  creado_en               timestamptz not null default now(),
  creado_por              text,
  estado                  text not null check (estado in ('OK','REVISION_FISCAL','NO_HABILITADA','SIMULACION')),
                                                    -- solo OK numera; NO_HABILITADA = tratamiento claro pero TB no tiene hoy la identificación que lo permite
  matriz_version          text,
  regla_codigo            text,
  regla_version           int,
  evento                  text,
  fecha_devengo           date,
  pais_origen_mercancia   text,
  pais_ubicacion          text,
  estado_aduanero         text,
  pais_destino            text,
  perfil_vendedor         text,                     -- jurisdicción ES / NL
  identificacion_codigo   text,                     -- identificación con la que se factura
  cobertura_requerida     text,
  habilitarian            text[],                   -- identificaciones que permitirían la operación si no está habilitada
  motivos_habilitacion    jsonb,
  via_deduccion           text,                     -- compras: cómo se recupera el IVA soportado
  vat_vendedor            text,
  vat_comprador           text,
  vies_estado             text,
  vies_consulta_id        text,
  cliente_tipo            text,
  proveedor_vat           text,
  incoterm                text,
  transporte_por          text,
  importador              text,
  exportador              text,
  tipo_operacion          text,
  calificacion            text,
  untdid_5305             text,
  tipo_iva_pct            numeric(5,2),
  recargo_pct             numeric(5,2),
  base_imponible          numeric(14,2),
  cuota_iva               numeric(14,2),
  cuota_recargo           numeric(14,2),
  cuota_autoliquidada     numeric(14,2),            -- ISP, adquisición, importación verlegd/diferida: no se suma al total
  total                   numeric(14,2),
  textos_legales          text,
  declaraciones           text[],
  documentos_archivo      text[],
  requiere_vies           boolean,
  requiere_349_icp        boolean,
  requiere_aduana         boolean,
  requiere_mrn_salida     boolean,
  interviene_rep_nl       boolean,
  representante_codigo    text,
  faltantes               jsonb,                    -- lista de datos que faltan (REVISIÓN FISCAL NECESARIA)
  avisos                  jsonb,
  hechos                  jsonb not null,           -- entrada completa del motor
  override_por            text,
  override_motivo         text
);

create table if not exists erp_fiscal_vies_consulta (
  id                  bigint generated always as identity primary key,
  consultado_en       timestamptz not null default now(),
  pais                text not null,
  numero              text not null,
  valido              boolean not null,
  nombre              text,
  direccion           text,
  request_identifier  text,                         -- nº de consulta VIES: prueba ante Hacienda / Belastingdienst
  respuesta           jsonb
);
create index if not exists erp_fiscal_vies_idx on erp_fiscal_vies_consulta (pais, numero, consultado_en desc);

-- Una versión de regla ya usada en una factura no se edita: se crea una versión nueva.
create or replace function erp_fiscal_regla_protege() returns trigger language plpgsql as $$
begin
  if (new.condiciones is distinct from old.condiciones or new.resultado is distinct from old.resultado
      or new.prioridad is distinct from old.prioridad or new.vigente_desde is distinct from old.vigente_desde)
     and exists (select 1 from erp_fiscal_determinacion d
                 where d.regla_codigo = old.codigo and d.regla_version = old.version) then
    raise exception 'La regla % v% ya se ha usado en documentos: cree la versión % y cierre esta con vigente_hasta.',
      old.codigo, old.version, old.version + 1;
  end if;
  return new;
end $$;
drop trigger if exists erp_fiscal_regla_protege on erp_fiscal_regla;
create trigger erp_fiscal_regla_protege before update on erp_fiscal_regla
  for each row execute function erp_fiscal_regla_protege();

-- La determinación es un registro de auditoría: no se modifica ni se borra.
create or replace function erp_fiscal_det_inmutable() returns trigger language plpgsql as $$
begin
  raise exception 'erp_fiscal_determinacion es inmutable: registre una nueva determinación.';
end $$;
drop trigger if exists erp_fiscal_det_inmutable on erp_fiscal_determinacion;
create trigger erp_fiscal_det_inmutable before update or delete on erp_fiscal_determinacion
  for each row execute function erp_fiscal_det_inmutable();
-- ============ 8. DATOS SEMILLA (generados desde la fuente única de la matriz) ============
insert into erp_fiscal_territorio (codigo,nombre,estado_miembro,zona,union_aduanera,prefijo_vat,nota) values
('ES','España (Península y Baleares)','ES','ES_TAI',true,'ES',null),
('ES-CN','Canarias',null,'ES_CN',true,null,'Territorio tercero a efectos de IVA (art. 3 LIVA). IGIC en destino.'),
('ES-CE','Ceuta',null,'ES_CEML',false,null,'Fuera de la unión aduanera y del IVA. IPSI en destino.'),
('ES-ML','Melilla',null,'ES_CEML',false,null,'Fuera de la unión aduanera y del IVA. IPSI en destino.'),
('NL','Países Bajos','NL','NL',true,'NL',null),
('GR','Grecia','EL','UE',true,'EL','Prefijo IVA EL.'),
('MC','Mónaco','FR','UE',true,'FR','Tratado como Francia a efectos de IVA.'),
('XI','Irlanda del Norte (mercancías)','XI','XI',true,'XI','Reglas UE de mercancías (Marco de Windsor). NIF-IVA con prefijo XI.'),
('GB','Reino Unido (Gran Bretaña)',null,'TERCERO',false,null,'País tercero desde 2021.'),
('IM','Isla de Man',null,'TERCERO',false,null,'Sigue al Reino Unido.'),
('FI-AX','Åland',null,'UE_EXCLUIDO',true,null,'Excluido del IVA UE; dentro de la unión aduanera.'),
('FR-GP','Guadalupe',null,'UE_EXCLUIDO',true,null,null),
('FR-MQ','Martinica',null,'UE_EXCLUIDO',true,null,null),
('FR-RE','Reunión',null,'UE_EXCLUIDO',true,null,null),
('FR-GF','Guayana Francesa',null,'UE_EXCLUIDO',true,null,null),
('FR-YT','Mayotte',null,'UE_EXCLUIDO',true,null,null),
('FR-MF','San Martín',null,'UE_EXCLUIDO',false,null,null),
('DE-HGL','Helgoland',null,'UE_EXCLUIDO',false,null,null),
('DE-BUS','Büsingen',null,'UE_EXCLUIDO',false,null,null),
('IT-LIV','Livigno',null,'UE_EXCLUIDO',false,null,null),
('IT-CDI','Campione d''Italia',null,'UE_EXCLUIDO',false,null,null),
('GR-ATH','Monte Athos',null,'UE_EXCLUIDO',true,null,null),
('AT','Austria','AT','UE',true,'AT',null),
('BE','Bélgica','BE','UE',true,'BE',null),
('BG','Bulgaria','BG','UE',true,'BG',null),
('CY','Chipre','CY','UE',true,'CY',null),
('CZ','Chequia','CZ','UE',true,'CZ',null),
('DE','Alemania','DE','UE',true,'DE',null),
('DK','Dinamarca','DK','UE',true,'DK',null),
('EE','Estonia','EE','UE',true,'EE',null),
('FI','Finlandia','FI','UE',true,'FI',null),
('FR','Francia','FR','UE',true,'FR',null),
('HR','Croacia','HR','UE',true,'HR',null),
('HU','Hungría','HU','UE',true,'HU',null),
('IE','Irlanda','IE','UE',true,'IE',null),
('IT','Italia','IT','UE',true,'IT',null),
('LT','Lituania','LT','UE',true,'LT',null),
('LU','Luxemburgo','LU','UE',true,'LU',null),
('LV','Letonia','LV','UE',true,'LV',null),
('MT','Malta','MT','UE',true,'MT',null),
('PL','Polonia','PL','UE',true,'PL',null),
('PT','Portugal','PT','UE',true,'PT',null),
('RO','Rumanía','RO','UE',true,'RO',null),
('SE','Suecia','SE','UE',true,'SE',null),
('SI','Eslovenia','SI','UE',true,'SI',null),
('SK','Eslovaquia','SK','UE',true,'SK',null),
('MA','Marruecos',null,'TERCERO',false,null,null),
('PE','Perú',null,'TERCERO',false,null,null),
('CO','Colombia',null,'TERCERO',false,null,null),
('MX','México',null,'TERCERO',false,null,null),
('CL','Chile',null,'TERCERO',false,null,null),
('EC','Ecuador',null,'TERCERO',false,null,null),
('US','Estados Unidos',null,'TERCERO',false,null,null),
('CA','Canadá',null,'TERCERO',false,null,null),
('CH','Suiza',null,'TERCERO',false,null,null),
('NO','Noruega',null,'TERCERO',false,null,null),
('AD','Andorra',null,'TERCERO',false,null,null),
('GI','Gibraltar',null,'TERCERO',false,null,null),
('SM','San Marino',null,'TERCERO',false,null,null),
('AE','Emiratos Árabes Unidos',null,'TERCERO',false,null,null),
('SA','Arabia Saudí',null,'TERCERO',false,null,null),
('CN','China',null,'TERCERO',false,null,null),
('HK','Hong Kong',null,'TERCERO',false,null,null),
('SG','Singapur',null,'TERCERO',false,null,null),
('JP','Japón',null,'TERCERO',false,null,null),
('KR','Corea del Sur',null,'TERCERO',false,null,null),
('IL','Israel',null,'TERCERO',false,null,null),
('TR','Turquía',null,'TERCERO',false,null,null)
on conflict (codigo) do nothing;
insert into erp_fiscal_tipo_iva (pais,categoria,porcentaje,clase,vigente_desde,vigente_hasta,base_legal) values
('ES','ALIM_NATURAL',0.0,'CERO','2023-01-01','2024-09-30','RDL 20/2022 y prórrogas (tipo 0% temporal; operación SUJETA, no exenta)'),
('ES','ALIM_NATURAL',2.0,'SUPERREDUCIDO','2024-10-01','2024-12-31','RDL 4/2024 (tipo temporal)'),
('ES','ALIM_NATURAL',4.0,'SUPERREDUCIDO','2025-01-01',null,'art. 91.Dos.1.1º Ley 37/1992 (frutas y hortalizas naturales)'),
('ES','RE_ALIM_NATURAL',0.5,'RECARGO','2025-01-01',null,'art. 161 Ley 37/1992 (recargo de equivalencia sobre tipo 4%)'),
('ES','GENERAL',21.0,'GENERAL','2012-09-01',null,'art. 90 Ley 37/1992'),
('NL','ALIM_NATURAL',9.0,'REDUCIDO','2019-01-01',null,'Tabel I, onderdeel a, post 1 Wet OB 1968 (voedingsmiddelen)'),
('NL','GENERAL',21.0,'GENERAL','2012-10-01',null,'art. 9 lid 1 Wet OB 1968')
on conflict (pais,categoria,vigente_desde) do nothing;
insert into erp_fiscal_texto_legal (codigo,idioma,texto,base_legal,estado_validacion,vigente_desde) values
('TX_ES_ICS','es','Entrega intracomunitaria exenta de IVA (art. 25 Ley 37/1992; art. 138 Directiva 2006/112/CE).','art. 25 LIVA; art. 138 Dir. 2006/112/CE; art. 6.1.j RD 1619/2012','PROPUESTO','2021-07-01'),
('TX_ES_ICS','en','VAT-exempt intra-Community supply (Art. 25 Spanish VAT Act 37/1992; Art. 138 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_ES_EXP','es','Exportación exenta de IVA (art. 21 Ley 37/1992; art. 146 Directiva 2006/112/CE).','art. 21 LIVA; art. 146 Dir. 2006/112/CE','PROPUESTO','2021-07-01'),
('TX_ES_EXP','en','VAT-exempt export (Art. 21 Spanish VAT Act 37/1992; Art. 146 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_ES_EXP_TT','es','Exportación exenta de IVA con destino a territorio tercero (arts. 3 y 21 Ley 37/1992).','arts. 3 y 21 LIVA','PROPUESTO','2021-07-01'),
('TX_ES_EXP_TT','en','VAT-exempt supply to a territory excluded from EU VAT (Arts. 3 and 21 Spanish VAT Act 37/1992).','idem','PROPUESTO','2021-07-01'),
('TX_ES_NS_LOC','es','Operación no sujeta al IVA español por reglas de localización (art. 68 Ley 37/1992).','art. 68 LIVA; art. 32 Dir. 2006/112/CE','PROPUESTO','2021-07-01'),
('TX_ES_NS_LOC','en','Not subject to Spanish VAT – place-of-supply rules (Art. 68 Spanish VAT Act 37/1992; Art. 32 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_ES_DEP','es','Entrega exenta de IVA de bienes vinculados al régimen de depósito aduanero (art. 24 Ley 37/1992).','art. 24 LIVA; art. 160 Dir. 2006/112/CE','PROPUESTO','2021-07-01'),
('TX_ES_DEP','en','VAT-exempt supply of goods placed under customs warehousing (Art. 24 Spanish VAT Act 37/1992; Art. 160 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_ES_TRI','es','Operación triangular. Inversión del sujeto pasivo: el destinatario es el sujeto pasivo (art. 26.Tres Ley 37/1992; arts. 141 y 197 Directiva 2006/112/CE).','art. 26.Tres y 84.Uno.2º LIVA; arts. 141, 197 y 226.11 bis Dir.','PROPUESTO','2021-07-01'),
('TX_ES_TRI','en','Intra-Community triangular transaction. Reverse charge: the customer is liable for VAT (Arts. 141 and 197 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_ES_RE','es','Recargo de equivalencia (art. 161 Ley 37/1992).','art. 161 LIVA','PROPUESTO','2021-07-01'),
('TX_ES_TRANSF','es','Transferencia de bienes propios asimilada a entrega intracomunitaria exenta (arts. 9.3º y 25.Tres Ley 37/1992). Documento interno: no es factura.','arts. 9.3º, 25.Tres y 79.Tres LIVA','PROPUESTO','2021-07-01'),
('TX_ES_CONSIGNA','es','Traslado en régimen de ventas de bienes en consigna (art. 9 bis Ley 37/1992; art. 17 bis Directiva 2006/112/CE). Documento interno: no es factura.','art. 9 bis LIVA; art. 17 bis Dir.; art. 54 bis R. Ejec. 282/2011','PROPUESTO','2021-07-01'),
('TX_DIST','es','Venta a distancia intracomunitaria: IVA del Estado miembro de llegada (art. 33 Directiva 2006/112/CE).','art. 33 Dir. 2006/112/CE','PROPUESTO','2021-07-01'),
('TX_DIST','en','Intra-Community distance sale: VAT of the Member State of arrival (Art. 33 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_NL_ICS','nl','Intracommunautaire levering – 0% btw (art. 138, lid 1, Richtlijn 2006/112/EG; Tabel II, onderdeel a, post 6, Wet OB 1968).','Tabel II a.6 Wet OB 1968; art. 138 Dir.','PROPUESTO','2021-07-01'),
('TX_NL_ICS','en','Intra-Community supply – 0% VAT (Art. 138(1) Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_NL_EXP','nl','Uitvoer – 0% btw (art. 146 Richtlijn 2006/112/EG).','art. 146 Dir. 2006/112/CE','PROPUESTO','2021-07-01'),
('TX_NL_EXP','en','Export – 0% VAT (Art. 146 Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01'),
('TX_NL_VERLEGD','nl','Btw verlegd (art. 12, lid 3, Wet OB 1968).','art. 12 lid 3 Wet OB 1968; art. 194 Dir.','PROPUESTO','2021-07-01'),
('TX_NL_VERLEGD','en','VAT reverse charged – customer liable (Art. 194 Directive 2006/112/EC; Art. 12(3) Dutch VAT Act 1968).','idem','PROPUESTO','2021-07-01'),
('TX_NL_DEP','nl','Levering van goederen onder de regeling douane-entrepot (nog niet ingevoerd) – 0% btw (Tabel II, onderdeel a, post 1, Wet OB 1968).','art. 9 lid 2 b + Tabel II a.1 Wet OB 1968; art. 160 Dir.','PROPUESTO','2021-07-01'),
('TX_NL_DEP','en','Supply of goods placed under customs warehousing (not yet imported) – 0% VAT (Art. 160 Directive 2006/112/EC; Table II, a.1, Dutch VAT Act 1968).','idem','PROPUESTO','2021-07-01'),
('TX_NL_REP','nl','Fiscaal vertegenwoordiger: {rep_nombre}, {rep_direccion}, btw-id {rep_vat} (art. 226, punt 15, Richtlijn 2006/112/EG).','art. 226.15 Dir. 2006/112/CE','PROPUESTO','2021-07-01'),
('TX_NL_REP','en','Fiscal representative: {rep_nombre}, {rep_direccion}, VAT ID {rep_vat} (Art. 226(15) Directive 2006/112/EC).','idem','PROPUESTO','2021-07-01')
on conflict (codigo,idioma,vigente_desde) do nothing;
insert into erp_fiscal_documento_req (codigo,nombre,base_legal,momento,plazo_dias) values
('FACTURA','Factura completa con NIF-IVA de ambas partes','RD 1619/2012 art. 6; art. 226 Dir. 2006/112/CE','AL_EMITIR',null),
('DOC_TRANSFERENCIA','Documento interno de transferencia valorado a coste (no es factura)','art. 79.Tres LIVA','AL_EMITIR',null),
('ALBARAN','Albarán / nota de entrega firmada por quien recoge','—','AL_EMITIR',null),
('VIES','Evidencia de consulta VIES: fecha, hora y nº de consulta','art. 25 LIVA; art. 138.1.c Dir.','ANTES_EMITIR',null),
('CMR','CMR (o documento de transporte equivalente) firmado por el destinatario','art. 45 bis R. Ejec. (UE) 282/2011','POSTERIOR',30),
('BL','Conocimiento de embarque (B/L) o AWB','—','POSTERIOR',30),
('PRUEBA_2_INDEP','Dos documentos no contradictorios de partes independientes (transporte + seguro/pago/factura transportista)','art. 45 bis.1.a R. Ejec. 282/2011','POSTERIOR',30),
('DECL_ADQUIRENTE','Declaración escrita del adquirente de llegada al EM de destino (antes del día 10 del mes siguiente)','art. 45 bis.1.b R. Ejec. 282/2011','POSTERIOR',null),
('DUA_EXP','Declaración de exportación (DUA) con MRN','Código Aduanero de la Unión','AL_EMITIR',null),
('PRUEBA_SALIDA','Confirmación electrónica de salida del territorio aduanero UE (ECS)','art. 21 LIVA; art. 146 Dir.','POSTERIOR',90),
('DUA_IMP','Declaración de importación con MRN y liquidación de IVA','arts. 17-18 LIVA','AL_EMITIR',null),
('DUA_42','Importación régimen 42: NIF-IVA del importador y del adquirente en otro EM + prueba de transporte','art. 27.12º LIVA; art. 143.1.d y 143.2 Dir.','AL_EMITIR',null),
('REF_ART23','Referencia de la licencia art. 23 (verlegging invoer-btw) del representante','art. 23 Wet OB 1968','AL_EMITIR',null),
('DOC_DEPOSITO','Entrada, permanencia y cambio de titularidad en depósito aduanero','art. 24 LIVA','AL_EMITIR',null),
('BL_ENDOSADO','B/L endosado o contrato de venta a flote con transmisión antes del despacho','art. 68 LIVA','AL_EMITIR',null),
('REG_CONSIGNA','Registro de bienes en consigna','art. 54 bis R. Ejec. 282/2011','AL_EMITIR',null),
('ACRED_RE','Comunicación del cliente de estar en recargo de equivalencia','art. 154 y ss. LIVA','ANTES_EMITIR',null),
('FACT_PROVEEDOR','Factura del proveedor de origen','—','AL_EMITIR',null),
('CONTRATO','Contrato o confirmación de venta con Incoterm','—','AL_EMITIR',null)
on conflict (codigo) do nothing;
insert into erp_fiscal_declaracion (codigo,pais,nombre,presenta,nota) values
('ES_303','ES','Modelo 303 — autoliquidación IVA','TB/asesor','Casillas según diseño vigente del modelo'),
('ES_390','ES','Modelo 390 — resumen anual','TB/asesor','Salvo exoneración (SII)'),
('ES_SII','ES','SII — Libros registro','TB/asesor','Solo si TB está en SII (obligatorio o voluntario)'),
('ES_349_E','ES','Modelo 349 — clave E (entregas intracomunitarias)','TB/asesor',null),
('ES_349_A','ES','Modelo 349 — clave A (adquisiciones intracomunitarias)','TB/asesor',null),
('ES_349_T','ES','Modelo 349 — clave T (operaciones triangulares)','TB/asesor',null),
('ES_349_M','ES','Modelo 349 — clave M (entregas tras importación exenta, régimen 42)','TB/asesor',null),
('ES_349_R','ES','Modelo 349 — clave R (traslados en consigna)','TB/asesor',null),
('ES_369','ES','Modelo 369 — ventanilla única (OSS)','TB/asesor','Solo si TB está dada de alta en OSS'),
('ES_INTRASTAT','ES','Intrastat','TB/asesor','Solo si se superan los umbrales'),
('ES_ADUANA','ES','Declaración aduanera (DUA) — importación/exportación','Agente de aduanas',null),
('ES_360','ES','Modelo 360 — devolución de IVA soportado en otro Estado miembro (no establecidos)','TB/asesor','No procede si TB realiza entregas en ese Estado en el periodo (art. 3 Dir. 2008/9/CE)'),
('NL_BTW','NL','Btw-aangifte','Según identificación NL','LFV: bajo el subnúmero del representante · representación general: el representante con el NIF NL de TB · registro directo: TB o su gestor'),
('NL_ICP','NL','Opgaaf intracommunautaire prestaties (ICP)','Según identificación NL',null),
('NL_INTRASTAT','NL','Intrastat (CBS)','Según identificación NL','Solo si se superan los umbrales'),
('NL_DOUANE','NL','Aangifte douane — invoer/uitvoer/entrepot','Agente de aduanas NL (Cool Control)',null)
on conflict (codigo) do nothing;
insert into erp_fiscal_incoterm (codigo,transporte_principal,despacho_exportacion,despacho_importacion,nota) values
('EXW','COMPRADOR','COMPRADOR','COMPRADOR','En exportación el exportador aduanero debe estar establecido en la UE: si el comprador no lo está, TB figura como exportador.'),
('FCA','COMPRADOR','VENDEDOR','COMPRADOR',null),
('FAS','COMPRADOR','VENDEDOR','COMPRADOR',null),
('FOB','COMPRADOR','VENDEDOR','COMPRADOR',null),
('CPT','VENDEDOR','VENDEDOR','COMPRADOR',null),
('CIP','VENDEDOR','VENDEDOR','COMPRADOR',null),
('CFR','VENDEDOR','VENDEDOR','COMPRADOR',null),
('CIF','VENDEDOR','VENDEDOR','COMPRADOR',null),
('DAP','VENDEDOR','VENDEDOR','COMPRADOR',null),
('DPU','VENDEDOR','VENDEDOR','COMPRADOR',null),
('DDP','VENDEDOR','VENDEDOR','VENDEDOR','Fuera del IVA UE, TB sería importador en destino.')
on conflict (codigo) do nothing;
insert into erp_fiscal_cobertura (codigo,jurisdiccion,descripcion) values
('IMPORT_40_ART23','NL','Importación a libre práctica con IVA verlegd (art. 23)'),
('IMPORT_40_ADUANA','NL','Importación a libre práctica con IVA pagado en aduana y deducido en NL'),
('IMPORT_42','NL','Importación régimen 42 + entrega intracomunitaria'),
('NL_ICS','NL','Entrega intracomunitaria desde NL'),
('NL_EXPORT','NL','Exportación desde NL'),
('NL_B2B_VERLEGD','NL','Venta en NL a empresa establecida en NL (btw verlegd)'),
('NL_VENTA_SUJETA','NL','Venta en NL con 9% repercutido (particular, sin NIF-IVA o comprador no establecido)'),
('NL_DEPOSITO','NL','Venta de mercancía en depósito aduanero NL (0%)'),
('NL_ADQ','NL','Adquisiciones intracomunitarias en NL (compras UE y transferencias de entrada)'),
('NL_TRANSF_SALIDA','NL','Transferencias de stock propio desde NL'),
('NL_DEDUCCION_SOPORTADO','NL','Deducción del btw soportado en compras en NL')
on conflict (codigo) do nothing;
insert into erp_fiscal_config (clave,valor,descripcion) values
('matriz_version','"2026.09-2"'::jsonb,'Versión de la matriz cargada'),
('vies_max_dias','7'::jsonb,'Antigüedad máxima de la consulta VIES para emitir'),
('ventas_distancia_umbral_superado','false'::jsonb,'TB supera (u optó por) el umbral UE de 10.000 € en ventas a distancia'),
('bloquear_textos_no_validados','false'::jsonb,'Si true, un texto legal PROPUESTO bloquea la emisión')
on conflict (clave) do nothing;
insert into erp_fiscal_representante (codigo,nombre,direccion,pais,vat_number,tipo_representacion,declaraciones,
  documentacion_requerida,garantia_requerida,garantia_tipo,garantia_importe,garantia_entidad,garantia_vencimiento,
  vigente_desde,vigente_hasta,contacto,activo,notas) values
('EXONERO','Exonero',null,'NL',null,'LIMITADA',array['NL_BTW','NL_ICP','NL_INTRASTAT','NL_DOUANE']::text[],
 array['FACTURA','CMR','DECL_ADQUIRENTE','DUA_IMP','DUA_EXP','PRUEBA_SALIDA']::text[],true,null,null,null,null,null,null,null,true,'Datos solicitados a Exonero (sept. 2026). Coberturas de la licencia pendientes de confirmar por escrito.')
on conflict (codigo) do nothing;
insert into erp_fiscal_identificacion (codigo,jurisdiccion,modalidad,estado,prioridad,empresa,nif,vat,numero_representacion,representante_codigo,coberturas,licencia_art23,roi_alta,roi_desde,sii,oss_alta,redeme,diferimiento_iva_importacion,notas) values
('ES_PROPIA','ES','PROPIA','ACTIVA',1,'Tropical Báez S.L.','B02989630','ESB02989630',null,null,array['*']::text[],false,true,null,null,null,null,null,'Alta en ROI confirmada (sept. 2026). Completar roi_desde con la fecha efectiva del alta.'),
('NL_EXONERO_LFV','NL','REP_LIMITADA','EN_TRAMITE',1,'Tropical Báez S.L. (licencia limitada Exonero)',null,null,null,'EXONERO',array['IMPORT_40_ART23','IMPORT_42','NL_ICS@IMPORT','NL_EXPORT@IMPORT','NL_B2B_VERLEGD@IMPORT']::text[],true,null,null,null,null,null,null,'Cobertura según lo acordado: importación y venta posterior de mercancía importada por TB. Pasar a ACTIVA cuando estén VAT, subnúmero, dirección y garantía.'),
('NL_REP_GENERAL','NL','REP_GENERAL','ESCENARIO',2,'Tropical Báez S.L. (NIF NL propio, representación general)',null,'NL_PENDIENTE',null,'EXONERO',array['*']::text[],true,null,null,null,null,null,null,'Escenario: ampliar Exonero a representación general. TB se registra en NL y el representante declara con el NIF NL de TB; exige garantía.'),
('NL_DIRECTA','NL','DIRECTA','ESCENARIO',3,'Tropical Báez S.L. (registro directo como empresa extranjera)',null,'NL_PENDIENTE',null,null,array['*']::text[],false,null,null,null,null,null,null,'Escenario: TB se registra directamente en la Belastingdienst (formulario Aanmelding Onderneming buitenland). Sin representante. Licencia art. 23 no supuesta: verificar.')
on conflict (codigo) do nothing;
insert into erp_fiscal_regla (codigo,version,prioridad,descripcion,condiciones,resultado,base_legal,estado_validacion,vigente_desde) values
('B-CADENA',1,10,'Operación en cadena sin triangulación declarada','{"cadena": [true], "triangular": [false]}'::jsonb,'{"revision": "Operación en cadena: hay que decidir a qué entrega se asigna el transporte (art. 36 bis Directiva 2006/112/CE). Requiere análisis previo."}'::jsonb,'art. 36 bis Dir.; art. 68.Dos.1º LIVA','PROPUESTO','2021-07-01'),
('B-DDP',1,20,'DDP con destino fuera del IVA UE','{"evento": ["VENTA"], "ddp": [true], "flujo": ["EXTRA_UE"]}'::jsonb,'{"revision": "Incoterm DDP fuera de la UE: TB sería importadora en destino y necesitaría registro fiscal y aduanero allí. Cambiar a DAP/DPU o acreditar el registro."}'::jsonb,'Incoterms 2020','PROPUESTO','2021-07-01'),
('B-TRANSITO-TB-IMPORTA',1,21,'Venta antes del despacho con TB como importador','{"evento": ["VENTA"], "flujo": ["FUERA_UE"], "importador": ["TB"]}'::jsonb,'{"revision": "Si TB despacha la mercancía, la entrega se localiza en el Estado miembro de importación (art. 32 párr. 2 Directiva; art. 68.Dos.1º LIVA). Registrar primero la importación y facturar como venta desde ese país."}'::jsonb,'art. 32 Dir.; art. 68 LIVA','PROPUESTO','2021-07-01'),
('OVR-ES',1,25,'Intracomunitaria sin NIF-IVA válido — facturar con IVA español (autorizado)','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT", "B2B_SIN_VAT"], "ics_requisitos_ok": [false], "override_iva_origen": [true]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303", "ES_390"], "documentos": ["FACTURA", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["Exención intracomunitaria no aplicada por autorización expresa de GERENCIA."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 25 LIVA (requisitos no cumplidos)','PROPUESTO','2021-07-01'),
('OVR-NL',1,25,'Intracomunitaria sin NIF-IVA válido — facturar con btw neerlandés (autorizado)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT", "B2B_SIN_VAT"], "ics_requisitos_ok": [false], "override_iva_origen": [true]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_BTW"], "documentos": ["FACTURA", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["Tipo 0% no aplicado por autorización expresa de GERENCIA."], "cobertura": "NL_VENTA_SUJETA", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'Tabel II a.6 Wet OB (requisitos no cumplidos)','PROPUESTO','2021-07-01'),
('B-SIN-VAT',1,30,'Empresa de otro EM sin NIF-IVA','{"evento": ["VENTA"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_SIN_VAT"]}'::jsonb,'{"revision": "Cliente empresa de otro Estado miembro sin NIF-IVA: no se puede aplicar la exención/tipo 0 intracomunitario. Obtener NIF-IVA válido o autorizar (GERENCIA) facturar con IVA del país de salida."}'::jsonb,'art. 138.1.b Dir.; art. 25 LIVA','PROPUESTO','2021-07-01'),
('B-VIES',1,31,'NIF-IVA del comprador no validado en VIES','{"evento": ["VENTA"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vies": ["INVALIDO", "NO_VERIFICADO", "CADUCADO", null]}'::jsonb,'{"revision": "NIF-IVA del comprador no validado en VIES (o consulta caducada). Repetir la consulta VIES antes de emitir."}'::jsonb,'art. 138.1.b Dir.; art. 25 LIVA','PROPUESTO','2021-07-01'),
('B-VAT-MS',1,32,'NIF-IVA del comprador del mismo EM de salida','{"evento": ["VENTA"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vat_ms_distinto": [false]}'::jsonb,'{"revision": "El NIF-IVA del comprador pertenece al Estado miembro de salida de la mercancía: no hay entrega intracomunitaria exenta. Pedir el NIF-IVA de otro Estado miembro."}'::jsonb,'art. 138.1.b Dir.','PROPUESTO','2021-07-01'),
('B-ROI',1,33,'TB España sin alta en ROI en la fecha de devengo','{"evento": ["VENTA", "TRANSFERENCIA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "roi": [false, null]}'::jsonb,'{"revision": "Tropical Báez no figura dada de alta en el ROI (modelo 036) en la fecha de devengo."}'::jsonb,'art. 25 LIVA; art. 164 LIVA','PROPUESTO','2021-07-01'),
('B-VIES-NL',1,34,'Venta interior NL con inversión sin VIES','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTERIOR"], "cliente_tipo": ["B2B_VAT"], "cliente_nl_establecido": [true], "vies": ["INVALIDO", "NO_VERIFICADO", "CADUCADO", null]}'::jsonb,'{"revision": "Inversión del sujeto pasivo en NL: validar en VIES el NIF-IVA neerlandés del comprador antes de emitir."}'::jsonb,'art. 12 lid 3 Wet OB 1968','PROPUESTO','2021-07-01'),
('NH-OSS',1,37,'Venta a distancia con IVA de destino sin alta en OSS','{"evento": ["VENTA"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2C"], "transporte_por": ["VENDEDOR"], "distancia_destino": [true], "oss": [false, null]}'::jsonb,'{"no_habilitada": "Venta a distancia que tributa en destino y TB no está en la ventanilla única (OSS). Alta en el régimen de la Unión (modelo 035) o registro de IVA en el país de destino."}'::jsonb,'arts. 33 y 369 bis Dir.; art. 163 octiesdecies LIVA','PROPUESTO','2021-07-01'),
('ES-INT-RE',1,99,'España → España, cliente en recargo de equivalencia','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTERIOR"], "re": [true]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": {"pais": "ES", "categoria": "RE_MERCANCIA"}, "textos": ["TX_ES_RE"], "declaraciones": ["ES_303", "ES_390", "ES_SII"], "documentos": ["FACTURA", "ALBARAN", "ACRED_RE"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 91.Dos y 161 LIVA','PROPUESTO','2021-07-01'),
('ES-INT',1,100,'España → España','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTERIOR"], "re": [false]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303", "ES_390", "ES_SII"], "documentos": ["FACTURA", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 4 y 91.Dos LIVA','PROPUESTO','2021-07-01'),
('ES-ICS-V',1,110,'España → UE, B2B, transporta TB','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vies": ["VALIDO"], "vat_ms_distinto": [true], "roi": [true], "transporte_por": ["VENDEDOR"], "triangular": [false]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTRACOMUNITARIA", "calificacion": "EXENTA_PLENA", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_ES_ICS"], "declaraciones": ["ES_303", "ES_349_E", "ES_INTRASTAT"], "documentos": ["FACTURA", "VIES", "CMR", "PRUEBA_2_INDEP"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 25 LIVA; art. 138 Dir.; art. 45 bis R. 282/2011','PROPUESTO','2021-07-01'),
('ES-ICS-C',1,111,'España → UE, B2B, recoge el cliente','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vies": ["VALIDO"], "vat_ms_distinto": [true], "roi": [true], "transporte_por": ["COMPRADOR"], "triangular": [false]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTRACOMUNITARIA", "calificacion": "EXENTA_PLENA", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_ES_ICS"], "declaraciones": ["ES_303", "ES_349_E", "ES_INTRASTAT"], "documentos": ["FACTURA", "VIES", "CMR", "DECL_ADQUIRENTE", "PRUEBA_2_INDEP"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["Recoge el cliente: sin su declaración escrita de llegada (día 10 del mes siguiente) la exención pierde la presunción de transporte."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 25 LIVA; art. 45 bis.1.b R. 282/2011','PROPUESTO','2021-07-01'),
('ES-DIST',1,120,'España → UE, particular, transporta TB (IVA de destino)','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2C"], "transporte_por": ["VENDEDOR"], "distancia_destino": [true], "oss": [true]}'::jsonb,'{"tipo_operacion": "VENTA_DISTANCIA_UE", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "DESTINO", "categoria": "MERCANCIA"}, "recargo": null, "textos": ["TX_DIST"], "declaraciones": ["ES_369"], "documentos": ["FACTURA", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 33 Dir.; art. 68.Tres LIVA','PROPUESTO','2021-07-01'),
('ES-DIST-BAJO',1,121,'España → UE, particular, transporta TB (bajo umbral)','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2C"], "transporte_por": ["VENDEDOR"], "distancia_destino": [false]}'::jsonb,'{"tipo_operacion": "VENTA_DISTANCIA_UE", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303", "ES_390"], "documentos": ["FACTURA", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["Bajo el umbral UE de 10.000 €: IVA español. Revisar el parámetro si se supera o si TB optó por tributar en destino."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 59 quater Dir.; art. 73 LIVA','PROPUESTO','2021-07-01'),
('ES-B2C-RECOGE',1,122,'España → UE, particular que recoge','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2C"], "transporte_por": ["COMPRADOR"]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303", "ES_390"], "documentos": ["FACTURA", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 68.Uno LIVA','PROPUESTO','2021-07-01'),
('ES-TRI',1,125,'Triangular: TB (NIF ES) compra en EM A y vende en EM C','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "triangular": [true], "cliente_tipo": ["B2B_VAT"], "vies": ["VALIDO"], "roi": [true]}'::jsonb,'{"tipo_operacion": "OPERACION_TRIANGULAR", "calificacion": "INVERSION_SUJETO_PASIVO", "untdid_5305": "AE", "tasa": null, "recargo": null, "textos": ["TX_ES_TRI"], "declaraciones": ["ES_303", "ES_349_T"], "documentos": ["FACTURA", "VIES", "CMR", "FACT_PROVEEDOR"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["Requisitos: TB no establecida ni identificada en el EM de llegada; transporte directo de A a C; comprador identificado en C."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 141 y 197 Dir.; art. 26.Tres LIVA','PROPUESTO','2021-07-01'),
('ES-EXP-CN',1,128,'España → Canarias','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["EXTRA_UE"], "zona_destino": ["ES_CN"], "exp_valida": [true]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "EXENTA_PLENA", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_ES_EXP_TT"], "declaraciones": ["ES_303", "ES_ADUANA"], "documentos": ["FACTURA", "DUA_EXP", "PRUEBA_SALIDA", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": ["IGIC (y en su caso AIEM) los liquida el importador en Canarias."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 3 y 21 LIVA','PROPUESTO','2021-07-01'),
('ES-EXP-CEML',1,129,'España → Ceuta / Melilla','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["EXTRA_UE"], "zona_destino": ["ES_CEML"], "exp_valida": [true]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "EXENTA_PLENA", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_ES_EXP_TT"], "declaraciones": ["ES_303", "ES_ADUANA"], "documentos": ["FACTURA", "DUA_EXP", "PRUEBA_SALIDA", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": ["IPSI lo liquida el importador en destino."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 3 y 21 LIVA','PROPUESTO','2021-07-01'),
('ES-EXP-V',1,130,'España → UK / Marruecos / terceros, transporta TB','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["EXTRA_UE"], "zona_destino": ["TERCERO", "UE_EXCLUIDO"], "transporte_por": ["VENDEDOR"]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "EXENTA_PLENA", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_ES_EXP"], "declaraciones": ["ES_303", "ES_ADUANA"], "documentos": ["FACTURA", "DUA_EXP", "PRUEBA_SALIDA", "BL", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 21.1º LIVA; art. 146.1.a Dir.','PROPUESTO','2021-07-01'),
('ES-EXP-C',1,131,'España → terceros, transporta comprador no establecido','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["EXTRA_UE"], "zona_destino": ["TERCERO", "UE_EXCLUIDO"], "transporte_por": ["COMPRADOR"], "cliente_establecido_tai": [false]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "EXENTA_PLENA", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_ES_EXP"], "declaraciones": ["ES_303", "ES_ADUANA"], "documentos": ["FACTURA", "DUA_EXP", "PRUEBA_SALIDA", "BL", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": ["La mercancía debe salir en 3 meses. Si el comprador no está establecido en la UE, TB debe figurar como exportador en la declaración."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 21.2º LIVA; art. 146.1.b Dir.','PROPUESTO','2021-07-01'),
('ES-EXP-C-TAI',1,132,'España → terceros, transporta comprador establecido en España','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["EXTRA_UE"], "transporte_por": ["COMPRADOR"], "cliente_establecido_tai": [true]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303", "ES_390"], "documentos": ["FACTURA", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["Comprador establecido en el TAI que exporta por su cuenta: la entrega de TB es interior sujeta (no aplica art. 21.2º)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 21.2º LIVA a contrario','PROPUESTO','2021-07-01'),
('ES-DEP',1,140,'Venta de mercancía en depósito aduanero en España','{"evento": ["VENTA"], "perfil": ["ES"], "flujo": ["DEPOSITO"]}'::jsonb,'{"tipo_operacion": "VENTA_EN_DEPOSITO", "calificacion": "EXENTA_PLENA", "untdid_5305": "E", "tasa": null, "recargo": null, "textos": ["TX_ES_DEP"], "declaraciones": ["ES_303", "ES_ADUANA"], "documentos": ["FACTURA", "DOC_DEPOSITO"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 24 LIVA; art. 160 Dir.','PROPUESTO','2021-07-01'),
('ES-NS-TRANSITO',1,150,'Venta a flote / en origen (el cliente importa)','{"evento": ["VENTA"], "flujo": ["FUERA_UE"], "importador": ["CLIENTE"]}'::jsonb,'{"tipo_operacion": "VENTA_NO_SUJETA_LOCALIZACION", "calificacion": "NO_SUJETA", "untdid_5305": "O", "tasa": null, "recargo": null, "textos": ["TX_ES_NS_LOC"], "declaraciones": ["ES_303"], "documentos": ["FACTURA", "CONTRATO", "BL_ENDOSADO"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 68 LIVA; art. 32 Dir.','PROPUESTO','2021-07-01'),
('ES-TRANSF-CONSIGNA',1,170,'Traslado ES → UE en consigna','{"evento": ["TRANSFERENCIA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "consigna": [true], "roi": [true]}'::jsonb,'{"tipo_operacion": "TRANSFERENCIA_CONSIGNA", "calificacion": "NO_SUJETA", "untdid_5305": "O", "tasa": null, "recargo": null, "textos": ["TX_ES_CONSIGNA"], "declaraciones": ["ES_349_R"], "documentos": ["DOC_TRANSFERENCIA", "REG_CONSIGNA", "CMR"], "flags": {"vies": false, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["La entrega intracomunitaria se produce cuando el cliente retira la mercancía (plazo 12 meses)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 9 bis LIVA; art. 17 bis Dir.','PROPUESTO','2021-07-01'),
('ES-TRANSF',1,171,'Transferencia de stock propio ES → UE (p. ej. a Cool Control)','{"evento": ["TRANSFERENCIA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "consigna": [false], "roi": [true]}'::jsonb,'{"tipo_operacion": "TRANSFERENCIA_STOCK", "calificacion": "EXENTA_PLENA", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_ES_TRANSF"], "declaraciones": ["ES_303", "ES_349_E"], "documentos": ["DOC_TRANSFERENCIA", "CMR"], "flags": {"vies": false, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["En destino TB realiza una adquisición intracomunitaria asimilada que declara con su identificación de ese país."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": "ADQ"}'::jsonb,'arts. 9.3º y 25.Tres LIVA','PROPUESTO','2021-07-01'),
('ES-TRANSF-EXT',1,172,'Traslado de stock propio ES → fuera UE','{"evento": ["TRANSFERENCIA"], "perfil": ["ES"], "flujo": ["EXTRA_UE"]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "EXENTA_PLENA", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_ES_EXP"], "declaraciones": ["ES_303", "ES_ADUANA"], "documentos": ["DOC_TRANSFERENCIA", "DUA_EXP", "PRUEBA_SALIDA"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": ["En destino TB será importadora: necesita registro fiscal/aduanero allí (p. ej. EORI GB e IVA UK)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 21 LIVA','PROPUESTO','2021-07-01'),
('NL-INT-B2B',1,200,'Holanda → Holanda, empresa establecida en NL (btw verlegd)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTERIOR"], "cliente_tipo": ["B2B_VAT"], "cliente_nl_establecido": [true], "vies": ["VALIDO"]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR_ISP", "calificacion": "INVERSION_SUJETO_PASIVO", "untdid_5305": "AE", "tasa": null, "recargo": null, "textos": ["TX_NL_VERLEGD"], "declaraciones": ["NL_BTW"], "documentos": ["FACTURA", "VIES", "ALBARAN"], "flags": {"vies": true, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": "NL_B2B_VERLEGD", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 12 lid 3 Wet OB 1968; art. 194 Dir.','PROPUESTO','2021-07-01'),
('NL-INT-SUJETA',1,210,'Holanda → Holanda, particular o empresa sin NIF-IVA (9%)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTERIOR"], "cliente_tipo": ["B2C", "B2B_SIN_VAT"]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_BTW"], "documentos": ["FACTURA", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": "NL_VENTA_SUJETA", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 5 lid 1 y Tabel I a.1 Wet OB 1968','PROPUESTO','2021-07-01'),
('NL-INT-NOEST',1,211,'Holanda → Holanda, empresa no establecida en NL (9%)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTERIOR"], "cliente_tipo": ["B2B_VAT"], "cliente_nl_establecido": [false]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_BTW"], "documentos": ["FACTURA", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["Comprador sin establecimiento en NL y mercancía que no sale de NL: no procede btw verlegd; TB repercute el 9%. Si el comprador tiene establecimiento permanente en NL, marcarlo en su ficha (pasa a verlegd)."], "cobertura": "NL_VENTA_SUJETA", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 12 lid 3 Wet OB 1968 a contrario','PROPUESTO','2021-07-01'),
('NL-ICS-42',1,219,'Importación régimen 42 en NL + entrega intracomunitaria','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vies": ["VALIDO"], "vat_ms_distinto": [true], "regimen_importacion": ["42"]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTRACOMUNITARIA", "calificacion": "TIPO_CERO", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_NL_ICS"], "declaraciones": ["NL_BTW", "NL_ICP", "NL_INTRASTAT"], "documentos": ["FACTURA", "VIES", "DUA_42", "CMR", "PRUEBA_2_INDEP"], "flags": {"vies": true, "m349_icp": true, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": "IMPORT_42", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 143.1.d Dir.; Tabel II a.6 Wet OB','PROPUESTO','2021-07-01'),
('NL-ICS-V',1,220,'Holanda → UE (incl. España), B2B, transporta TB','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vies": ["VALIDO"], "vat_ms_distinto": [true], "transporte_por": ["VENDEDOR"], "regimen_importacion": ["40", null]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTRACOMUNITARIA", "calificacion": "TIPO_CERO", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_NL_ICS"], "declaraciones": ["NL_BTW", "NL_ICP", "NL_INTRASTAT"], "documentos": ["FACTURA", "VIES", "CMR", "PRUEBA_2_INDEP"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": "NL_ICS", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'Tabel II a.6 Wet OB 1968; art. 138 Dir.','PROPUESTO','2021-07-01'),
('NL-ICS-C',1,221,'Holanda → UE (incl. España), B2B, recoge el cliente (EXW Cool Control)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2B_VAT"], "vies": ["VALIDO"], "vat_ms_distinto": [true], "transporte_por": ["COMPRADOR"], "regimen_importacion": ["40", null]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTRACOMUNITARIA", "calificacion": "TIPO_CERO", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_NL_ICS"], "declaraciones": ["NL_BTW", "NL_ICP", "NL_INTRASTAT"], "documentos": ["FACTURA", "VIES", "CMR", "DECL_ADQUIRENTE", "PRUEBA_2_INDEP"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["EXW: sin CMR firmado en destino y declaración escrita del comprador no se puede sostener el 0%."], "cobertura": "NL_ICS", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'Tabel II a.6 Wet OB 1968; art. 45 bis R. 282/2011','PROPUESTO','2021-07-01'),
('NL-DIST',1,230,'Holanda → UE, particular, transporta TB (OSS España)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2C"], "transporte_por": ["VENDEDOR"], "oss": [true]}'::jsonb,'{"tipo_operacion": "VENTA_DISTANCIA_UE", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "DESTINO", "categoria": "MERCANCIA"}, "recargo": null, "textos": ["TX_DIST"], "declaraciones": ["ES_369"], "documentos": ["FACTURA", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["Expedición desde NL: IVA del país de llegada declarado en la OSS española y factura con el NIF-IVA español. Criterio aplicado: el umbral de 10.000 € no cubre expediciones desde un Estado distinto del de establecimiento (validar con el asesor)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": "ES", "requiere_destino": null}'::jsonb,'arts. 33, 59 quater y 219 bis.2.b Dir.','PROPUESTO','2021-07-01'),
('NL-B2C-RECOGE',1,231,'Holanda → UE, particular que recoge en NL','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "cliente_tipo": ["B2C"], "transporte_por": ["COMPRADOR"]}'::jsonb,'{"tipo_operacion": "ENTREGA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_BTW"], "documentos": ["FACTURA", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": "NL_VENTA_SUJETA", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 31 Dir.','PROPUESTO','2021-07-01'),
('NL-EXP-V',1,240,'Holanda → UK / Marruecos / terceros / Canarias, transporta TB','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["EXTRA_UE"], "transporte_por": ["VENDEDOR"]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "TIPO_CERO", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_NL_EXP"], "declaraciones": ["NL_BTW", "NL_DOUANE"], "documentos": ["FACTURA", "DUA_EXP", "PRUEBA_SALIDA", "BL", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": [], "cobertura": "NL_EXPORT", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'Tabel II a.2 Wet OB; art. 146.1.a Dir.','PROPUESTO','2021-07-01'),
('NL-EXP-C',1,241,'Holanda → terceros, recoge el comprador','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["EXTRA_UE"], "transporte_por": ["COMPRADOR"]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "TIPO_CERO", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_NL_EXP"], "declaraciones": ["NL_BTW", "NL_DOUANE"], "documentos": ["FACTURA", "DUA_EXP", "PRUEBA_SALIDA", "BL", "CMR"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": ["El exportador aduanero debe estar establecido en la UE: TB (o su representante) figura como exportador aunque recoja el comprador."], "cobertura": "NL_EXPORT", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'Tabel II a.2 Wet OB; art. 146.1.b Dir.','PROPUESTO','2021-07-01'),
('NL-DEP',1,250,'Venta de mercancía en depósito aduanero en NL (sin despachar)','{"evento": ["VENTA"], "perfil": ["NL"], "flujo": ["DEPOSITO"]}'::jsonb,'{"tipo_operacion": "VENTA_EN_DEPOSITO", "calificacion": "TIPO_CERO", "untdid_5305": "Z", "tasa": null, "recargo": null, "textos": ["TX_NL_DEP"], "declaraciones": ["NL_BTW", "NL_DOUANE"], "documentos": ["FACTURA", "DOC_DEPOSITO"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": ["El comprador pasa a ser titular en el depósito: el IVA surgirá cuando se despache a libre práctica (lo liquida quien importe)."], "cobertura": "NL_DEPOSITO", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 9 lid 2 b y Tabel II a.1 Wet OB 1968; art. 160 Dir.','PROPUESTO','2021-07-01'),
('NL-TRANSF',1,260,'Transferencia de stock propio NL → UE (p. ej. a España)','{"evento": ["TRANSFERENCIA"], "perfil": ["NL"], "flujo": ["INTRA_UE"]}'::jsonb,'{"tipo_operacion": "TRANSFERENCIA_STOCK", "calificacion": "TIPO_CERO", "untdid_5305": "K", "tasa": null, "recargo": null, "textos": ["TX_NL_ICS"], "declaraciones": ["NL_BTW", "NL_ICP", "ES_303", "ES_349_A"], "documentos": ["DOC_TRANSFERENCIA", "CMR"], "flags": {"vies": false, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": "NL_TRANSF_SALIDA", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": "ADQ"}'::jsonb,'art. 17 Dir.; art. 16.2º LIVA','PROPUESTO','2021-07-01'),
('NL-TRANSF-EXT',1,261,'Traslado de stock propio NL → fuera UE','{"evento": ["TRANSFERENCIA"], "perfil": ["NL"], "flujo": ["EXTRA_UE"]}'::jsonb,'{"tipo_operacion": "EXPORTACION", "calificacion": "TIPO_CERO", "untdid_5305": "G", "tasa": null, "recargo": null, "textos": ["TX_NL_EXP"], "declaraciones": ["NL_BTW", "NL_DOUANE"], "documentos": ["DOC_TRANSFERENCIA", "DUA_EXP", "PRUEBA_SALIDA"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": true}, "avisos": ["En destino TB será importadora: necesita registro fiscal/aduanero allí."], "cobertura": "NL_EXPORT", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 146 Dir.','PROPUESTO','2021-07-01'),
('CMP-EXT',1,280,'Compra de mercancía fuera del territorio IVA UE (FOB/CFR origen, a flote)','{"evento": ["COMPRA"], "flujo": ["FUERA_UE"]}'::jsonb,'{"tipo_operacion": "COMPRA_NO_SUJETA", "calificacion": "NO_SUJETA", "untdid_5305": "O", "tasa": null, "recargo": null, "textos": [], "declaraciones": [], "documentos": ["FACT_PROVEEDOR", "CONTRATO", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["El IVA surge al importar: registrar después el evento IMPORTACION en el país de despacho."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 68 LIVA; art. 32 Dir.','PROPUESTO','2021-07-01'),
('CMP-DEP-ES',1,281,'Compra de mercancía en depósito aduanero en España','{"evento": ["COMPRA"], "perfil": ["ES"], "flujo": ["DEPOSITO"]}'::jsonb,'{"tipo_operacion": "COMPRA_EN_DEPOSITO", "calificacion": "EXENTA_PLENA", "untdid_5305": "E", "tasa": null, "recargo": null, "textos": [], "declaraciones": ["ES_303"], "documentos": ["FACT_PROVEEDOR", "DOC_DEPOSITO"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 24 LIVA','PROPUESTO','2021-07-01'),
('CMP-DEP-NL',1,282,'Compra de mercancía en depósito aduanero en NL','{"evento": ["COMPRA"], "perfil": ["NL"], "flujo": ["DEPOSITO"]}'::jsonb,'{"tipo_operacion": "COMPRA_EN_DEPOSITO", "calificacion": "TIPO_CERO", "untdid_5305": "Z", "tasa": null, "recargo": null, "textos": [], "declaraciones": [], "documentos": ["FACT_PROVEEDOR", "DOC_DEPOSITO"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": ["Sin IVA mientras siga en depósito. Al despachar, registrar la IMPORTACION (TB importadora)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'Tabel II a.1 Wet OB 1968','PROPUESTO','2021-07-01'),
('CMP-ES-INT',1,283,'Compra en España a proveedor establecido en España','{"evento": ["COMPRA"], "perfil": ["ES"], "flujo": ["INTERIOR"], "proveedor_establecido_local": [true]}'::jsonb,'{"tipo_operacion": "COMPRA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303"], "documentos": ["FACT_PROVEEDOR", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 92 y ss. LIVA','PROPUESTO','2021-07-01'),
('CMP-ES-ISP',1,284,'Compra en España a proveedor no establecido (inversión del sujeto pasivo)','{"evento": ["COMPRA"], "perfil": ["ES"], "flujo": ["INTERIOR"], "proveedor_establecido_local": [false]}'::jsonb,'{"tipo_operacion": "COMPRA_INTERIOR_ISP", "calificacion": "INVERSION_SUJETO_PASIVO", "untdid_5305": "AE", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303"], "documentos": ["FACT_PROVEEDOR", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["El proveedor no debe repercutir IVA español: TB lo autoliquida (devengado y deducible en el mismo 303)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": true, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 84.Uno.2º.a LIVA','PROPUESTO','2021-07-01'),
('CMP-NL-INT',1,285,'Compra en NL (mercancía que ya está en NL)','{"evento": ["COMPRA"], "perfil": ["NL"], "flujo": ["INTERIOR"]}'::jsonb,'{"tipo_operacion": "COMPRA_INTERIOR", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_BTW"], "documentos": ["FACT_PROVEEDOR", "ALBARAN"], "flags": {"vies": false, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["TB no está establecida en NL: el proveedor repercute el 9%. Para vender después desde NL, la venta exige una identificación NL que cubra mercancía comprada en NL."], "cobertura": "NL_DEDUCCION_SOPORTADO", "cobertura_bloquea": false, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 5 y 15 Wet OB 1968','PROPUESTO','2021-07-01'),
('ADQ-ES-SIN-ROI',1,289,'Adquisición intracomunitaria sin ROI','{"evento": ["COMPRA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "roi": [false, null]}'::jsonb,'{"revision": "Adquisición intracomunitaria: el proveedor solo puede aplicar la exención si TB comunica un NIF-IVA válido (alta en ROI no vigente en la fecha)."}'::jsonb,'art. 25 LIVA','PROPUESTO','2021-07-01'),
('ADQ-ES',1,290,'Adquisición intracomunitaria con llegada a España','{"evento": ["COMPRA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "roi": [true], "triangular": [false]}'::jsonb,'{"tipo_operacion": "ADQUISICION_INTRACOMUNITARIA", "calificacion": "SUJETA", "untdid_5305": "K", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_303", "ES_349_A", "ES_INTRASTAT"], "documentos": ["FACT_PROVEEDOR", "VIES", "CMR"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["Comunicar al proveedor el NIF-IVA ESB02989630 para que aplique la exención; si repercute su IVA, reclamar factura rectificativa."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": true, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 13, 15 y 85 LIVA','PROPUESTO','2021-07-01'),
('ADQ-NL',1,291,'Adquisición intracomunitaria con llegada a NL','{"evento": ["COMPRA"], "perfil": ["NL"], "flujo": ["INTRA_UE"], "triangular": [false]}'::jsonb,'{"tipo_operacion": "ADQUISICION_INTRACOMUNITARIA", "calificacion": "SUJETA", "untdid_5305": "K", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_BTW", "NL_INTRASTAT"], "documentos": ["FACT_PROVEEDOR", "VIES", "CMR"], "flags": {"vies": true, "m349_icp": false, "aduana": false, "mrn_salida": false}, "avisos": ["El proveedor debe facturar a la identificación NL de TB (no a la española) para que la adquisición se declare en NL."], "cobertura": "NL_ADQ", "cobertura_bloquea": true, "autoliquidacion": true, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 1 onderdeel b y art. 17a Wet OB 1968','PROPUESTO','2021-07-01'),
('CMP-TRI',1,292,'Compra en operación triangular (TB intermediario con NIF ES)','{"evento": ["COMPRA"], "perfil": ["ES"], "flujo": ["INTRA_UE"], "triangular": [true], "roi": [true]}'::jsonb,'{"tipo_operacion": "ADQUISICION_INTRACOMUNITARIA", "calificacion": "EXENTA_PLENA", "untdid_5305": "E", "tasa": null, "recargo": null, "textos": [], "declaraciones": ["ES_349_T"], "documentos": ["FACT_PROVEEDOR", "VIES", "CMR"], "flags": {"vies": true, "m349_icp": true, "aduana": false, "mrn_salida": false}, "avisos": ["Exenta en el EM de llegada solo si la venta posterior se factura como triangular (regla ES-TRI)."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 141 y 197 Dir.; art. 26.Tres LIVA','PROPUESTO','2021-07-01'),
('IMP-ES-40-DIF',1,299,'Importación en España con IVA diferido','{"evento": ["IMPORTACION"], "perfil": ["ES"], "regimen_importacion": ["40"], "diferimiento": [true]}'::jsonb,'{"tipo_operacion": "IMPORTACION", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_ADUANA", "ES_303"], "documentos": ["DUA_IMP", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": ["IVA a la importación diferido: se ingresa y deduce en el mismo modelo 303."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": true, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 167.Dos LIVA; art. 74 RIVA','PROPUESTO','2021-07-01'),
('IMP-ES-40',1,300,'Importación en España (IVA pagado en aduana)','{"evento": ["IMPORTACION"], "perfil": ["ES"], "regimen_importacion": ["40"], "diferimiento": [false, null]}'::jsonb,'{"tipo_operacion": "IMPORTACION", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "ES", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["ES_ADUANA", "ES_303"], "documentos": ["DUA_IMP", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": ["IVA a la importación pagado en aduana y deducible en el 303. Con SII o REDEME TB puede optar al diferimiento."], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 17, 18 y 167.Dos LIVA','PROPUESTO','2021-07-01'),
('IMP-ES-42',1,301,'Importación en España régimen 42 (exenta + entrega intracomunitaria inmediata)','{"evento": ["IMPORTACION"], "perfil": ["ES"], "regimen_importacion": ["42"]}'::jsonb,'{"tipo_operacion": "IMPORTACION_EXENTA", "calificacion": "EXENTA_PLENA", "untdid_5305": "E", "tasa": null, "recargo": null, "textos": [], "declaraciones": ["ES_ADUANA", "ES_349_M"], "documentos": ["DUA_42", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": true, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 27.12º LIVA','PROPUESTO','2021-07-01'),
('IMP-NL-40-A23',1,309,'Importación en NL con verlegging (licencia art. 23)','{"evento": ["IMPORTACION"], "perfil": ["NL"], "regimen_importacion": ["40"], "art23": [true]}'::jsonb,'{"tipo_operacion": "IMPORTACION", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_DOUANE", "NL_BTW"], "documentos": ["DUA_IMP", "REF_ART23", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": ["IVA a la importación verlegd: se declara y deduce en la misma btw-aangifte. Sin coste de caja."], "cobertura": "IMPORT_40_ART23", "cobertura_bloquea": true, "autoliquidacion": true, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 23 Wet OB 1968','PROPUESTO','2021-07-01'),
('IMP-NL-40',1,310,'Importación en NL sin licencia art. 23 (IVA pagado en aduana)','{"evento": ["IMPORTACION"], "perfil": ["NL"], "regimen_importacion": ["40"], "art23": [false, null]}'::jsonb,'{"tipo_operacion": "IMPORTACION", "calificacion": "SUJETA", "untdid_5305": "S", "tasa": {"pais": "NL", "categoria": "MERCANCIA"}, "recargo": null, "textos": [], "declaraciones": ["NL_DOUANE", "NL_BTW"], "documentos": ["DUA_IMP", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": ["Sin art. 23 el 9% se paga a la aduana y se recupera en la btw-aangifte: coste financiero de 1 a 3 meses."], "cobertura": "IMPORT_40_ADUANA", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'arts. 18 y 22 Wet OB 1968','PROPUESTO','2021-07-01'),
('IMP-NL-42',1,311,'Importación en NL régimen 42','{"evento": ["IMPORTACION"], "perfil": ["NL"], "regimen_importacion": ["42"]}'::jsonb,'{"tipo_operacion": "IMPORTACION_EXENTA", "calificacion": "EXENTA_PLENA", "untdid_5305": "E", "tasa": null, "recargo": null, "textos": [], "declaraciones": ["NL_DOUANE", "NL_BTW", "NL_ICP"], "documentos": ["DUA_42", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": true, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": "IMPORT_42", "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 143.1.d Dir.','PROPUESTO','2021-07-01'),
('IMP-DEP-ES',1,320,'Entrada en depósito aduanero en España (IVA suspendido)','{"evento": ["IMPORTACION"], "perfil": ["ES"], "regimen_importacion": ["DEPOSITO"]}'::jsonb,'{"tipo_operacion": "ENTRADA_DEPOSITO", "calificacion": "SUSPENSION_ADUANERA", "untdid_5305": "O", "tasa": null, "recargo": null, "textos": [], "declaraciones": ["ES_ADUANA"], "documentos": ["DOC_DEPOSITO", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 24 LIVA; art. 156 Dir.','PROPUESTO','2021-07-01'),
('IMP-DEP-NL',1,321,'Entrada en depósito aduanero en NL (IVA suspendido)','{"evento": ["IMPORTACION"], "perfil": ["NL"], "regimen_importacion": ["DEPOSITO"]}'::jsonb,'{"tipo_operacion": "ENTRADA_DEPOSITO", "calificacion": "SUSPENSION_ADUANERA", "untdid_5305": "O", "tasa": null, "recargo": null, "textos": [], "declaraciones": ["NL_DOUANE"], "documentos": ["DOC_DEPOSITO", "FACT_PROVEEDOR", "BL"], "flags": {"vies": false, "m349_icp": false, "aduana": true, "mrn_salida": false}, "avisos": [], "cobertura": null, "cobertura_bloquea": true, "autoliquidacion": false, "factura_con": null, "requiere_destino": null}'::jsonb,'art. 156 Dir.','PROPUESTO','2021-07-01')
on conflict (codigo,version) do nothing;

-- ============ 9. ENLACE CON LA FACTURACIÓN EXISTENTE ============
-- Añade erp_documento.fiscal_determinacion_id y erp_fiscal_determinacion.documento_id
-- con el mismo tipo que erp_documento.id (sea uuid o bigint).
do $$
declare t text;
begin
  select format_type(a.atttypid, a.atttypmod) into t
  from pg_attribute a
  where a.attrelid = 'public.erp_documento'::regclass and a.attname = 'id' and not a.attisdropped;

  if t is null then
    raise notice 'erp_documento no encontrado: enlace omitido';
    return;
  end if;

  if not exists (select 1 from information_schema.columns
                 where table_name = 'erp_fiscal_determinacion' and column_name = 'documento_id') then
    execute format('alter table erp_fiscal_determinacion add column documento_id %s references erp_documento(id)', t);
    create index erp_fiscal_det_doc on erp_fiscal_determinacion (documento_id);
  end if;

  if not exists (select 1 from information_schema.columns
                 where table_name = 'erp_documento' and column_name = 'fiscal_determinacion_id') then
    alter table erp_documento add column fiscal_determinacion_id bigint references erp_fiscal_determinacion(id);
  end if;
end $$;

-- ============ 10. SEGURIDAD (RLS) ============
-- Lectura para usuarios autenticados. Escritura de la matriz y del representante:
-- sustituir "true" por la comprobación de rol GERENCIA que usan las migraciones 01–08.
do $$
declare tb text;
begin
  foreach tb in array array['erp_fiscal_territorio','erp_fiscal_tipo_iva','erp_fiscal_texto_legal','erp_fiscal_documento_req',
    'erp_fiscal_declaracion','erp_fiscal_incoterm','erp_fiscal_cobertura','erp_fiscal_config','erp_fiscal_representante',
    'erp_fiscal_identificacion','erp_fiscal_regla','erp_fiscal_determinacion','erp_fiscal_vies_consulta']
  loop
    execute format('alter table %I enable row level security', tb);
    execute format('drop policy if exists %I on %I', tb || '_leer', tb);
    execute format('create policy %I on %I for select to authenticated using (true)', tb || '_leer', tb);
  end loop;

  -- Maestros editables (GERENCIA)
  foreach tb in array array['erp_fiscal_territorio','erp_fiscal_tipo_iva','erp_fiscal_texto_legal','erp_fiscal_documento_req',
    'erp_fiscal_declaracion','erp_fiscal_incoterm','erp_fiscal_cobertura','erp_fiscal_config','erp_fiscal_representante',
    'erp_fiscal_identificacion','erp_fiscal_regla']
  loop
    execute format('drop policy if exists %I on %I', tb || '_escribir', tb);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', tb || '_escribir', tb);
  end loop;

  -- Registros de auditoría: solo alta
  foreach tb in array array['erp_fiscal_determinacion','erp_fiscal_vies_consulta']
  loop
    execute format('drop policy if exists %I on %I', tb || '_alta', tb);
    execute format('create policy %I on %I for insert to authenticated with check (true)', tb || '_alta', tb);
  end loop;
end $$;
