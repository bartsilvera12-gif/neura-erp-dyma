-- =============================================================================
-- DYMA ERP — módulo Administración de Lotes (fase 1)
-- =============================================================================
-- Ejecutar DESPUÉS de 03_datos_maestros_dyma.sql.
--
-- Jerarquía del loteamiento:
--     loteamientos → fracciones → manzanas → lotes
--
-- NOMBRE: el nivel superior se llama `loteamientos` y no `proyectos` porque en
-- este schema `proyectos` ya existe y es otra cosa (gestión de tareas/entregas,
-- con tipos, estados y QA). Son dominios distintos y no deben mezclarse.
--
-- El lote es la unidad vendible: dimensiones, linderos, precio de contado y
-- precio financiado, y un estado que controla si se puede vender o no.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Loteamiento — el emprendimiento inmobiliario
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.loteamientos (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  codigo text NOT NULL,
  nombre text NOT NULL,
  ubicacion text,
  descripcion text,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 2) Fracción — subdivisión mayor del loteamiento
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.loteamiento_fracciones (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  loteamiento_id uuid NOT NULL,
  codigo text NOT NULL,
  nombre text,
  orden integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 3) Manzana — agrupa los lotes dentro de una fracción
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.loteamiento_manzanas (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  fraccion_id uuid NOT NULL,
  codigo text NOT NULL,
  nombre text,
  orden integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 4) Lote — la unidad vendible
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.lotes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  manzana_id uuid NOT NULL,
  numero text NOT NULL,
  -- Dimensiones. `superficie_m2` es el dato que manda para precio y contrato;
  -- frente y fondo son informativos (hay lotes irregulares donde no multiplican).
  superficie_m2 numeric,
  frente_m numeric,
  fondo_m numeric,
  lindero_norte text,
  lindero_sur text,
  lindero_este text,
  lindero_oeste text,
  -- Precios de lista. El precio pactado real se congela después en la venta.
  precio_contado numeric,
  precio_financiado numeric,
  moneda text DEFAULT 'GS'::text NOT NULL,
  -- disponible | reservado | vendido | bloqueado
  estado text DEFAULT 'disponible'::text NOT NULL,
  estado_motivo text,
  -- Cliente que lo tiene reservado o lo compró. NULL mientras está disponible.
  cliente_id uuid,
  observacion text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 5) Claves, unicidad y reglas
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'loteamientos_pkey'
      AND conrelid = 'dymaerp.loteamientos'::regclass
  ) THEN
    ALTER TABLE dymaerp.loteamientos ADD CONSTRAINT loteamientos_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.loteamientos ADD CONSTRAINT loteamientos_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.loteamientos ADD CONSTRAINT loteamientos_codigo_uq
      UNIQUE (empresa_id, codigo);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'loteamiento_fracciones_pkey'
      AND conrelid = 'dymaerp.loteamiento_fracciones'::regclass
  ) THEN
    ALTER TABLE dymaerp.loteamiento_fracciones ADD CONSTRAINT loteamiento_fracciones_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.loteamiento_fracciones ADD CONSTRAINT loteamiento_fracciones_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.loteamiento_fracciones ADD CONSTRAINT loteamiento_fracciones_loteamiento_id_fkey
      FOREIGN KEY (loteamiento_id) REFERENCES dymaerp.loteamientos(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.loteamiento_fracciones ADD CONSTRAINT loteamiento_fracciones_codigo_uq
      UNIQUE (loteamiento_id, codigo);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'loteamiento_manzanas_pkey'
      AND conrelid = 'dymaerp.loteamiento_manzanas'::regclass
  ) THEN
    ALTER TABLE dymaerp.loteamiento_manzanas ADD CONSTRAINT loteamiento_manzanas_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.loteamiento_manzanas ADD CONSTRAINT loteamiento_manzanas_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.loteamiento_manzanas ADD CONSTRAINT loteamiento_manzanas_fraccion_id_fkey
      FOREIGN KEY (fraccion_id) REFERENCES dymaerp.loteamiento_fracciones(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.loteamiento_manzanas ADD CONSTRAINT loteamiento_manzanas_codigo_uq
      UNIQUE (fraccion_id, codigo);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lotes_pkey'
      AND conrelid = 'dymaerp.lotes'::regclass
  ) THEN
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_manzana_id_fkey
      FOREIGN KEY (manzana_id) REFERENCES dymaerp.loteamiento_manzanas(id) ON DELETE CASCADE;
    -- RESTRICT, no SET NULL: un lote reservado o vendido tiene que conservar su
    -- titular (lo exige `lotes_titular_segun_estado_check`), así que borrar de
    -- verdad a un cliente con lotes asignados se bloquea. Para dar de baja a un
    -- cliente está la baja lógica que ya usa el ERP (`deleted_at` / baja operativa),
    -- que no toca esta FK.
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE RESTRICT;
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_numero_uq
      UNIQUE (manzana_id, numero);
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_estado_check
      CHECK (estado = ANY (ARRAY['disponible'::text, 'reservado'::text, 'vendido'::text, 'bloqueado'::text]));
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_moneda_check
      CHECK (moneda = ANY (ARRAY['GS'::text, 'USD'::text]));
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_precios_check
      CHECK ((precio_contado IS NULL OR precio_contado >= 0)
         AND (precio_financiado IS NULL OR precio_financiado >= 0));
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_medidas_check
      CHECK ((superficie_m2 IS NULL OR superficie_m2 > 0)
         AND (frente_m IS NULL OR frente_m > 0)
         AND (fondo_m IS NULL OR fondo_m > 0));
    -- Reservado y vendido exigen titular; disponible no puede tenerlo.
    ALTER TABLE dymaerp.lotes ADD CONSTRAINT lotes_titular_segun_estado_check
      CHECK (
        (estado IN ('reservado', 'vendido') AND cliente_id IS NOT NULL)
        OR (estado = 'disponible' AND cliente_id IS NULL)
        OR estado = 'bloqueado'
      );
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 6) Índices de consulta
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS ix_loteamientos_empresa
  ON dymaerp.loteamientos USING btree (empresa_id) WHERE activo;
