-- =============================================================================
-- DYMA ERP — RUC + DV independientes, Profesión y Lugar de trabajo en el cliente
-- =============================================================================
-- Ejecutar DESPUÉS de 18_datos_registrales_por_lote.sql.
--
-- Una persona física puede tener Cédula (documento) y además estar inscripta como
-- contribuyente con RUC. Hasta ahora la ficha mostraba uno u otro según el tipo de
-- cliente; ahora los dos se guardan por separado y cargar el RUC no pisa la cédula.
--
--   dv             → dígito verificador del RUC, aparte del cuerpo (columna ruc).
--   profesion      → Profesión / Ocupación (a qué se dedica la persona).
--   lugar_trabajo  → Lugar de trabajo.
--
-- Al facturar: si el cliente tiene RUC + DV se usa RUC-DV; si no, se factura con
-- el documento (CI) como no contribuyente. La cédula nunca se reemplaza.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS dv text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS profesion text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS lugar_trabajo text;

COMMENT ON COLUMN dymaerp.clientes.dv IS
  'Dígito verificador del RUC, guardado aparte del cuerpo (columna ruc). En la factura se usa RUC-DV; si no hay RUC, se factura con documento (CI).';
COMMENT ON COLUMN dymaerp.clientes.profesion IS
  'Profesión / Ocupación del cliente: a qué se dedica la persona.';
COMMENT ON COLUMN dymaerp.clientes.lugar_trabajo IS
  'Lugar de trabajo del cliente.';

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve las columnas nuevas.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT column_name
FROM information_schema.columns
WHERE table_schema = 'dymaerp'
  AND table_name = 'clientes'
  AND column_name IN ('dv', 'profesion', 'lugar_trabajo')
ORDER BY column_name;
