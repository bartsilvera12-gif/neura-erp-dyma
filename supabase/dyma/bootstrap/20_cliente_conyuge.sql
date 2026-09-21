-- =============================================================================
-- DYMA ERP — Datos del cónyuge en la ficha del cliente
-- =============================================================================
-- Ejecutar DESPUÉS de 19_cliente_ruc_dv_profesion.sql.
--
-- El cónyuge se cargaba sólo por contrato (lote_venta_partes), y no había dónde
-- registrarlo desde la ficha. Ahora se guarda en el cliente y el contrato lo
-- toma automáticamente cuando el tipo de contrato requiere cónyuge y la venta no
-- tiene uno cargado a mano.
--
-- Campos (mínimos pedidos por el cliente):
--   conyuge_nombre         → nombre y apellido
--   conyuge_documento      → CI
--   conyuge_profesion      → profesión / ocupación
--   conyuge_lugar_trabajo  → lugar de trabajo
--   conyuge_telefono       → teléfono
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS conyuge_nombre text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS conyuge_documento text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS conyuge_profesion text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS conyuge_lugar_trabajo text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS conyuge_telefono text;

COMMENT ON COLUMN dymaerp.clientes.conyuge_nombre IS
  'Nombre y apellido del cónyuge. Se usa en los contratos que requieren cónyuge si la venta no trae uno cargado.';
COMMENT ON COLUMN dymaerp.clientes.conyuge_documento IS 'CI del cónyuge.';

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve las columnas nuevas.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'dymaerp'
  AND table_name = 'clientes'
  AND column_name LIKE 'conyuge_%'
ORDER BY column_name;
