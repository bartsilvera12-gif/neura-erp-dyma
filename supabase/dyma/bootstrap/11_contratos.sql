-- =============================================================================
-- DYMA ERP — Tipos de contrato, partes y datos para el documento
-- =============================================================================
-- Ejecutar DESPUÉS de 10_simulador_planes.sql.
--
-- Qué agrega:
--   contrato_tipos               → catálogo de tipos (individual, cónyuge, codeudor…)
--   lote_venta_partes            → datos completos de cónyuge / codeudor por contrato
--   lote_ventas.tipo_contrato_id → qué plantilla usa cada contrato
--   contrato_config              → datos de LA VENDEDORA para el encabezado
--   clientes.nacionalidad / estado_civil
--   loteamientos: finca matriz, catastro, resolución municipal, RUN, ubicación
--
-- Reemplaza `lote_venta_codeudores`, que solo guardaba un vínculo a `clientes`.
-- El contrato necesita los datos COMPLETOS del codeudor (documento, estado civil,
-- domicilio), y un codeudor no siempre es cliente de la empresa. La tabla nueva
-- los guarda de forma independiente, con vínculo opcional al cliente si lo es.
--
-- El catálogo de tipos es data-driven a propósito: el cliente todavía tiene que
-- confirmar la lista completa, y agregar uno nuevo debe ser insertar una fila,
-- no tocar código.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Catálogo de tipos de contrato
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.contrato_tipos (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  slug text NOT NULL,
  nombre text NOT NULL,
  descripcion text,
  -- Qué partes adicionales exige este tipo. La UI muestra los formularios
  -- correspondientes y la plantilla incluye sus cláusulas.
  requiere_conyuge boolean DEFAULT false NOT NULL,
  requiere_codeudor boolean DEFAULT false NOT NULL,
  -- Plantilla del documento. Hoy solo existe la de compraventa a plazos.
  plantilla text DEFAULT 'compraventa_plazos'::text NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'contrato_tipos_pkey'
      AND conrelid = 'dymaerp.contrato_tipos'::regclass
  ) THEN
    ALTER TABLE dymaerp.contrato_tipos ADD CONSTRAINT contrato_tipos_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.contrato_tipos ADD CONSTRAINT contrato_tipos_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.contrato_tipos ADD CONSTRAINT contrato_tipos_slug_uq
      UNIQUE (empresa_id, slug);
    ALTER TABLE dymaerp.contrato_tipos ADD CONSTRAINT contrato_tipos_slug_check
      CHECK (btrim(slug) <> '' AND btrim(nombre) <> '');
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 2) Partes adicionales del contrato (cónyuge, codeudor)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.lote_venta_partes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  -- conyuge | codeudor
  rol text NOT NULL,
  -- Si además es cliente de la empresa, queda vinculado. No es obligatorio:
  -- un codeudor puede no tener ninguna otra relación con el negocio.
  cliente_id uuid,
  nombre text NOT NULL,
  documento text,
  nacionalidad text DEFAULT 'paraguaya'::text,
  estado_civil text,
  domicilio text,
  telefono text,
  email text,
  observacion text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_venta_partes_pkey'
      AND conrelid = 'dymaerp.lote_venta_partes'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_venta_partes ADD CONSTRAINT lote_venta_partes_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.lote_venta_partes ADD CONSTRAINT lote_venta_partes_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.lote_venta_partes ADD CONSTRAINT lote_venta_partes_venta_id_fkey
      FOREIGN KEY (venta_id) REFERENCES dymaerp.lote_ventas(id) ON DELETE CASCADE;
    -- SET NULL: si se borra el cliente vinculado, los datos de la parte quedan.
    -- El contrato firmado no puede perder quién lo firmó.
    ALTER TABLE dymaerp.lote_venta_partes ADD CONSTRAINT lote_venta_partes_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
    ALTER TABLE dymaerp.lote_venta_partes ADD CONSTRAINT lote_venta_partes_rol_check
      CHECK (rol = ANY (ARRAY['conyuge'::text, 'codeudor'::text]));
    ALTER TABLE dymaerp.lote_venta_partes ADD CONSTRAINT lote_venta_partes_nombre_check
      CHECK (btrim(nombre) <> '');
  END IF;
END $$;

-- Un solo cónyuge por contrato; codeudores puede haber varios.
CREATE UNIQUE INDEX IF NOT EXISTS uq_lote_venta_conyuge
  ON dymaerp.lote_venta_partes (venta_id) WHERE rol = 'conyuge';
CREATE INDEX IF NOT EXISTS ix_lote_venta_partes_venta
  ON dymaerp.lote_venta_partes USING btree (venta_id, rol);

COMMENT ON TABLE dymaerp.lote_venta_partes IS
  'Cónyuge y codeudores de un contrato, con sus datos completos. Independientes de `clientes`: un codeudor puede no ser cliente, y el contrato firmado no debe perder sus datos si el cliente cambia.';

