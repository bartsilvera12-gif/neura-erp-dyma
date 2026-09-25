-- =============================================================================
-- DYMA ERP — Entrega inicial cobrable
-- =============================================================================
-- Ejecutar DESPUÉS de 23_plan_personalizado_sin_cancelacion.sql.
--
-- La entrega inicial deja de ser solo un número informativo: se registra como
-- una "cuota" especial del contrato (numero 0, marcada con `es_entrega`) que
-- vence el día de la venta y se puede cobrar por el mismo circuito que las
-- cuotas (factura + pago). Así suma al "Cobrado" del contrato.
--
-- NO cambia la aritmética del contrato: `entrega_inicial`, `capital` y
-- `monto_financiado` de `lote_ventas` quedan igual (la cuota de entrega es
-- aparte del plan financiado). Cumple `lote_venta_cuotas_montos_check` con
-- capital = entrega, interes = 0, total = entrega.
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.lote_venta_cuotas
  ADD COLUMN IF NOT EXISTS es_entrega boolean DEFAULT false NOT NULL;

COMMENT ON COLUMN dymaerp.lote_venta_cuotas.es_entrega IS
  'true = fila de la entrega inicial (numero 0), cobrable como una cuota pero fuera del plan financiado; no genera mora.';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'dymaerp' AND table_name = 'lote_venta_cuotas' AND column_name = 'es_entrega';
