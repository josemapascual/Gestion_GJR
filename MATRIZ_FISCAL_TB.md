# Matriz fiscal de IVA — Tropical Báez

Versión de matriz `2026.09-2` · motor `tb_fiscal_engine.js 2.0.0` · migración `09_matriz_fiscal_tb.sql`

## Resumen

- El sistema separa tres cosas que antes estaban mezcladas: **si faltan datos**, **qué dice la ley** y **si TB está registrada para hacerlo**. Así la matriz cubre todas las operaciones aunque Exonero todavía no esté operativo.
- **La ley** la decide una matriz de 60 reglas en base de datos a partir de los hechos de la operación: dónde está la mercancía, adónde va, tipo de operación, cliente o proveedor, transporte, Incoterm y aduana. No depende de la licencia de Exonero.
- **El registro** lo deciden las identificaciones fiscales de TB: España propia (activa, ROI confirmado), Holanda vía Exonero (en trámite) y dos escenarios (representación general y registro directo en NL) para comparar.
- Cuatro estados por factura: **OK** (se numera) · **REVISIÓN FISCAL NECESARIA** (falta un dato) · **NO HABILITADA** (el tratamiento está claro, pero TB no tiene hoy el registro que lo permite; dice cuál lo permitiría) · **SIMULACIÓN** (prueba con un escenario, nunca numera).
- Cubre ventas ES→ES/UE/terceros (incluidos Reino Unido, Marruecos, Canarias, Ceuta y Melilla), ventas NL→NL/ES/UE/terceros, compras (en origen, en España, en Holanda, a proveedores UE, en depósito), importaciones (ES y NL, regímenes 40, 42 y depósito) y transferencias de stock.
- Probado con 58 escenarios: 40 OK, 12 NO HABILITADA (todas por registro en NL u OSS), 5 REVISIÓN (datos que faltan a propósito) y 1 SIMULACIÓN.

---

## 1. Arquitectura en tres capas

```
 hechos de la operación
        │
 ┌──────▼──────┐   falta un dato crítico
 │ 1. DATOS    │ ─────────────────────────────► REVISIÓN FISCAL NECESARIA (sin número)
 └──────┬──────┘
 ┌──────▼──────┐   regla de bloqueo
 │ 2. LEY      │ ─────────────────────────────► REVISIÓN FISCAL NECESARIA
 │  matriz     │   tratamiento: tipo de operación, calificación, tipo IVA, textos,
 └──────┬──────┘   declaraciones, documentos, cobertura que exige
 ┌──────▼──────┐   ninguna identificación operativa la cubre
 │ 3. HABILI-  │ ─────────────────────────────► NO HABILITADA + tratamiento completo
 │    TACIÓN   │                                 + qué identificación la permitiría
 └──────┬──────┘
        ▼
       OK → guardar determinación → numerar → imprimir textos → checklist de documentos
```

La capa 2 nunca mira qué licencia tiene TB. Por eso, cuando se amplíe la licencia de Exonero o TB se registre en NL, no hay que tocar ninguna regla: se cambia una fila de `erp_fiscal_identificacion`.

## 2. Principios

1. **Localización primero.** El lugar de la entrega (arts. 31-32 Directiva 2006/112/CE; art. 68 LIVA) fija la jurisdicción: mercancía en España → ES; en Holanda → NL; fuera de la UE sin despachar → ES. Si el usuario elige otra, bloquea.
2. **Reglas como datos.** La matriz vive en `erp_fiscal_regla`; el motor solo evalúa.
3. **Primera coincidencia por prioridad.** Bloqueos (< 100) antes que tratamientos. Dos reglas con la misma prioridad = ambigüedad = revisión.
4. **Registro inmutable.** Cada determinación guarda la entrada completa, la regla y su versión, la identificación usada y el resultado.
5. **Nada se asume.** Umbral de ventas a distancia, ROI, OSS, diferimiento, licencia art. 23, garantía y coberturas son parámetros.

## 3. Hechos de entrada

