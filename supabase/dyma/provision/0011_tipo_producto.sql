-- =============================================================================
-- DYMA — tipo de producto (reventa / repuesto / servicio)
-- =============================================================================
-- El negocio distingue tres cosas distintas en el catálogo:
--   reventa   → mercadería que se compra y se revende (compresores, motores…)
--   repuesto  → piezas que se consumen en una reparación; descuentan stock
--               pero NO se detallan en la factura del servicio
--   servicio  → mano de obra / instalación; no tiene stock propio
--
-- Idempotente. Requiere supabase_admin (la tabla es de ese rol).
-- =============================================================================

ALTER TABLE dymaerp.productos
  ADD COLUMN IF NOT EXISTS tipo_producto text NOT NULL DEFAULT 'reventa';

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint co
    JOIN pg_class cl ON cl.oid = co.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    WHERE n.nspname = 'dymaerp' AND cl.relname = 'productos'
      AND co.conname = 'productos_tipo_producto_check'
  ) THEN
    ALTER TABLE dymaerp.productos
      ADD CONSTRAINT productos_tipo_producto_check
      CHECK (tipo_producto IN ('reventa', 'repuesto', 'servicio'));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_productos_tipo_producto
  ON dymaerp.productos (empresa_id, tipo_producto);
