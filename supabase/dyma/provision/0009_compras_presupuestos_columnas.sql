-- =============================================================================
-- DYMA — columnas para Órdenes de compra y Presupuestos
-- =============================================================================
-- Alinea el schema con ferreteriarepublica para los módulos portados.
-- Idempotente (ADD COLUMN IF NOT EXISTS).
-- =============================================================================

ALTER TABLE dymaerp.ordenes_compra
  ADD COLUMN IF NOT EXISTS nro_timbrado             text,
  ADD COLUMN IF NOT EXISTS numero_factura           text,
  ADD COLUMN IF NOT EXISTS comprobante_url          text,
  ADD COLUMN IF NOT EXISTS comprobante_storage_path text,
  ADD COLUMN IF NOT EXISTS comprobante_nombre       text,
  ADD COLUMN IF NOT EXISTS comprobante_mime_type    text;

ALTER TABLE dymaerp.presupuestos
  ADD COLUMN IF NOT EXISTS condicion text NOT NULL DEFAULT 'contado';