| Factor | Campo | Crítico |
|---|---|---|
| Evento | `evento`: VENTA · TRANSFERENCIA · COMPRA · IMPORTACION | sí |
| Fecha de devengo | `fecha_devengo` | sí |
| Dónde está la mercancía | `mercancia.ubicacion` + `mercancia.estado_aduanero` (LIBRE_PRACTICA · DEPOSITO_ADUANERO · NO_DESPACHADA · EN_ORIGEN) | sí |
| Cómo entró en NL | `mercancia.entrada_nl`: IMPORTACION · COMPRA_LOCAL · ADQUISICION_UE | sí en ventas y traslados desde NL |
| Destino / llegada | `destino` | sí en ventas, traslados y compras en la UE |
| Cliente | `cliente.tipo` (B2B_VAT · B2B_SIN_VAT · B2C), `pais_establecimiento`, `vat`, `vies`, `recargo_equivalencia`, `establecimiento_permanente_nl` | sí en ventas |
| Proveedor | `proveedor.pais_establecimiento`, `vat` | sí en compras |
| Transporte | `transporte.incoterm`, `transporte.por` (si falta, lo deduce el Incoterm) | sí si hay movimiento |
| Aduana | `aduana.importador`, `aduana.exportador`, `aduana.regimen_importacion` (40 · 42 · DEPOSITO) | según operación |
| Especiales | `especiales.triangular`, `consigna`, `operacion_en_cadena` | — |
| Autorización | `override {forzar_iva_origen, usuario, motivo}` | — |
| Simulación | `simular_identificacion` (p. ej. NL_DIRECTA) | — |

Flujo derivado: INTERIOR · INTRA_UE (incluida Irlanda del Norte, NIF XI) · EXTRA_UE (terceros, Canarias, Ceuta, Melilla, territorios excluidos) · FUERA_UE (sin despachar o en origen) · DEPOSITO · IMPORTACION.

## 4. Clasificación

**Tipo de operación:** ENTREGA_INTERIOR · ENTREGA_INTERIOR_ISP · ENTREGA_INTRACOMUNITARIA · VENTA_DISTANCIA_UE · EXPORTACION · VENTA_EN_DEPOSITO · VENTA_NO_SUJETA_LOCALIZACION · OPERACION_TRIANGULAR · TRANSFERENCIA_STOCK · TRANSFERENCIA_CONSIGNA · COMPRA_INTERIOR · COMPRA_INTERIOR_ISP · COMPRA_NO_SUJETA · COMPRA_EN_DEPOSITO · ADQUISICION_INTRACOMUNITARIA · IMPORTACION · IMPORTACION_EXENTA · ENTRADA_DEPOSITO.

**Calificación:**

| Código | Qué significa | UNTDID 5305 | Ejemplo TB |
|---|---|---|---|
| SUJETA | IVA repercutido o soportado | S | ES→ES 4% · NL→NL particular 9% |
| SUJETA_TIPO_CERO | Sujeta con tipo vigente 0% (automática) | S | ES→ES en 2023-sept. 2024 |
| TIPO_CERO | 0% neerlandés (intracomunitaria, exportación, depósito) | K / G / Z | NL→ES, NL→UK |
| EXENTA_PLENA | Exenta con derecho a deducción | K / G / E | ES→UE (art. 25), ES→UK (art. 21) |
| NO_SUJETA | Fuera del IVA por localización | O | venta o compra a flote |
| INVERSION_SUJETO_PASIVO | El IVA lo declara el destinatario | AE | NL→NL empresa (verlegd), compra ES a no establecido |
| SUSPENSION_ADUANERA | IVA suspendido | O | entrada en depósito |

Cuando el IVA lo autoliquida TB (inversión en compras, adquisición intracomunitaria, importación con art. 23 o diferida), la cuota va en `cuota_autoliquidada` y no se suma al total.

## 5. Matriz

### Ventas desde España

