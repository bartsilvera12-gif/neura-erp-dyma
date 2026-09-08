-- =============================================================================
-- DYMA ERP — Factura autoimpresor (media hoja, 8,5" x 5,5")
-- =============================================================================
-- Ejecutar DESPUÉS de 13_venta_contado.sql.
--
-- Hoy la factura se llena a mano sobre el talonario preimpreso. Autoimpresor es
-- lo contrario: el ERP imprime TODO sobre papel en blanco — membrete, timbrado,
-- número y detalle. Para eso hacen falta dos cosas que la base todavía no tiene:
--
--   1) Los datos del emisor y del timbrado, para poder imprimirlos.
--   2) Un registro de qué número le tocó a cada factura, porque el número
--      fiscal se asigna una sola vez y no se puede repetir ni reusar.
--
-- El punto 2 va en tabla propia y no en `facturas`: el número fiscal es un acto
-- de emisión con su propia fecha, su propio timbrado vigente y su propio corte
-- de IVA congelado. Si mañana se corrige el importe de la factura, lo emitido
-- sigue siendo lo que se le entregó al cliente.
--
-- `factura_autoimpresor` (que ya existe) NO sirve acá: cuelga de `ventas`, el
-- módulo POS que DYMA no usa. Esta tabla cuelga de `facturas`.
--
-- IMPORTANTE — el timbrado que se carga acá es el que figura en el talonario
-- preimpreso. Imprimir por autoimpresor requiere una autorización distinta de
-- la SET, con su propio número y su propio rango habilitado. Antes de emitir en
-- producción hay que reemplazar timbrado, vigencia y rango por los autorizados.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Datos del emisor que van impresos en la cabecera
-- ---------------------------------------------------------------------------
-- La tabla ya existe (viene del schema base). Solo falta el rubro, que en el
-- talonario de DYMA ocupa dos líneas al lado del logo.
ALTER TABLE dymaerp.empresa_autoimpresor_config
  ADD COLUMN IF NOT EXISTS actividad_economica text;

COMMENT ON COLUMN dymaerp.empresa_autoimpresor_config.actividad_economica IS
  'Rubro tal como debe salir impreso bajo la razón social. Se acepta más de una línea separada por saltos.';

INSERT INTO dymaerp.empresa_autoimpresor_config (
  empresa_id, activo,
  ruc_emisor, razon_social_emisor, nombre_fantasia, actividad_economica,
  direccion_matriz, telefono,
  timbrado_numero, timbrado_inicio_vigencia, timbrado_fin_vigencia,
  establecimiento_codigo, punto_expedicion_codigo,
  numero_inicial, numero_final, numero_actual,
  tipo_documento_default, formato_impresion_default,
  observaciones
)
SELECT
  '06255def-3835-4d37-8f7f-801af8043e8c', true,
  '80149103-7', 'CORPORACION DYMA S.A.', 'DYMA INMOBILIARIA',
  E'INVERSORES DE EMPRENDIMIENTOS INMOBILIARIOS\nACTIVIDADES INMOBILIARIAS REALIZADAS CON BIENES PROPIOS O ARRENDADOS',
  E'Av. Monday a 150 metros de la Ruta 2 — Barrio San Juan\nJuan E. O''Leary - Alto Paraná - Paraguay',
  '(0976) 606 960',
  '18667879', DATE '2026-02-20', DATE '2027-02-28',
  '001', '001',
  1, 9999999, 0,
  'factura', 'pdf_media_hoja',
  'Timbrado tomado del talonario preimpreso. Reemplazar por el timbrado y rango autorizados para autoimpresor antes de emitir.'
WHERE NOT EXISTS (
  SELECT 1 FROM dymaerp.empresa_autoimpresor_config
  WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
);

