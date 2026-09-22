-- =============================================================================
-- DYMA — activar autoimpresor con autorización DNIT vigente
-- FORM.350-1 N° 350010038781 — fecha 21/09/2026
-- Timbrado 19139705 — vigencia 22/09/2026 a 30/09/2027
-- Establecimiento 003 — Punto de expedición 002 — rango 1..5000
--
-- No modifica facturas ya emitidas: factura_timbrado conserva el timbrado y
-- número congelados de cada emisión anterior.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.empresa_autoimpresor_config
  ADD COLUMN IF NOT EXISTS actividad_economica text;

INSERT INTO dymaerp.empresa_autoimpresor_config (
  empresa_id, activo,
  ruc_emisor, razon_social_emisor, nombre_fantasia, actividad_economica,
  direccion_matriz, telefono,
  timbrado_numero, timbrado_inicio_vigencia, timbrado_fin_vigencia,
  establecimiento_codigo, punto_expedicion_codigo,
  numero_inicial, numero_final, numero_actual,
  tipo_documento_default, formato_impresion_default,
  observaciones
)
VALUES (
  '06255def-3835-4d37-8f7f-801af8043e8c', true,
  '80149103-7', 'CORPORACION DYMA S.A.', 'DYMA INMOBILIARIA',
  E'INVERSORES DE EMPRENDIMIENTOS INMOBILIARIOS\nACTIVIDADES INMOBILIARIAS REALIZADAS CON BIENES PROPIOS O ARRENDADOS',
  E'AV. LA RESIDENTA A UNA CUADRA Y MEDIA DE LA COMISARIA\nJUAN E. O''LEARY - ALTO PARANÁ - PARAGUAY',
  '0976 606960',
  '19139705', DATE '2026-09-22', DATE '2027-09-30',
  '003', '002',
  1, 5000, 1,
  'factura', 'pdf_a4',
  'Autoimpresor autorizado por DNIT — FORM.350-1 N° 350010038781, fecha 21/09/2026. Rango autorizado 003-002-0000001 a 003-002-0005000.'
)
ON CONFLICT (empresa_id) DO UPDATE SET
  activo = EXCLUDED.activo,
  ruc_emisor = EXCLUDED.ruc_emisor,
  razon_social_emisor = EXCLUDED.razon_social_emisor,
  nombre_fantasia = EXCLUDED.nombre_fantasia,
  actividad_economica = EXCLUDED.actividad_economica,
  direccion_matriz = EXCLUDED.direccion_matriz,
  telefono = EXCLUDED.telefono,
  timbrado_numero = EXCLUDED.timbrado_numero,
  timbrado_inicio_vigencia = EXCLUDED.timbrado_inicio_vigencia,
  timbrado_fin_vigencia = EXCLUDED.timbrado_fin_vigencia,
  establecimiento_codigo = EXCLUDED.establecimiento_codigo,
  punto_expedicion_codigo = EXCLUDED.punto_expedicion_codigo,
  numero_inicial = EXCLUDED.numero_inicial,
  numero_final = EXCLUDED.numero_final,
  numero_actual = EXCLUDED.numero_actual,
  tipo_documento_default = EXCLUDED.tipo_documento_default,
  formato_impresion_default = EXCLUDED.formato_impresion_default,
  observaciones = EXCLUDED.observaciones,
  updated_at = now();

INSERT INTO dymaerp.empresa_facturacion_modo (
  empresa_id, modo, impresion_tipo_default, imprimir_al_confirmar,
  preguntar_datos_al_confirmar, activo
)
VALUES (
  '06255def-3835-4d37-8f7f-801af8043e8c',
  'autoimpresor', 'pdf_a4', false, false, true
)
ON CONFLICT (empresa_id) DO UPDATE SET
  modo = EXCLUDED.modo,
  impresion_tipo_default = EXCLUDED.impresion_tipo_default,
  activo = true,
  updated_at = now();

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación rápida post-migración.
SELECT
  timbrado_numero,
  timbrado_inicio_vigencia,
  timbrado_fin_vigencia,
  establecimiento_codigo,
  punto_expedicion_codigo,
  numero_inicial,
  numero_final,
  formato_impresion_default
FROM dymaerp.empresa_autoimpresor_config
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c';