| Escenario | Regla | Tratamiento | 5305 | IVA |
|---|---|---|---|---|
| ES → ES | ES-INT | Interior sujeta | S | 4% |
| ES → ES, minorista en recargo | ES-INT-RE | Sujeta + recargo | S | 4% + 0,5% |
| ES → UE empresa, transporta TB | ES-ICS-V | Intracomunitaria exenta | K | 0 |
| ES → UE empresa, recoge (EXW) | ES-ICS-C | Ídem + declaración del adquirente | K | 0 |
| ES → UE empresa sin NIF-IVA válido | B-SIN-VAT / B-VIES / B-VAT-MS | Revisión; o OVR-ES (4%) con autorización de GERENCIA | — | — |
| ES → UE particular, transporta TB | ES-DIST-BAJO / ES-DIST | 4% ES bajo umbral; IVA de destino vía OSS por encima | S | 4% / destino |
| ES → UE particular que recoge | ES-B2C-RECOGE | Interior sujeta | S | 4% |
| ES → Irlanda del Norte | ES-ICS-V/C | Intracomunitaria | K | 0 |
| ES → Reino Unido, Marruecos, terceros | ES-EXP-V / ES-EXP-C | Exportación exenta | G | 0 |
| Ídem, recoge un comprador establecido en España | ES-EXP-C-TAI | Interior sujeta | S | 4% |
| Fuera UE en DDP | B-DDP | Revisión | — | — |
| ES → Canarias / Ceuta / Melilla | ES-EXP-CN / ES-EXP-CEML | Exportación a territorio tercero | G | 0 |
| Venta en depósito aduanero ES | ES-DEP | Exenta art. 24 | E | 0 |
| Venta a flote, importa el cliente | ES-NS-TRANSITO | No sujeta | O | 0 |
| Venta a flote, importa TB | B-TRANSITO-TB-IMPORTA | Revisión | — | — |
| Triangular (TB intermediario con NIF ES) | ES-TRI | ISP del destinatario | AE | 0 |

### Ventas desde Holanda (mercancía en Cool Control u otro almacén NL)

| Escenario | Regla | Tratamiento | 5305 | IVA | Cobertura que exige |
|---|---|---|---|---|---|
| NL → NL empresa establecida en NL | NL-INT-B2B | Btw verlegd | AE | 0 | NL_B2B_VERLEGD |
| NL → NL particular o sin NIF-IVA | NL-INT-SUJETA | Sujeta | S | 9% | NL_VENTA_SUJETA |
| NL → NL empresa no establecida en NL | NL-INT-NOEST | Sujeta (no procede verlegd) | S | 9% | NL_VENTA_SUJETA |
| NL → ES / UE empresa, transporta TB | NL-ICS-V | Intracomunitaria 0% | K | 0 | NL_ICS |
| NL → ES / UE empresa, EXW Cool Control | NL-ICS-C | Ídem + CMR y declaración del comprador | K | 0 | NL_ICS |
| Importación régimen 42 y entrega a otro EM | NL-ICS-42 | Intracomunitaria 0% | K | 0 | IMPORT_42 |
| NL → UE particular, transporta TB | NL-DIST | IVA de destino vía OSS española, factura con NIF ES | S | destino | OSS (ES) |
| NL → UE particular que recoge | NL-B2C-RECOGE | Sujeta | S | 9% | NL_VENTA_SUJETA |
| NL → Reino Unido, Marruecos, terceros | NL-EXP-V / NL-EXP-C | Exportación 0% | G | 0 | NL_EXPORT |
| Venta en depósito aduanero NL | NL-DEP | 0% Tabel II a.1 | Z | 0 | NL_DEPOSITO |

### Compras (facturas recibidas)

| Escenario | Regla | Tratamiento | IVA | Deducción |
|---|---|---|---|---|
| Compra FOB/CFR en origen (Perú, Colombia, México…) | CMP-EXT | No sujeta; el IVA surge al importar | 0 | — |
| Compra en España a proveedor español | CMP-ES-INT | Soportado | 4% | 303 |
| Compra en España a proveedor no establecido | CMP-ES-ISP | Inversión: TB autoliquida | 4% | 303 (neutro) |
| Compra en Holanda (mercancía en NL) | CMP-NL-INT | Soportado, repercute el proveedor | 9% | btw-aangifte si hay identificación NL; si no, coste |
| Compra a proveedor UE con llegada a España | ADQ-ES | Adquisición intracomunitaria | 4% autoliq. | 303 + 349 A |
| Compra a proveedor UE (o español) con llegada a NL | ADQ-NL | Adquisición intracomunitaria | 9% autoliq. | exige NL_ADQ |
| Compra en triangular | CMP-TRI | Adquisición exenta + 349 T | 0 | — |
| Compra en depósito aduanero ES / NL | CMP-DEP-ES / CMP-DEP-NL | Exenta / 0% | 0 | — |

### Importaciones