-- Se traen los codeudores que hubiera en la tabla vieja antes de retirarla.
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'dymaerp' AND table_name = 'lote_venta_codeudores'
  ) THEN
    INSERT INTO dymaerp.lote_venta_partes
      (empresa_id, venta_id, rol, cliente_id, nombre, documento, domicilio, telefono, email, observacion)
    SELECT
      k.empresa_id, k.venta_id, 'codeudor', k.cliente_id,
      COALESCE(NULLIF(btrim(COALESCE(c.empresa, c.nombre_contacto, c.nombre)), ''), 'Codeudor'),
      COALESCE(c.documento, c.ruc), c.direccion, c.telefono, c.email, k.observacion
    FROM dymaerp.lote_venta_codeudores k
    LEFT JOIN dymaerp.clientes c ON c.id = k.cliente_id
    WHERE NOT EXISTS (
      SELECT 1 FROM dymaerp.lote_venta_partes p
      WHERE p.venta_id = k.venta_id AND p.rol = 'codeudor' AND p.cliente_id IS NOT DISTINCT FROM k.cliente_id
    );
    DROP TABLE dymaerp.lote_venta_codeudores;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 3) El contrato sabe de qué tipo es
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.lote_ventas ADD COLUMN IF NOT EXISTS tipo_contrato_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_tipo_contrato_id_fkey'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_tipo_contrato_id_fkey
      FOREIGN KEY (tipo_contrato_id) REFERENCES dymaerp.contrato_tipos(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 4) Datos de LA VENDEDORA para el encabezado del contrato
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.contrato_config (
  empresa_id uuid NOT NULL,
  razon_social text DEFAULT 'DYMA SA'::text NOT NULL,
  ruc text,
  representante_nombre text,
  representante_documento text,
  domicilio text,
  ciudad_firma text DEFAULT 'Juan E. O''Leary'::text,
  departamento text DEFAULT 'Alto Paraná'::text,
  lugar_pago text,
  -- Los pagos van del día 1 al 5 de cada mes según el contrato modelo.
  dia_pago_desde integer DEFAULT 1 NOT NULL,
  dia_pago_hasta integer DEFAULT 5 NOT NULL,
  ejemplares integer DEFAULT 3 NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'contrato_config_pkey'
      AND conrelid = 'dymaerp.contrato_config'::regclass
  ) THEN
    ALTER TABLE dymaerp.contrato_config ADD CONSTRAINT contrato_config_pkey PRIMARY KEY (empresa_id);
    ALTER TABLE dymaerp.contrato_config ADD CONSTRAINT contrato_config_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.contrato_config ADD CONSTRAINT contrato_config_dias_check
      CHECK (dia_pago_desde BETWEEN 1 AND 28 AND dia_pago_hasta BETWEEN 1 AND 28
         AND dia_pago_hasta >= dia_pago_desde);
  END IF;
END $$;

-- ---------------------------------------------------------------------------
-- 5) Datos personales que el contrato pide y la ficha no tenía
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS nacionalidad text;
ALTER TABLE dymaerp.clientes ADD COLUMN IF NOT EXISTS estado_civil text;

COMMENT ON COLUMN dymaerp.clientes.estado_civil IS
  'Texto libre (soltero/a, casado/a…). El contrato lo transcribe tal cual.';

-- ---------------------------------------------------------------------------
-- 6) Datos registrales del loteamiento para el apartado del contrato
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS departamento text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS distrito text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS finca_matriz text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS matricula text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS cuenta_corriente_catastral text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS padron text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS resolucion_municipal text;
ALTER TABLE dymaerp.loteamientos ADD COLUMN IF NOT EXISTS run_expediente text;

-- ---------------------------------------------------------------------------
-- 7) updated_at automático
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['contrato_tipos','lote_venta_partes','contrato_config'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated ON dymaerp.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON dymaerp.%I FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at()',
      t, t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 8) RLS y permisos
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['contrato_tipos','lote_venta_partes','contrato_config'] LOOP
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
-- 9) Semillas para DYMA
-- ---------------------------------------------------------------------------
INSERT INTO dymaerp.contrato_tipos (empresa_id, slug, nombre, descripcion, requiere_conyuge, requiere_codeudor, orden)
VALUES
  ('06255def-3835-4d37-8f7f-801af8043e8c', 'individual', 'Contrato individual',
   'Solo el comprador titular. Es el contrato normal.', false, false, 1),
  ('06255def-3835-4d37-8f7f-801af8043e8c', 'conyuge', 'Contrato con cónyuge',
   'El titular firma junto a su cónyuge, que compra en el mismo acto.', true, false, 2),
  ('06255def-3835-4d37-8f7f-801af8043e8c', 'con_codeudor', 'Contrato con codeudor',
   'Además del titular, un codeudor responde solidariamente por el pago.', false, true, 3)
ON CONFLICT (empresa_id, slug) DO UPDATE
  SET nombre = EXCLUDED.nombre,
      descripcion = EXCLUDED.descripcion,
      requiere_conyuge = EXCLUDED.requiere_conyuge,
      requiere_codeudor = EXCLUDED.requiere_codeudor,
      orden = EXCLUDED.orden;

INSERT INTO dymaerp.contrato_config
  (empresa_id, razon_social, ruc, representante_nombre, domicilio, ciudad_firma, departamento)
VALUES
  ('06255def-3835-4d37-8f7f-801af8043e8c', 'DYMA SA', '80149103-7', 'Rody Sebastian Verdún Rios',
   'Calle Monday, Barrio San Juan, Juan Emilio O''Leary - Alto Paraná',
   'Juan E. O''Leary', 'Alto Paraná')
ON CONFLICT (empresa_id) DO NOTHING;

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve las tablas ni las
-- columnas nuevas y responde 404 aunque existan.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT slug, nombre, requiere_conyuge, requiere_codeudor
FROM dymaerp.contrato_tipos
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
ORDER BY orden;
