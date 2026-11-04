-- =============================================================================
-- DYMA ERP — Estado de resultado: cuentas de gasto, módulo y costo del lote
-- =============================================================================
-- Ejecutar DESPUÉS de 24_cuota_entrega_inicial.sql.
--
-- Para que el estado de resultado mensual cuadre hacen falta tres cosas que hoy
-- faltan:
--
--   1) Que el módulo Gastos esté habilitado. Existe en el código, pero nunca se
--      le asignó a DYMA: hoy no hay dónde cargar un gasto.
--
--   2) Que la cuenta del gasto salga de una lista cerrada. Hoy es texto libre,
--      así que "SUELDOS Y JORNALES", "Sueldos" y "SUELDO" serían tres renglones
--      distintos en el reporte y ninguno sumaría con el otro.
--
--   3) Un costo por lote. Las columnas Costo y Utilidad del modelo no se pueden
--      calcular con el precio de venta solo.
--
-- La columna vieja `gastos.categoria` NO se borra: queda como respaldo de lo que
-- se escribió a mano, y los gastos que ya existan se migran a la cuenta que les
-- corresponda, creándola si hace falta. Borrarla perdería datos sin necesidad.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Catálogo de cuentas de gasto
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.gasto_cuentas (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  -- Código del plan de cuentas. Ordena el reporte y sobrevive a un cambio de
  -- nombre: si mañana "INTERÉS" pasa a "INTERESES BANCARIOS", los gastos ya
  -- cargados siguen colgando de la misma cuenta.
  codigo text NOT NULL,
  nombre text NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'gasto_cuentas_pkey'
      AND conrelid = 'dymaerp.gasto_cuentas'::regclass
  ) THEN
    ALTER TABLE dymaerp.gasto_cuentas ADD CONSTRAINT gasto_cuentas_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.gasto_cuentas ADD CONSTRAINT gasto_cuentas_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.gasto_cuentas ADD CONSTRAINT gasto_cuentas_codigo_uq
      UNIQUE (empresa_id, codigo);
    ALTER TABLE dymaerp.gasto_cuentas ADD CONSTRAINT gasto_cuentas_nombre_uq
      UNIQUE (empresa_id, nombre);
    ALTER TABLE dymaerp.gasto_cuentas ADD CONSTRAINT gasto_cuentas_codigo_check
      CHECK (btrim(codigo) <> '');
    ALTER TABLE dymaerp.gasto_cuentas ADD CONSTRAINT gasto_cuentas_nombre_check
      CHECK (btrim(nombre) <> '');
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_gasto_cuentas_empresa
  ON dymaerp.gasto_cuentas USING btree (empresa_id, activo, orden);

COMMENT ON TABLE dymaerp.gasto_cuentas IS
  'Plan de cuentas de gasto. Cada renglón del estado de resultado es una de estas cuentas.';

-- ---------------------------------------------------------------------------
-- 2) Las cuentas del modelo que trajo el cliente
-- ---------------------------------------------------------------------------
-- Se insertan solo si faltan y no se pisan: si alguien renombró una cuenta o
-- cambió su orden, correr el script de nuevo no le deshace el cambio.
INSERT INTO dymaerp.gasto_cuentas (empresa_id, codigo, nombre, orden)
SELECT '06255def-3835-4d37-8f7f-801af8043e8c', v.codigo, v.nombre, v.orden
FROM (VALUES
  ('510', 'ANTICIPO A LA RENTA',                 10),
  ('515', 'ARTÍCULOS DE LIMPIEZA',               20),
  ('520', 'COMBUSTIBLE Y LUBRICANTES',           30),
  ('525', 'CONSUMICIÓN',                         40),
  ('530', 'DESCUENTOS',                          50),
  ('535', 'ENCOMIENDAS Y CORREOS',               60),
  ('540', 'EQUIPOS DE OFICINA',                  70),
  ('545', 'FLETES Y ACARREOS',                   80),
  ('550', 'GASTOS VARIOS',                       90),
  ('555', 'HONORARIOS PROFESIONALES',           100),
  ('560', 'INTERÉS',                            110),
  ('565', 'IPS',                                120),
  ('570', 'LAVADO Y ENGRASE',                   130),
  ('575', 'LUZ, AGUA Y TELÉFONO',               140),
  ('580', 'MANTENIMIENTO Y REPARACIÓN DE RODADOS', 150),
  ('585', 'PAPELES E IMPRESOS',                 160),
  ('590', 'PUBLICIDAD Y PROPAGANDA',            170),
  ('595', 'SUELDOS Y JORNALES',                 180)
) AS v(codigo, nombre, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM dymaerp.gasto_cuentas g
  WHERE g.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
    AND (g.codigo = v.codigo OR g.nombre = v.nombre)
);

-- ---------------------------------------------------------------------------
-- 3) El gasto cuelga de una cuenta
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.gastos ADD COLUMN IF NOT EXISTS cuenta_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'gastos_cuenta_id_fkey'
      AND conrelid = 'dymaerp.gastos'::regclass
  ) THEN
    -- RESTRICT: una cuenta con gastos cargados no se borra; se marca inactiva.
    ALTER TABLE dymaerp.gastos ADD CONSTRAINT gastos_cuenta_id_fkey
      FOREIGN KEY (cuenta_id) REFERENCES dymaerp.gasto_cuentas(id) ON DELETE RESTRICT;
  END IF;
END $$;

-- El reporte entra por empresa y rango de fechas.
CREATE INDEX IF NOT EXISTS ix_gastos_empresa_fecha
  ON dymaerp.gastos USING btree (empresa_id, fecha);