| Escenario | Regla | Tratamiento | IVA | Cobertura |
|---|---|---|---|---|
| Importación en España | IMP-ES-40 | IVA pagado en aduana | 4% | — |
| Ídem con diferimiento | IMP-ES-40-DIF | Autoliquidado en el 303 | 4% autoliq. | — |
| Importación en España, régimen 42 | IMP-ES-42 | Exenta + 349 M | 0 | — |
| Importación en NL con licencia art. 23 | IMP-NL-40-A23 | Verlegd, sin coste de caja | 9% autoliq. | IMPORT_40_ART23 |
| Importación en NL sin art. 23 | IMP-NL-40 | Pagado en aduana, deducible en NL | 9% | IMPORT_40_ADUANA |
| Importación en NL, régimen 42 | IMP-NL-42 | Exenta | 0 | IMPORT_42 |
| Entrada en depósito ES / NL | IMP-DEP-ES / IMP-DEP-NL | Suspensión | — | — |

### Transferencias de stock propio

| Escenario | Regla | Tratamiento | Exige |
|---|---|---|---|
| ES → NL (u otro EM) | ES-TRANSF | Asimilada a intracomunitaria exenta (349 E) | identificación en destino con NL_ADQ |
| ES → UE en consigna | ES-TRANSF-CONSIGNA | Sin entrega hasta la retirada (349 R) | — |
| NL → ES | NL-TRANSF | 0% en NL + adquisición asimilada en ES (349 A) | NL_TRANSF_SALIDA |
| ES / NL → fuera UE | ES-TRANSF-EXT / NL-TRANSF-EXT | Exportación; TB importadora en destino | registro en destino |

## 6. Identificaciones fiscales y habilitación

`erp_fiscal_identificacion` guarda con qué número opera TB en cada país y qué cubre. Carga inicial:

| Código | Modalidad | Estado | Cubre | NIF-IVA en factura |
|---|---|---|---|---|
| ES_PROPIA | Propia | ACTIVA (ROI confirmado) | todo | ESB02989630 |
| NL_EXONERO_LFV | Representación limitada | EN_TRAMITE | importación art. 23 y 42; intracomunitaria, exportación y verlegd solo de mercancía importada por TB | btw-id asignado por Exonero |
| NL_REP_GENERAL | Representación general | ESCENARIO | todo | NIF NL propio de TB |
| NL_DIRECTA | Registro directo en la Belastingdienst | ESCENARIO | todo (sin art. 23 supuesto) | NIF NL propio de TB |

Selección: la identificación ACTIVA y completa de menor prioridad que cubra la operación. El sufijo `@IMPORT` limita una cobertura a mercancía importada por TB.

**Mapa de habilitación en NL** (vista `erp_fiscal_mapa_habilitacion`, función `TBFiscal.mapaHabilitacion`):

| Operación en NL | Exonero LFV | Repr. general | Registro directo |
|---|---|---|---|
| Importación con art. 23 | sí | sí | sí* |
| Importación pagando IVA en aduana | no | sí | sí |
| Importación régimen 42 | sí | sí | sí |
| Intracomunitaria desde NL | solo importada | sí | sí |
| Exportación desde NL | solo importada | sí | sí |
| Venta a empresa NL (verlegd) | solo importada | sí | sí |
| Venta al 9% (particular, no establecido) | no | sí | sí |
| Venta en depósito aduanero | no | sí | sí |
| Adquisición intracomunitaria / transferencia de entrada | no | sí | sí |
| Transferencia de salida | no | sí | sí |
| Deducción de btw soportado en compras NL | no | sí | sí |

\* La matriz supone que el registro directo no lleva licencia art. 23 (a verificar con la Belastingdienst); en ese caso el 9% se paga en aduana y se recupera en la declaración.

Para activar Exonero: rellenar representante (dirección, NIF-IVA, garantía) e identificación (btw-id, subnúmero) y pasarla a ACTIVA. No se toca ninguna regla.

## 7. Reglas IF/THEN (orden de evaluación)

