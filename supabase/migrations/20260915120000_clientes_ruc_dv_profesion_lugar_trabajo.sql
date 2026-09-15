-- Ficha de cliente: RUC + DV como campos independientes del CI/Documento, más
-- Profesión/Ocupación y Lugar de trabajo.
--
-- Una persona física puede tener Cédula (documento) y además estar inscripta con
-- RUC. Hasta ahora el formulario mostraba uno u otro según tipo_cliente; ahora se
-- guardan por separado y cargar el RUC no pisa la cédula.
--
--   dv             → dígito verificador del RUC (se guarda aparte del cuerpo).
--   profesion      → Profesión / Ocupación.
--   lugar_trabajo  → Lugar de trabajo.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS en todos los schemas que tienen `clientes`
-- (public, zentra_erp, er_*, erp_*). El schema propio de DYMA (dymaerp) recibe las
-- mismas columnas desde su bootstrap.

DO $$
DECLARE
  r RECORD;
BEGIN
  FOR r IN
    SELECT n.nspname AS s
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'clientes'
      AND c.relkind = 'r'
      AND (
        n.nspname IN ('public', 'zentra_erp')
        OR n.nspname ~ '^er_[0-9a-f]{32}$'
        OR n.nspname LIKE 'erp\_%' ESCAPE '\'
      )
  LOOP
    EXECUTE format(
      $q$
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS dv text NULL;
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS profesion text NULL;
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS lugar_trabajo text NULL;
      $q$,
      r.s, r.s, r.s
    );
    EXECUTE format(
      'COMMENT ON COLUMN %I.clientes.dv IS %L',
      r.s,
      'Dígito verificador del RUC, guardado aparte del cuerpo (columna ruc). En la factura se usa RUC-DV; si no hay RUC, se factura con documento (CI).'
    );
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
