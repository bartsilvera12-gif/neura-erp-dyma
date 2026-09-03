-- =============================================================================
-- DYMA ERP — Vendedores y comisión sobre cuotas cobradas
-- =============================================================================
-- Ejecutar DESPUÉS de 08_ventas_y_cuotas.sql.
--
-- Qué agrega:
--   vendedores                  → catálogo de vendedores, cada uno con su código
--   lote_ventas.vendedor_id     → la venta queda asociada a un vendedor
--   lote_ventas.comision_pct    → el % acordado, CONGELADO en el contrato
--
-- Por qué el % vive en el contrato y no solo en el vendedor: si mañana se
-- renegocia la comisión, los contratos ya firmados tienen que seguir liquidando
-- con el porcentaje con el que se vendieron. El vendedor solo aporta el valor
-- sugerido al momento de cargar la venta.
--
-- La comisión NO se guarda: se calcula al consultar, a partir de los pagos
-- imputados a las facturas de cada cuota. Una cuota pendiente no genera nada; el
-- día que se cobra, aparece en el mes de su cobro. Guardar el devengado obligaría
-- a mantenerlo sincronizado con cada pago, anulación y corrección.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Catálogo de vendedores
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.vendedores (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  -- Código con el que el negocio identifica al vendedor (ej. "10663").
  codigo text NOT NULL,
  nombre text NOT NULL,
  documento text,
  telefono text,
  email text,
  -- Comisión sugerida para las ventas nuevas de este vendedor. 0.03 = 3%.
  comision_pct numeric DEFAULT 0.03 NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  observacion text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'vendedores_pkey'
      AND conrelid = 'dymaerp.vendedores'::regclass
  ) THEN
    ALTER TABLE dymaerp.vendedores ADD CONSTRAINT vendedores_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.vendedores ADD CONSTRAINT vendedores_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.vendedores ADD CONSTRAINT vendedores_codigo_uq
      UNIQUE (empresa_id, codigo);
    ALTER TABLE dymaerp.vendedores ADD CONSTRAINT vendedores_codigo_check
      CHECK (btrim(codigo) <> '');
    ALTER TABLE dymaerp.vendedores ADD CONSTRAINT vendedores_nombre_check
      CHECK (btrim(nombre) <> '');
    -- Fracción, no porcentaje: 0.03 = 3%. El tope de 1 evita cargar "3" por "3%".
    ALTER TABLE dymaerp.vendedores ADD CONSTRAINT vendedores_comision_check
      CHECK (comision_pct >= 0 AND comision_pct <= 1);
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_vendedores_empresa
  ON dymaerp.vendedores USING btree (empresa_id, activo, nombre);

COMMENT ON TABLE dymaerp.vendedores IS
  'Vendedores con su código de negocio. La comisión se liquida sobre las cuotas efectivamente cobradas de sus ventas.';
COMMENT ON COLUMN dymaerp.vendedores.comision_pct IS
  'Comisión sugerida para ventas nuevas, como fracción (0.03 = 3%). El valor que rige es el congelado en lote_ventas.comision_pct.';

-- ---------------------------------------------------------------------------
-- 2) La venta queda asociada al vendedor, con su % congelado
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.lote_ventas ADD COLUMN IF NOT EXISTS vendedor_id uuid;
ALTER TABLE dymaerp.lote_ventas ADD COLUMN IF NOT EXISTS comision_pct numeric DEFAULT 0 NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_vendedor_id_fkey'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    -- RESTRICT: un vendedor con ventas no se borra; se marca inactivo.
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_vendedor_id_fkey
      FOREIGN KEY (vendedor_id) REFERENCES dymaerp.vendedores(id) ON DELETE RESTRICT;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_comision_check'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_comision_check
      CHECK (comision_pct >= 0 AND comision_pct <= 1);
  END IF;
END $$;

-- Listado de comisiones del mes: se entra por vendedor.
CREATE INDEX IF NOT EXISTS ix_lote_ventas_vendedor
  ON dymaerp.lote_ventas USING btree (empresa_id, vendedor_id)
  WHERE vendedor_id IS NOT NULL;

COMMENT ON COLUMN dymaerp.lote_ventas.vendedor_id IS
  'Vendedor que cerró la venta. Null = venta sin vendedor asignado (no genera comisión).';
COMMENT ON COLUMN dymaerp.lote_ventas.comision_pct IS
  'Comisión acordada, congelada al vender (0.03 = 3%). Renegociar con el vendedor no altera contratos ya firmados.';

-- ---------------------------------------------------------------------------
-- 3) updated_at automático
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_vendedores_updated ON dymaerp.vendedores;
CREATE TRIGGER trg_vendedores_updated
  BEFORE UPDATE ON dymaerp.vendedores
  FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4) RLS y permisos
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.vendedores ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS vendedores_select ON dymaerp.vendedores;
DROP POLICY IF EXISTS vendedores_insert ON dymaerp.vendedores;
DROP POLICY IF EXISTS vendedores_update ON dymaerp.vendedores;
DROP POLICY IF EXISTS vendedores_delete ON dymaerp.vendedores;

CREATE POLICY vendedores_select ON dymaerp.vendedores
  AS PERMISSIVE FOR SELECT TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY vendedores_insert ON dymaerp.vendedores
  AS PERMISSIVE FOR INSERT TO PUBLIC
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY vendedores_update ON dymaerp.vendedores
  AS PERMISSIVE FOR UPDATE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY vendedores_delete ON dymaerp.vendedores
  AS PERMISSIVE FOR DELETE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.vendedores TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE dymaerp.vendedores TO anon, service_role;

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve la tabla ni las
-- columnas nuevas y responde 404 aunque existan.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT 'vendedores' AS objeto, count(*)::text AS detalle
FROM information_schema.tables
WHERE table_schema = 'dymaerp' AND table_name = 'vendedores'
UNION ALL
SELECT 'lote_ventas.' || column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'dymaerp' AND table_name = 'lote_ventas'
  AND column_name IN ('vendedor_id', 'comision_pct')
ORDER BY 1;