```
0. SI falta un dato crítico (apartado 8)                          → REVISIÓN
1. flujo = derivar(evento, ubicación, estado aduanero, destino)
   jurisdicción = FUERA_UE → ES | compra intracomunitaria → EM de llegada | triangular → ES
                | EM de la ubicación ∈ {ES, NL} → ese | otro → REVISIÓN
   SI jurisdicción solicitada ≠ jurisdicción                        → REVISIÓN
2. hechos = operación + ROI/OSS/diferimiento de ES_PROPIA (+ art. 23 de la identificación NL candidata)
3. PARA cada identificación operativa de la jurisdicción (por prioridad) y, al final, «ninguna»:
     regla = primera coincidencia vigente
     SI regla de bloqueo                                            → REVISIÓN
     SI regla de habilitación (OSS)                                 → NO HABILITADA
     SI la regla exige cobertura y la identificación la tiene
        y, si hay adquisición en destino, TB está identificada allí  → OK con esa identificación
     SI la cobertura no bloquea (compras)                           → OK, deducción «sin identificación»
4. Ninguna sirve → evaluar escenarios (EN_TRAMITE, ESCENARIO)
     → NO HABILITADA + tratamiento completo + habilitarían [identificaciones]
5. tipo = erp_fiscal_tipo_iva(país, categoría, fecha); SUJETA con 0% → SUJETA_TIPO_CERO
6. importes: base, cuota (o autoliquidada), recargo, total
7. textos legales en el idioma pedido (+ mención del representante si interviene)
```

Bloqueos principales: cadena sin triangulación · DDP fuera de la UE · venta a flote con TB importadora · intracomunitaria con cliente sin NIF-IVA, VIES no válido o caducado, o NIF del mismo EM de salida · ROI no vigente · verlegd sin VIES.

## 8. REVISIÓN frente a NO HABILITADA

**REVISIÓN FISCAL NECESARIA** = el problema está en la operación. Faltan o son incoherentes: fecha · ubicación o estado aduanero · entrada en NL · destino · territorio no parametrizado · categoría de IVA · tipo, país o NIF-IVA del cliente · país del proveedor · Incoterm o transporte · importador o exportador · régimen de importación · jurisdicción elegida · tipo de IVA vigente · texto legal · regla aplicable o ambigua · autorización sin usuario o motivo.

**NO HABILITADA** = la operación está bien definida y el tratamiento está calculado, pero TB no tiene la identificación que exige. El mensaje dice por qué y qué la habilitaría, por ejemplo:

`NL_EXONERO_LFV no cubre: Entrega intracomunitaria desde NL (solo la cubre para mercancía importada por TB). Habilitarían: NL_REP_GENERAL, NL_DIRECTA.`

Ninguno de los dos estados consume número.

## 9. Módulo Fiscal Representative NL

Vista `erp_fiscal_rep_nl_v` = `erp_fiscal_representante` + la identificación con la que opera TB.

| Campo | Dónde |
|---|---|
| Nombre, dirección, contacto | representante |
| VAT number del representante | representante `vat_number` |
| Btw-id que sale en la factura / subnúmero | identificación `vat` / `numero_representacion` |
| Tipo de representación | representante `tipo_representacion`; identificación `modalidad` |
| Operaciones e importaciones cubiertas | identificación `coberturas`, `licencia_art23`, `licencia_art23_ref` |
| Declaraciones que presenta | representante `declaraciones` |
| Documentación requerida | representante `documentacion_requerida` |
| Garantías | representante `garantia_*` |
| Vigencia | ambos |

En toda factura emitida con representante se imprime su nombre, dirección y NIF-IVA (art. 226.15 Directiva).

## 10. Salida por factura

Estado · regla y versión · país de origen · ubicación y estado aduanero · destino · jurisdicción · identificación usada · cobertura exigida · habilitarían · motivos · VAT vendedor y comprador · VIES · tipo de cliente · Incoterm · transporte · importador · exportador · tipo de operación · calificación · 5305 · % IVA · % recargo · base · IVA · recargo · cuota autoliquidada · total · vía de deducción · textos legales · declaraciones · documentos a archivar · requiere VIES / 349-ICP / aduana / MRN y prueba de salida · interviene representante · avisos · autorización.

## 11. Modelo de datos

