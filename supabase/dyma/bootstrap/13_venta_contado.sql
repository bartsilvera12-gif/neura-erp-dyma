-- =============================================================================
-- DYMA ERP — Venta de lote al contado
-- =============================================================================
-- Ejecutar DESPUÉS de 12_dashboard_lotes.sql.
--
-- Hasta ahora un lote solo se podía vender financiado. Una venta al contado se
-- modela como el MISMO contrato, con una sola cuota que vence el día de la venta
-- y sin recargo: así entra al mismo circuito de factura, cobranza, comisión y
-- documento, en vez de abrir un camino paralelo que después no cuadre.
--
-- La columna `modalidad` deja constancia explícita de cuál fue. Se podría
-- inferir (una cuota, interés cero), pero eso es frágil: un plan financiado de
-- una sola cuota sin recargo se vería igual.
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.lote_ventas
  ADD COLUMN IF NOT EXISTS modalidad text DEFAULT 'financiada'::text NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_modalidad_check'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_modalidad_check
      CHECK (modalidad = ANY (ARRAY['financiada'::text, 'contado'::text]));
    -- Al contado no se financia nada: no hay recargo ni plan de cuotas.
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_contado_check
      CHECK (modalidad <> 'contado' OR (cantidad_cuotas = 1 AND interes_total = 0 AND entrega_inicial = 0));
  END IF;
END $$;

COMMENT ON COLUMN dymaerp.lote_ventas.modalidad IS
  'contado = pago único el día de la venta (una cuota, sin recargo); financiada = plan de cuotas.';

CREATE INDEX IF NOT EXISTS ix_lote_ventas_modalidad
  ON dymaerp.lote_ventas USING btree (empresa_id, modalidad, fecha_venta DESC);

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'dymaerp' AND table_name = 'lote_ventas' AND column_name = 'modalidad';
