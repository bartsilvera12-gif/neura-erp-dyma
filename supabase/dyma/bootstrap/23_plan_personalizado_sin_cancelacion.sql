-- =============================================================================
-- DYMA ERP — Plan personalizado: cuota de cancelación opcional
-- =============================================================================
-- Ejecutar DESPUÉS de 22_plan_personalizado_simulacion.sql.
--
-- El plan personalizado ya no obliga a tener una "cuota final de cancelación".
-- El vendedor puede definir todas las cuotas a mano (que sumen el financiado) o,
-- si quiere, dejar una cuota final que se lleve el saldo restante. Por eso la
-- simulación personalizada ya no exige `cancelacion_vencimiento`: basta con que
-- traiga sus cuotas cargadas (`cuotas_manuales`).
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- Reemplaza el CHECK anterior (que exigía cancelacion_vencimiento) por uno que
-- solo pide las cuotas cargadas cuando el plan es personalizado.
ALTER TABLE dymaerp.plan_simulaciones
  DROP CONSTRAINT IF EXISTS plan_simulaciones_personalizada_check;

ALTER TABLE dymaerp.plan_simulaciones
  ADD CONSTRAINT plan_simulaciones_personalizada_check
  CHECK (plan_tipo <> 'personalizada' OR cuotas_manuales IS NOT NULL);

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT conname, pg_get_constraintdef(oid) AS definicion
FROM pg_constraint
WHERE conname = 'plan_simulaciones_personalizada_check'
  AND conrelid = 'dymaerp.plan_simulaciones'::regclass;