| Tabla / vista | Contenido |
|---|---|
| `erp_fiscal_territorio` | 68 territorios con EM de IVA, zona y unión aduanera |
| `erp_fiscal_tipo_iva` | Tipos con vigencia: ES 4% fruta (y 0%/2% de 2023-2024), RE 0,5%, NL 9%, generales |
| `erp_fiscal_texto_legal` | Textos es/en/nl, PROPUESTO/VALIDADO |
| `erp_fiscal_documento_req` | 19 documentos de prueba |
| `erp_fiscal_declaracion` | 303, 390, SII, 349 por clave, 369, 360, Intrastat, DUA, btw-aangifte, ICP, douane |
| `erp_fiscal_incoterm` | Incoterms 2020 |
| `erp_fiscal_cobertura` | 11 operaciones habilitables en NL |
| `erp_fiscal_config` | versión, antigüedad VIES, umbral distancia, bloqueo por textos |
| `erp_fiscal_representante` | Exonero |
| `erp_fiscal_identificacion` | ES_PROPIA, NL_EXONERO_LFV, NL_REP_GENERAL, NL_DIRECTA |
| `erp_fiscal_regla` | 60 reglas |
| `erp_fiscal_determinacion` | Resultado por documento, inmutable |
| `erp_fiscal_vies_consulta` | Consultas VIES con nº de consulta |
| `erp_fiscal_rep_nl_v`, `erp_fiscal_mapa_habilitacion` | Vistas del módulo NL y del mapa |

Enlace: `erp_documento.fiscal_determinacion_id` y `erp_fiscal_determinacion.documento_id` (con el tipo real de `erp_documento.id`).

## 12. Integración en la facturación actual

1. Ejecutar la migración en una rama de Supabase y después en producción.
2. Completar `ES_PROPIA`: `roi_desde`, `sii`, `oss_alta`, `redeme`, `diferimiento_iva_importacion`.
3. Desplegar `vies-check`; la pantalla lo llama al elegir cliente y al emitir.
4. Al emitir una factura o registrar una compra, importación o traslado: construir `hechos` (ubicación = país del almacén; estado aduanero y `entrada_nl` = del lote) → `TBFiscal.determinar`.
   - OK: guardar `aSnapshot`, numerar, imprimir textos, crear checklist.
   - REVISIÓN: banner con la lista de datos.
   - NO HABILITADA: banner con el tratamiento calculado y la identificación que falta.
5. El cliente aporta tipo, país, NIF-IVA, recargo y establecimiento permanente en NL; el régimen deja de ser un atributo suyo.
6. El lote guarda `estado_aduanero` y `entrada_nl`: Cool Control tiene a la vez mercancía en depósito y en libre práctica, importada y comprada.
7. Pantalla de simulación: el mismo formulario con `simular_identificacion` para ver qué pasaría con cada escenario.

Fuera de alcance: líneas de servicio (fletes, comisiones), que conservan su régimen, y VeriFactu.

## 13. Cuando cambie la ley o el registro

- Tipo de IVA: cerrar la fila vigente y crear la nueva. Ejemplo: si NL aprueba el 0% para fruta fresca desde 2027, basta una fila.
- Regla: versión nueva con su vigencia; las facturas antiguas conservan la suya.
- Texto legal: fila nueva y VALIDADO cuando lo firme el asesor.
- Registro de TB: cambiar `estado`, `vat` y `coberturas` de la identificación. Ninguna regla cambia.

## 14. Qué pedir a Exonero

1. Btw-id que figurará en las facturas de TB y subnúmero de omzetbelasting de la licencia limitada.
2. Dirección y NIF-IVA propio de Exonero.
3. Garantía: tipo, importe, entidad y vencimiento.
4. Referencia de la licencia art. 23.
5. Confirmación por escrito, operación por operación: intracomunitaria, exportación y venta verlegd de mercancía **no** importada por TB (comprada en NL o llegada de España); venta al 9%; venta en depósito; transferencias; adquisiciones; deducción del btw de compras en NL.
6. Documentación que exige por operación y plazos (CMR, declaración del comprador, MRN de salida).
7. Coste y garantía de pasar a representación general, para compararlo con el registro directo.

## 15. Pendiente de validar

1. **Fecha de alta en ROI** (`roi_desde`). Hoy el ROI se da por vigente en cualquier fecha.
2. **OSS**: sin alta, las ventas a particulares de otros países con IVA de destino quedan NO HABILITADAS. Solo relevante si se vende B2C.
3. **Criterios marcados para el asesor**: umbral de 10.000 € en expediciones desde NL (se aplica IVA de destino); 9% a compradores no establecidos en NL; ausencia de art. 23 en el registro directo.
4. **Textos legales y reglas**: todos en PROPUESTO.
5. **EXW Cool Control**: el 0% depende del CMR firmado y la declaración del comprador.
6. **Casillas del 303**: se consultan en el diseño vigente; no están en el código.