COMMENT ON COLUMN dymaerp.gastos.cuenta_id IS
  'Cuenta del plan de gastos. Null = gasto viejo sin clasificar; el reporte lo junta en "Sin clasificar".';
COMMENT ON COLUMN dymaerp.gastos.categoria IS
  'Texto libre heredado, previo al plan de cuentas. Se conserva como respaldo; lo que manda es cuenta_id.';

-- ---------------------------------------------------------------------------
-- 4) Migrar los gastos que ya estaban cargados a mano
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_empresa uuid := '06255def-3835-4d37-8f7f-801af8043e8c';
  r RECORD;
  v_id uuid;
  v_orden integer;
BEGIN
  FOR r IN
    SELECT DISTINCT btrim(categoria) AS nombre
    FROM dymaerp.gastos
    WHERE empresa_id = v_empresa AND cuenta_id IS NULL AND btrim(coalesce(categoria, '')) <> ''
  LOOP
    -- ¿Ya hay una cuenta que se llame así? (sin distinguir mayúsculas)
    SELECT id INTO v_id FROM dymaerp.gasto_cuentas
     WHERE empresa_id = v_empresa AND upper(nombre) = upper(r.nombre) LIMIT 1;

    IF v_id IS NULL THEN
      -- Cuenta nueva al final, con código propio: lo que se escribió a mano no
      -- se pierde ni se fuerza dentro de una cuenta del modelo que no es.
      SELECT coalesce(max(orden), 0) + 10 INTO v_orden
        FROM dymaerp.gasto_cuentas WHERE empresa_id = v_empresa;
      INSERT INTO dymaerp.gasto_cuentas (empresa_id, codigo, nombre, orden)
      VALUES (v_empresa, 'M' || lpad(v_orden::text, 3, '0'), upper(r.nombre), v_orden)
      RETURNING id INTO v_id;
    END IF;

    UPDATE dymaerp.gastos
       SET cuenta_id = v_id
     WHERE empresa_id = v_empresa AND cuenta_id IS NULL AND upper(btrim(categoria)) = upper(r.nombre);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 5) Costo del lote, para la columna Costo del reporte
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.lotes ADD COLUMN IF NOT EXISTS costo_adquisicion numeric;

COMMENT ON COLUMN dymaerp.lotes.costo_adquisicion IS
  'Lo que le costó el lote a la empresa: terreno, mensura, calles, servicios. Alimenta Costo y Utilidad del estado de resultado. Null = todavía sin cargar, el reporte lo cuenta como cero y lo avisa.';

-- ---------------------------------------------------------------------------
-- 6) RLS y permisos del catálogo
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.gasto_cuentas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS gasto_cuentas_select ON dymaerp.gasto_cuentas;
DROP POLICY IF EXISTS gasto_cuentas_insert ON dymaerp.gasto_cuentas;
DROP POLICY IF EXISTS gasto_cuentas_update ON dymaerp.gasto_cuentas;
DROP POLICY IF EXISTS gasto_cuentas_delete ON dymaerp.gasto_cuentas;

CREATE POLICY gasto_cuentas_select ON dymaerp.gasto_cuentas
  AS PERMISSIVE FOR SELECT TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gasto_cuentas_insert ON dymaerp.gasto_cuentas
  AS PERMISSIVE FOR INSERT TO PUBLIC
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gasto_cuentas_update ON dymaerp.gasto_cuentas
  AS PERMISSIVE FOR UPDATE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gasto_cuentas_delete ON dymaerp.gasto_cuentas
  AS PERMISSIVE FOR DELETE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.gasto_cuentas TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE dymaerp.gasto_cuentas TO anon, service_role;

DROP TRIGGER IF EXISTS trg_gasto_cuentas_updated ON dymaerp.gasto_cuentas;
CREATE TRIGGER trg_gasto_cuentas_updated
  BEFORE UPDATE ON dymaerp.gasto_cuentas
  FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();

-- ---------------------------------------------------------------------------
-- 7) Habilitar el módulo Gastos para DYMA
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_empresa uuid := '06255def-3835-4d37-8f7f-801af8043e8c';
  v_modulo uuid;
BEGIN
  SELECT id INTO v_modulo FROM dymaerp.modulos WHERE slug = 'gastos';
  IF v_modulo IS NULL THEN
    RAISE EXCEPTION 'No existe el módulo con slug "gastos" en dymaerp.modulos';
  END IF;

  IF EXISTS (
    SELECT 1 FROM dymaerp.empresa_modulos
    WHERE empresa_id = v_empresa AND modulo_id = v_modulo
  ) THEN
    UPDATE dymaerp.empresa_modulos SET activo = true
     WHERE empresa_id = v_empresa AND modulo_id = v_modulo;
  ELSE
    INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
    VALUES (v_empresa, v_modulo, true);
  END IF;
END $$;

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve la tabla ni las
-- columnas nuevas y responde 404 aunque existan.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT 'cuentas de gasto' AS dato, count(*)::text AS valor
FROM dymaerp.gasto_cuentas WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
UNION ALL
SELECT 'gastos sin clasificar', count(*)::text
FROM dymaerp.gastos WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND cuenta_id IS NULL
UNION ALL
SELECT 'modulo Gastos activo', coalesce((
  SELECT em.activo::text FROM dymaerp.empresa_modulos em
  JOIN dymaerp.modulos m ON m.id = em.modulo_id
  WHERE em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND m.slug = 'gastos'
), 'no asignado')
UNION ALL
SELECT 'lotes con costo cargado', count(*)::text
FROM dymaerp.lotes
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c' AND costo_adquisicion IS NOT NULL;
