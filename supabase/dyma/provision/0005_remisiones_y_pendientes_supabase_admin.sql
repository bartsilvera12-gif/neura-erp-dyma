-- =============================================================================
-- DYMA — script para ejecutar en el SQL Editor de Supabase
-- =============================================================================
-- Ejecutar COMPLETO, de una sola vez. Es idempotente: se puede correr varias veces.
--
-- Requiere rol propietario (supabase_admin / superusuario). El rol `postgres`
-- de la cadena de conexión NO tiene permiso de DDL sobre el schema `dymaerp`
-- (owner = supabase_admin), por eso estos pasos no se pudieron automatizar.
--
-- Contenido:
--   1) Tablas de Remisión / Recepción (multi-depósito)
--   2) movimientos_inventario: columna ubicacion_id + origen 'nota_remision'
--   3) Permisos del rol anon (rutas públicas)
--   4) Funciones de acceso RLS apuntando a dymaerp
--   5) Catálogo de módulos: Remisión y Recepción
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 1) TABLAS DE REMISIÓN / RECEPCIÓN
-- -----------------------------------------------------------------------------

-- Stock por depósito (base del multi-depósito).
CREATE TABLE IF NOT EXISTS dymaerp.productos_stock_ubicacion (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id   uuid NOT NULL,
  producto_id  uuid NOT NULL REFERENCES dymaerp.productos(id) ON DELETE CASCADE,
  ubicacion_id uuid NOT NULL REFERENCES dymaerp.inventario_ubicaciones(id) ON DELETE CASCADE,
  stock        numeric NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT productos_stock_ubicacion_empresa_producto_ubicacion_key
    UNIQUE (empresa_id, producto_id, ubicacion_id)
);
CREATE INDEX IF NOT EXISTS idx_psu_producto    ON dymaerp.productos_stock_ubicacion (producto_id);
CREATE INDEX IF NOT EXISTS idx_psu_ubicacion   ON dymaerp.productos_stock_ubicacion (ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_psu_empresa_ubi ON dymaerp.productos_stock_ubicacion (empresa_id, ubicacion_id);

-- Cabecera de la nota de remisión (documento NO fiscal).
CREATE TABLE IF NOT EXISTS dymaerp.notas_remision (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  empresa_id            uuid NOT NULL,
  numero                text NOT NULL,
  fecha                 timestamptz NOT NULL DEFAULT now(),
  emisor                text NOT NULL,
  ubicacion_origen_id   uuid NOT NULL REFERENCES dymaerp.inventario_ubicaciones(id),
  ubicacion_destino_id  uuid NOT NULL REFERENCES dymaerp.inventario_ubicaciones(id),
  motivo                text NOT NULL DEFAULT 'traslado',
  estado                text NOT NULL DEFAULT 'pendiente',
  motivo_rechazo        text,
  aprobada_at           timestamptz,
  aprobada_por          text,
  transportista         text,
  ruc_transportista     text,
  conductor             text,
  ci_conductor          text,
  chapa                 text,
  fecha_inicio_traslado date,
  fecha_fin_traslado    date,
  observaciones         text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT notas_remision_empresa_id_numero_key UNIQUE (empresa_id, numero),
  CONSTRAINT notas_remision_estado_check CHECK (estado = ANY (ARRAY['pendiente','aprobada','rechazada'])),
  CONSTRAINT notas_remision_motivo_check CHECK (motivo = ANY (ARRAY['traslado','venta','devolucion']))
);
CREATE INDEX IF NOT EXISTS idx_nr_empresa ON dymaerp.notas_remision (empresa_id);
CREATE INDEX IF NOT EXISTS idx_nr_estado  ON dymaerp.notas_remision (empresa_id, estado);
CREATE INDEX IF NOT EXISTS idx_nr_destino ON dymaerp.notas_remision (ubicacion_destino_id, estado);

-- Ítems de la nota de remisión.
CREATE TABLE IF NOT EXISTS dymaerp.notas_remision_items (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nota_remision_id uuid NOT NULL REFERENCES dymaerp.notas_remision(id) ON DELETE CASCADE,
  producto_id      uuid NOT NULL REFERENCES dymaerp.productos(id),
  cantidad         numeric NOT NULL,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_nri_nr       ON dymaerp.notas_remision_items (nota_remision_id);
CREATE INDEX IF NOT EXISTS idx_nri_producto ON dymaerp.notas_remision_items (producto_id);

-- RLS: mismo patrón del resto del schema, usando la función PROPIA de dymaerp.
ALTER TABLE dymaerp.productos_stock_ubicacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.notas_remision            ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.notas_remision_items      ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS psu_all ON dymaerp.productos_stock_ubicacion;
CREATE POLICY psu_all ON dymaerp.productos_stock_ubicacion
  FOR ALL USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));

DROP POLICY IF EXISTS nr_all ON dymaerp.notas_remision;
CREATE POLICY nr_all ON dymaerp.notas_remision
  FOR ALL USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));

-- Los ítems heredan el permiso de su cabecera.
DROP POLICY IF EXISTS nri_all ON dymaerp.notas_remision_items;
CREATE POLICY nri_all ON dymaerp.notas_remision_items
  FOR ALL USING (EXISTS (
    SELECT 1 FROM dymaerp.notas_remision nr
    WHERE nr.id = nota_remision_id AND dymaerp.puede_acceder_empresa(nr.empresa_id)
  ))
  WITH CHECK (EXISTS (
    SELECT 1 FROM dymaerp.notas_remision nr
    WHERE nr.id = nota_remision_id AND dymaerp.puede_acceder_empresa(nr.empresa_id)
  ));

