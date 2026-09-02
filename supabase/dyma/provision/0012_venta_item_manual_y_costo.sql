-- =============================================================================
-- DYMA — ítem manual (servicio escrito a mano) + costo por línea
-- =============================================================================
-- Pedido del negocio: poder facturar un trabajo como UNA sola línea escrita a
-- mano ("Mantenimiento de compresor: cambio de pistones, aceite y válvulas")
-- sin tener que cargar repuesto por repuesto, y registrar a mano cuánto costó
-- ese trabajo para conocer la ganancia.
--
-- Cambios:
--   ventas_items.producto_id   → pasa a NULL-able (la línea manual no apunta a
--                                ningún producto del catálogo).
--   ventas_items.sku           → pasa a NULL-able por el mismo motivo.
--   ventas_items.es_manual     → marca la línea escrita a mano.
--   ventas_items.costo_unitario→ costo cargado a mano (repuestos + mano de obra).
--                                Para líneas normales queda NULL: el costo real
--                                sigue saliendo de movimientos_inventario.
--   presupuesto_items.costo_unitario → lo mismo, para ver el margen antes de
--                                cerrar el trabajo.
--
-- Idempotente. Requiere supabase_admin (las tablas son de ese rol).
-- =============================================================================

ALTER TABLE dymaerp.ventas_items
  ALTER COLUMN producto_id DROP NOT NULL;

ALTER TABLE dymaerp.ventas_items
  ALTER COLUMN sku DROP NOT NULL;

ALTER TABLE dymaerp.ventas_items
  ADD COLUMN IF NOT EXISTS es_manual      boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS costo_unitario numeric NULL;

ALTER TABLE dymaerp.presupuesto_items
  ADD COLUMN IF NOT EXISTS costo_unitario numeric NULL;

-- Coherencia: una línea manual no referencia producto, y una línea de catálogo sí.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint co
    JOIN pg_class cl ON cl.oid = co.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    WHERE n.nspname = 'dymaerp' AND cl.relname = 'ventas_items'
      AND co.conname = 'ventas_items_manual_sin_producto_check'
  ) THEN
    ALTER TABLE dymaerp.ventas_items
      ADD CONSTRAINT ventas_items_manual_sin_producto_check
      CHECK (
        (es_manual = true  AND producto_id IS NULL)
        OR
        (es_manual = false AND producto_id IS NOT NULL)
      );
  END IF;
END $$;

COMMENT ON COLUMN dymaerp.ventas_items.es_manual IS
  'Línea escrita a mano (servicio/trabajo): no sale del catálogo, no descuenta stock.';
COMMENT ON COLUMN dymaerp.ventas_items.costo_unitario IS
  'Costo cargado a mano por unidad (repuestos + mano de obra). NULL en líneas de catálogo: ahí el costo sale de movimientos_inventario.';
COMMENT ON COLUMN dymaerp.presupuesto_items.costo_unitario IS
  'Costo estimado por unidad, para ver el margen del presupuesto antes de cerrar el trabajo.';
