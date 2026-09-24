-- =============================================================================
-- DYMA ERP — Plan personalizado en el simulador
-- =============================================================================
-- Ejecutar DESPUÉS de 21_plan_personalizado.sql.
--
-- El simulador ya guardaba propuestas de plan automático (amortización francesa),
-- regenerando las cuotas del motor al reabrir. Un plan personalizado no se puede
-- regenerar de una fórmula: sus cuotas SON el dato. Por eso, además de marcar el
-- tipo de plan, la simulación personalizada guarda las cuotas cargadas a mano.
--
--   plan_tipo               → 'automatica' (default) | 'personalizada'
--   cuotas_manuales         → jsonb [{ "vencimiento": "YYYY-MM-DD", "monto": n }]
--   cancelacion_vencimiento → fecha de la cuota final de cancelación
--
-- No cambia la aritmética existente: un plan personalizado tiene interés 0, así
-- que sigue cumpliendo los CHECK de montos y de coherencia de la tabla.
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.plan_simulaciones
  ADD COLUMN IF NOT EXISTS plan_tipo text DEFAULT 'automatica'::text NOT NULL,
  ADD COLUMN IF NOT EXISTS cuotas_manuales jsonb,
  ADD COLUMN IF NOT EXISTS cancelacion_vencimiento date;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'plan_simulaciones_plan_tipo_check'
      AND conrelid = 'dymaerp.plan_simulaciones'::regclass
  ) THEN
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_plan_tipo_check
      CHECK (plan_tipo = ANY (ARRAY['automatica'::text, 'personalizada'::text]));
    -- Una simulación personalizada tiene que traer sus cuotas cargadas a mano.
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_personalizada_check
      CHECK (plan_tipo <> 'personalizada'
             OR (cuotas_manuales IS NOT NULL AND cancelacion_vencimiento IS NOT NULL));
  END IF;
END $$;

COMMENT ON COLUMN dymaerp.plan_simulaciones.plan_tipo IS
  'automatica = cuotas por amortización francesa; personalizada = cuotas cargadas a mano (guardadas en cuotas_manuales).';
COMMENT ON COLUMN dymaerp.plan_simulaciones.cuotas_manuales IS
  'Solo plan personalizado: cuotas cargadas a mano [{vencimiento, monto}], sin la cuota de cancelación (esa se deriva del saldo).';

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve las columnas nuevas.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dymaerp' AND table_name = 'plan_simulaciones'
  AND column_name IN ('plan_tipo', 'cuotas_manuales', 'cancelacion_vencimiento')
ORDER BY column_name;