GRANT ALL ON dymaerp.productos_stock_ubicacion, dymaerp.notas_remision, dymaerp.notas_remision_items
  TO anon, authenticated, service_role;


-- -----------------------------------------------------------------------------
-- 2) MOVIMIENTOS DE INVENTARIO: soporte de depósito y origen 'nota_remision'
-- -----------------------------------------------------------------------------
ALTER TABLE dymaerp.movimientos_inventario
  ADD COLUMN IF NOT EXISTS ubicacion_id uuid REFERENCES dymaerp.inventario_ubicaciones(id);

CREATE INDEX IF NOT EXISTS idx_mov_ubicacion ON dymaerp.movimientos_inventario (ubicacion_id);

-- El CHECK actual de `origen` no admite 'nota_remision'; se reemplaza incluyéndolo.
DO $$
DECLARE v_con text;
BEGIN
  SELECT co.conname INTO v_con
  FROM pg_constraint co
  JOIN pg_class cl ON cl.oid = co.conrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
  WHERE n.nspname = 'dymaerp' AND cl.relname = 'movimientos_inventario'
    AND co.contype = 'c' AND pg_get_constraintdef(co.oid) LIKE '%origen%';
  IF v_con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE dymaerp.movimientos_inventario DROP CONSTRAINT %I', v_con);
  END IF;
  ALTER TABLE dymaerp.movimientos_inventario
    ADD CONSTRAINT movimientos_inventario_origen_check
    CHECK (origen = ANY (ARRAY['compra','venta','ajuste_manual','inventario_inicial',
                               'produccion','devolucion_venta','nota_remision']));
END $$;


-- -----------------------------------------------------------------------------
-- 3) PERMISOS DEL ROL anon (rutas públicas). RLS sigue filtrando fila por fila.
-- -----------------------------------------------------------------------------
GRANT USAGE ON SCHEMA dymaerp TO anon;
GRANT ALL ON ALL TABLES     IN SCHEMA dymaerp TO anon;
GRANT ALL ON ALL SEQUENCES  IN SCHEMA dymaerp TO anon;
GRANT EXECUTE ON ALL ROUTINES IN SCHEMA dymaerp TO anon;


-- -----------------------------------------------------------------------------
-- 4) FUNCIONES DE ACCESO RLS APUNTANDO A dymaerp
--    (heredaban `search_path` del tenant enlodemari; el cuerpo ya es correcto)
-- -----------------------------------------------------------------------------
ALTER FUNCTION dymaerp.jwt_email_normalized() SET search_path TO 'dymaerp';
ALTER FUNCTION dymaerp.empresa_id_actual()    SET search_path TO 'dymaerp';
ALTER FUNCTION dymaerp.es_super_admin()       SET search_path TO 'dymaerp';
ALTER FUNCTION dymaerp.puede_acceder_empresa(uuid) SET search_path TO 'dymaerp';

-- Guard heredado de otro tenant (hardcodea su UUID). No está usado por ningún trigger.
DROP FUNCTION IF EXISTS dymaerp.neura_enlodemari_block_other_empresas();


-- -----------------------------------------------------------------------------
-- 5) CATÁLOGO DE MÓDULOS: Remisión y Recepción (habilitados para DYMA)
-- -----------------------------------------------------------------------------
INSERT INTO dymaerp.modulos (id, nombre, slug, descripcion)
SELECT gen_random_uuid(), 'Remisión', 'remision', 'Emisión de notas de remisión (traslado entre depósitos)'
WHERE NOT EXISTS (SELECT 1 FROM dymaerp.modulos WHERE slug = 'remision');

INSERT INTO dymaerp.modulos (id, nombre, slug, descripcion)
SELECT gen_random_uuid(), 'Recepción', 'recepcion', 'Recepción y aprobación de remisiones entrantes'
WHERE NOT EXISTS (SELECT 1 FROM dymaerp.modulos WHERE slug = 'recepcion');

INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
SELECT '20863e7f-39f3-4bb7-87bf-90fd7e08f396', m.id, true
FROM dymaerp.modulos m
WHERE m.slug IN ('remision', 'recepcion')
  AND NOT EXISTS (
    SELECT 1 FROM dymaerp.empresa_modulos em
    WHERE em.empresa_id = '20863e7f-39f3-4bb7-87bf-90fd7e08f396' AND em.modulo_id = m.id
  );


-- =============================================================================
-- Verificación rápida (debe devolver todo en OK)
-- =============================================================================
SELECT
  (SELECT count(*) FROM information_schema.tables
     WHERE table_schema='dymaerp'
       AND table_name IN ('notas_remision','notas_remision_items','productos_stock_ubicacion')) AS tablas_creadas_de_3,
  (SELECT count(*) FROM information_schema.columns
     WHERE table_schema='dymaerp' AND table_name='movimientos_inventario' AND column_name='ubicacion_id') AS ubicacion_id_ok,
  (SELECT count(*) FROM information_schema.role_table_grants
     WHERE table_schema='dymaerp' AND grantee='anon' AND privilege_type='SELECT') AS tablas_con_anon_select,
  (SELECT count(*) FROM dymaerp.modulos WHERE slug IN ('remision','recepcion')) AS modulos_nuevos_de_2;
