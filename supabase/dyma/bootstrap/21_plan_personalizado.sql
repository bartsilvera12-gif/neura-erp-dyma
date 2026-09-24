-- =============================================================================
-- DYMA ERP — Plan de cuotas personalizado
-- =============================================================================
-- Ejecutar DESPUÉS de 20_cliente_conyuge.sql.
--
-- Hasta ahora un contrato financiado se armaba solo por amortización francesa
-- (cuota fija, recargo anual). El cliente pidió además un plan PERSONALIZADO:
-- el vendedor define a mano cada cuota (fecha y monto, sin interés) y una cuota
-- final de "cancelación" cuya fecha se indica a mano pero cuyo importe lo calcula
-- el sistema con el saldo restante.
--
-- Ambos planes son la MISMA modalidad 'financiada' (plan de cuotas). Lo que
-- cambia es cómo se armaron las cuotas, y eso lo deja constancia `plan_tipo`.
-- Con `plan_tipo = 'personalizada'`, el contrato marca la última cuota como
-- "Cancelación de saldo".
--
-- No cambia la aritmética existente: un plan personalizado tiene interés 0, así
-- que sigue cumpliendo `monto_financiado = capital + interes_total` y
-- `capital = precio_contado - entrega_inicial`.
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.lote_ventas
  ADD COLUMN IF NOT EXISTS plan_tipo text DEFAULT 'automatica'::text NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_plan_tipo_check'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_plan_tipo_check
      CHECK (plan_tipo = ANY (ARRAY['automatica'::text, 'personalizada'::text]));
  END IF;
END $$;

COMMENT ON COLUMN dymaerp.lote_ventas.plan_tipo IS
  'automatica = cuotas por amortización francesa (recargo); personalizada = cuotas cargadas a mano (sin interés) con cuota final de cancelación.';

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve la columna nueva.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_schema = 'dymaerp' AND table_name = 'lote_ventas' AND column_name = 'plan_tipo';
