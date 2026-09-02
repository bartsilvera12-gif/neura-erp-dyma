-- =============================================================================
-- DYMA ERP — módulo Servicio de limpieza
-- =============================================================================
-- Ejecutar DESPUÉS de 03_datos_maestros_dyma.sql (y de 04, en cualquier orden).
--
-- Servicio que se presta puntualmente sobre el lote de un cliente (típicamente
-- terrenos sin construcción todavía). NO se genera automáticamente ni por
-- calendario: lo carga el usuario a mano el día que el servicio se hizo.
--
-- Cada registro emite una factura contra el cliente, así el importe entra solo
-- al circuito de Cobranzas / Pagos / Estado de cuenta / Gerencia. `factura_id`
-- guarda ese vínculo.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Tabla de servicios prestados
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.servicios_limpieza (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  fecha_servicio date NOT NULL,
  importe numeric NOT NULL,
  moneda text DEFAULT 'GS'::text NOT NULL,
  observacion text,
  -- Factura emitida por este servicio. ON DELETE SET NULL: si la factura se
  -- borra, el registro del servicio prestado sobrevive como historial.
  factura_id uuid,
  creado_por uuid,
  creado_por_email text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'servicios_limpieza_pkey'
      AND conrelid = 'dymaerp.servicios_limpieza'::regclass
  ) THEN
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_importe_check
      CHECK (importe > 0);
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_moneda_check
      CHECK (moneda = ANY (ARRAY['GS'::text, 'USD'::text]));
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_factura_id_fkey
      FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE SET NULL;
    ALTER TABLE dymaerp.servicios_limpieza ADD CONSTRAINT servicios_limpieza_creado_por_fkey
      FOREIGN KEY (creado_por) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_servicios_limpieza_fecha
  ON dymaerp.servicios_limpieza USING btree (empresa_id, fecha_servicio DESC);
CREATE INDEX IF NOT EXISTS ix_servicios_limpieza_cliente
  ON dymaerp.servicios_limpieza USING btree (empresa_id, cliente_id, fecha_servicio DESC);
CREATE INDEX IF NOT EXISTS ix_servicios_limpieza_factura
  ON dymaerp.servicios_limpieza USING btree (factura_id) WHERE factura_id IS NOT NULL;

COMMENT ON TABLE dymaerp.servicios_limpieza IS
  'Servicios de limpieza de lote prestados a un cliente. Alta manual: se carga solo cuando el servicio efectivamente se realizó. Cada fila emite una factura (factura_id).';
COMMENT ON COLUMN dymaerp.servicios_limpieza.factura_id IS
  'Factura emitida por este servicio. NULL si la factura fue eliminada después.';

-- ---------------------------------------------------------------------------
-- 2) updated_at automático, con el mismo trigger que usa el resto del schema
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_servicios_limpieza_updated ON dymaerp.servicios_limpieza;
CREATE TRIGGER trg_servicios_limpieza_updated
  BEFORE UPDATE ON dymaerp.servicios_limpieza
  FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3) RLS y permisos — mismo patrón que `facturas`: 4 policies TO PUBLIC
--    filtrando por `puede_acceder_empresa`.
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.servicios_limpieza ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS servicios_limpieza_select ON dymaerp.servicios_limpieza;
DROP POLICY IF EXISTS servicios_limpieza_insert ON dymaerp.servicios_limpieza;
DROP POLICY IF EXISTS servicios_limpieza_update ON dymaerp.servicios_limpieza;
DROP POLICY IF EXISTS servicios_limpieza_delete ON dymaerp.servicios_limpieza;
CREATE POLICY servicios_limpieza_select ON dymaerp.servicios_limpieza
  AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY servicios_limpieza_insert ON dymaerp.servicios_limpieza
  AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY servicios_limpieza_update ON dymaerp.servicios_limpieza
  AS PERMISSIVE FOR UPDATE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY servicios_limpieza_delete ON dymaerp.servicios_limpieza
  AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.servicios_limpieza TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.servicios_limpieza TO anon, service_role;

-- ---------------------------------------------------------------------------
-- 4) Módulo `limpieza` en el catálogo y habilitado para DYMA
-- ---------------------------------------------------------------------------
INSERT INTO dymaerp.modulos (id, nombre, slug, descripcion) VALUES
  ('5f444016-01d1-43e0-b626-c11f2eea202c','Limpieza','limpieza','Servicio de limpieza de lote, carga manual por cliente')
ON CONFLICT (id) DO NOTHING;

INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
SELECT '06255def-3835-4d37-8f7f-801af8043e8c', m.id, true
FROM dymaerp.modulos m
WHERE m.slug = 'limpieza'
  AND NOT EXISTS (
    SELECT 1 FROM dymaerp.empresa_modulos em
    WHERE em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND em.modulo_id = m.id
  );

COMMIT;

-- Verificación: debe listar los 10 módulos activos, incluido `limpieza`.
SELECT m.slug, m.nombre
FROM dymaerp.empresa_modulos em
JOIN dymaerp.modulos m ON m.id = em.modulo_id
WHERE em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND em.activo
ORDER BY m.slug;