CREATE INDEX IF NOT EXISTS ix_fracciones_loteamiento
  ON dymaerp.loteamiento_fracciones USING btree (loteamiento_id, orden);
CREATE INDEX IF NOT EXISTS ix_manzanas_fraccion
  ON dymaerp.loteamiento_manzanas USING btree (fraccion_id, orden);
CREATE INDEX IF NOT EXISTS ix_lotes_manzana
  ON dymaerp.lotes USING btree (manzana_id, numero);
CREATE INDEX IF NOT EXISTS ix_lotes_estado
  ON dymaerp.lotes USING btree (empresa_id, estado);
CREATE INDEX IF NOT EXISTS ix_lotes_cliente
  ON dymaerp.lotes USING btree (cliente_id) WHERE cliente_id IS NOT NULL;

COMMENT ON TABLE dymaerp.loteamientos IS
  'Emprendimiento inmobiliario. Nivel superior de la jerarquía loteamiento → fracción → manzana → lote. No confundir con `proyectos`, que es el módulo de gestión de tareas.';
COMMENT ON TABLE dymaerp.lotes IS
  'Unidad vendible del loteamiento: dimensiones, linderos, precio de contado y financiado, y estado comercial.';
COMMENT ON COLUMN dymaerp.lotes.estado IS
  'disponible | reservado | vendido | bloqueado. Reservado y vendido exigen cliente_id.';

-- ---------------------------------------------------------------------------
-- 7) updated_at automático
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['loteamientos','loteamiento_fracciones','loteamiento_manzanas','lotes'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated ON dymaerp.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON dymaerp.%I FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at()',
      t, t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 8) RLS y permisos — mismo patrón que el resto del schema
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['loteamientos','loteamiento_fracciones','loteamiento_manzanas','lotes'] LOOP
    EXECUTE format('ALTER TABLE dymaerp.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON dymaerp.%I', t || '_select', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON dymaerp.%I', t || '_insert', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON dymaerp.%I', t || '_update', t);
    EXECUTE format('DROP POLICY IF EXISTS %I ON dymaerp.%I', t || '_delete', t);
    EXECUTE format(
      'CREATE POLICY %I ON dymaerp.%I AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id))',
      t || '_select', t);
    EXECUTE format(
      'CREATE POLICY %I ON dymaerp.%I AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
      t || '_insert', t);
    EXECUTE format(
      'CREATE POLICY %I ON dymaerp.%I AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
      t || '_update', t);
    EXECUTE format(
      'CREATE POLICY %I ON dymaerp.%I AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id))',
      t || '_delete', t);
    EXECUTE format('GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.%I TO authenticated', t);
    EXECUTE format(
      'GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.%I TO anon, service_role', t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 9) Módulo `lotes` en el catálogo y habilitado para DYMA
-- ---------------------------------------------------------------------------
INSERT INTO dymaerp.modulos (id, nombre, slug, descripcion) VALUES
  ('5c61e4fb-f72b-4b7b-8429-2608ac4cefbb','Lotes','lotes','Administración de loteamientos, fracciones, manzanas y lotes')
ON CONFLICT (id) DO NOTHING;

INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
SELECT '06255def-3835-4d37-8f7f-801af8043e8c', m.id, true
FROM dymaerp.modulos m
WHERE m.slug = 'lotes'
  AND NOT EXISTS (
    SELECT 1 FROM dymaerp.empresa_modulos em
    WHERE em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND em.modulo_id = m.id
  );

COMMIT;

-- Verificación: los módulos activos, ahora con `lotes`.
SELECT m.slug, m.nombre
FROM dymaerp.empresa_modulos em
JOIN dymaerp.modulos m ON m.id = em.modulo_id
WHERE em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND em.activo
ORDER BY m.slug;
