-- =============================================================================
-- DYMA ERP — Datos registrales propios de cada lote
-- =============================================================================
-- Ejecutar DESPUÉS de 17_fraccion_loteamiento.sql.
--
-- Hasta ahora todos los datos registrales vivían en el loteamiento y el contrato
-- los reusaba para cualquier lote. Pero cada lote tiene los suyos: en un mismo
-- loteamiento los padrones y matrículas cambian de lote a lote (CURUPAYTY:
-- padrones 6641, 6642, 6643…, cada uno con su matrícula), como figura en la
-- planilla de Registros Públicos.
--
-- Este script agrega al LOTE los datos registrales que varían entre lotes:
--   - padron
--   - matricula                 (N.º Finca / Matrícula / CUICR del lote)
--   - cuenta_corriente_catastral
--
-- Los datos comunes del emprendimiento (fracción, finca matriz, departamento,
-- distrito, resolución municipal, RUN/expediente) siguen en el loteamiento.
--
-- Al armar el contrato, el sistema combina: datos generales del loteamiento +
-- datos registrales del lote. Si el lote no tiene el suyo cargado, se cae al del
-- loteamiento (retrocompatible: los loteamientos ya cargados siguen funcionando).
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.lotes ADD COLUMN IF NOT EXISTS padron text;
ALTER TABLE dymaerp.lotes ADD COLUMN IF NOT EXISTS matricula text;
ALTER TABLE dymaerp.lotes ADD COLUMN IF NOT EXISTS cuenta_corriente_catastral text;

COMMENT ON COLUMN dymaerp.lotes.padron IS
  'Padrón registral propio del lote. Manda sobre el del loteamiento al armar el contrato.';
COMMENT ON COLUMN dymaerp.lotes.matricula IS
  'N.º de Finca / Matrícula / CUICR propio del lote. Manda sobre el del loteamiento al armar el contrato.';
COMMENT ON COLUMN dymaerp.lotes.cuenta_corriente_catastral IS
  'Cuenta corriente catastral propia del lote. Manda sobre la del loteamiento al armar el contrato.';

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve las columnas nuevas y
-- responde 404 aunque existan. Recarga sin reiniciar el contenedor.
NOTIFY pgrst, 'reload schema';

-- Verificación: las columnas registrales del lote.
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'dymaerp'
  AND table_name = 'lotes'
  AND column_name IN ('padron', 'matricula', 'cuenta_corriente_catastral')
ORDER BY column_name;