-- ---------------------------------------------------------------------------
-- 2) El número fiscal de cada factura emitida
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.factura_timbrado (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  factura_id uuid NOT NULL,
  -- Solo el correlativo: 7 en "001-001-0000007".
  numero_secuencia integer NOT NULL,
  numero_completo text NOT NULL,
  establecimiento_codigo text NOT NULL,
  punto_expedicion_codigo text NOT NULL,
  -- Timbrado vigente al emitir, copiado y no referenciado: cuando venza y se
  -- cargue el siguiente, lo ya impreso tiene que seguir mostrando el viejo.
  timbrado_numero text NOT NULL,
  timbrado_inicio_vigencia date,
  timbrado_fin_vigencia date,
  condicion text DEFAULT 'contado' NOT NULL,
  -- Corte de IVA congelado al emitir.
  gravado_10 numeric DEFAULT 0 NOT NULL,
  iva_10 numeric DEFAULT 0 NOT NULL,
  gravado_5 numeric DEFAULT 0 NOT NULL,
  iva_5 numeric DEFAULT 0 NOT NULL,
  exentas numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  emitida_at timestamp with time zone DEFAULT now() NOT NULL,
  emitida_por uuid,
  emitida_por_email text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'factura_timbrado_pkey'
      AND conrelid = 'dymaerp.factura_timbrado'::regclass
  ) THEN
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_factura_id_fkey
      FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE RESTRICT;
    -- Una factura se emite una sola vez.
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_factura_uq
      UNIQUE (factura_id);
    -- Y un número se usa una sola vez. Esta es la barrera real contra el
    -- duplicado: si dos personas emiten a la vez, una de las dos rebota y
    -- vuelve a pedir número.
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_numero_uq
      UNIQUE (empresa_id, timbrado_numero, establecimiento_codigo, punto_expedicion_codigo, numero_secuencia);
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_condicion_check
      CHECK (condicion IN ('contado', 'credito'));
    ALTER TABLE dymaerp.factura_timbrado ADD CONSTRAINT factura_timbrado_secuencia_check
      CHECK (numero_secuencia >= 1);
  END IF;
END $$;

-- Para calcular el próximo número y para el libro de ventas del mes.
CREATE INDEX IF NOT EXISTS ix_factura_timbrado_emision
  ON dymaerp.factura_timbrado USING btree (empresa_id, emitida_at);

COMMENT ON TABLE dymaerp.factura_timbrado IS
  'Número fiscal asignado a cada factura impresa por autoimpresor, con el timbrado y el corte de IVA congelados al momento de emitir.';

-- ---------------------------------------------------------------------------
-- 3) RLS y permisos
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.factura_timbrado ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS factura_timbrado_select ON dymaerp.factura_timbrado;
DROP POLICY IF EXISTS factura_timbrado_insert ON dymaerp.factura_timbrado;

CREATE POLICY factura_timbrado_select ON dymaerp.factura_timbrado
  AS PERMISSIVE FOR SELECT TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_timbrado_insert ON dymaerp.factura_timbrado
  AS PERMISSIVE FOR INSERT TO PUBLIC
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));

-- Sin UPDATE ni DELETE a propósito: un número emitido no se corrige ni se
-- borra. Lo que se hace con una factura mal emitida es anularla.
GRANT SELECT, INSERT ON TABLE dymaerp.factura_timbrado TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE dymaerp.factura_timbrado TO anon, service_role;

GRANT SELECT, INSERT, UPDATE ON TABLE dymaerp.empresa_autoimpresor_config TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE dymaerp.empresa_autoimpresor_config TO anon, service_role;

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve la tabla nueva y
-- responde 404 aunque exista.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT 'timbrado' AS dato, timbrado_numero AS valor
FROM dymaerp.empresa_autoimpresor_config
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
UNION ALL
SELECT 'vigencia', timbrado_inicio_vigencia::text || ' a ' || timbrado_fin_vigencia::text
FROM dymaerp.empresa_autoimpresor_config
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
UNION ALL
SELECT 'punto de expedición', establecimiento_codigo || '-' || punto_expedicion_codigo
FROM dymaerp.empresa_autoimpresor_config
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
UNION ALL
SELECT 'facturas emitidas', count(*)::text
FROM dymaerp.factura_timbrado
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c';
