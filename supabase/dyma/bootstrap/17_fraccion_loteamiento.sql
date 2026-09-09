-- =============================================================================
-- DYMA ERP — La fracción registral del loteamiento
-- =============================================================================
-- Ejecutar DESPUÉS de 11_contratos.sql.
--
-- El contrato describe el inmueble como "Fracción X, Manzana Y, Lote Z". Esa
-- fracción es un dato registral del loteamiento, escrito una sola vez en el
-- título, y no la subdivisión operativa de `loteamiento_fracciones`, que existe
-- para agrupar manzanas cuando el emprendimiento es grande.
--
-- Confundirlas hacía que el contrato imprimiera el código interno de la
-- subdivisión —"ÚNICA", "A"— donde tiene que ir lo que dice la finca matriz.
--
-- El resto de los datos registrales (finca matriz, matrícula, cuenta corriente
-- catastral, padrón, departamento, distrito, resolución municipal y RUN) ya
-- existen desde el script 11: este agrega solo el que faltaba.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS fraccion text;

COMMENT ON COLUMN dymaerp.loteamientos.fraccion IS
  'Fracción registral como figura en el título, para el contrato. No confundir con loteamiento_fracciones, que es la subdivisión operativa que agrupa manzanas.';

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve la columna nueva.
NOTIFY pgrst, 'reload schema';

-- Verificación: los datos registrales del loteamiento, todos juntos.
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'dymaerp'
  AND table_name = 'loteamientos'
  AND column_name IN (
    'fraccion', 'finca_matriz', 'matricula', 'cuenta_corriente_catastral',
    'padron', 'departamento', 'distrito', 'resolucion_municipal', 'run_expediente'
  )
ORDER BY column_name;
