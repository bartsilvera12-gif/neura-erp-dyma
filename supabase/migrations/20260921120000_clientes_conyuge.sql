-- Datos del cónyuge en la ficha del cliente.
--
-- El cónyuge se cargaba sólo por contrato (lote_venta_partes). Ahora se guarda
-- también en el cliente para reutilizarlo automáticamente en los contratos que
-- requieren cónyuge. Campos mínimos pedidos: nombre y apellido, CI, profesión/
-- ocupación, lugar de trabajo y teléfono.
--
-- Idempotente: ADD COLUMN IF NOT EXISTS en todos los schemas con `clientes`
-- (public, zentra_erp, er_*, erp_*). El schema propio de DYMA (dymaerp) recibe
-- las mismas columnas desde su bootstrap.

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
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS conyuge_nombre text NULL;
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS conyuge_documento text NULL;
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS conyuge_profesion text NULL;
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS conyuge_lugar_trabajo text NULL;
        ALTER TABLE %I.clientes ADD COLUMN IF NOT EXISTS conyuge_telefono text NULL;
      $q$,
      r.s, r.s, r.s, r.s, r.s
    );
  END LOOP;
END $$;

NOTIFY pgrst, 'reload schema';
