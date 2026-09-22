-- =============================================================================
-- DYMA ERP — Factura autoimpresor autorizada (modelo Neura A4)
-- =============================================================================
-- Ejecutar DESPUÉS de 13_venta_contado.sql.
--
-- Configuración fiscal oficial según autorización DNIT FORM.350-1 N° 350010038781
-- de fecha 21/09/2026. El timbrado entra en vigencia el 22/09/2026.
--
-- La emisión fiscal y la impresión son actos separados: emitir asigna una sola
-- vez el correlativo autorizado; reimprimir no consume otro número.
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
VALUES (
  '06255def-3835-4d37-8f7f-801af8043e8c', false,
  '80149103-7', 'CORPORACION DYMA S.A.', 'DYMA INMOBILIARIA',
  E'INVERSORES DE EMPRENDIMIENTOS INMOBILIARIOS\nACTIVIDADES INMOBILIARIAS REALIZADAS CON BIENES PROPIOS O ARRENDADOS',
  E'AV. LA RESIDENTA A UNA CUADRA Y MEDIA DE LA COMISARIA\nJUAN E. O''LEARY - ALTO PARANÁ - PARAGUAY',
  '0976 606960',
  '19139705', DATE '2026-09-22', DATE '2027-09-30',
  '003', '002',
  1, 5000, 1,
  'factura', 'pdf_a4',
  'Datos cargados desde FORM.350-1 N° 350010038781, fecha 21/09/2026. Rango 003-002-0000001 a 003-002-0005000. Emisión bloqueada hasta confirmar con DNIT/contador el uso desde Neura, ya que la autorización identifica FLEX PDV como software.'
)
ON CONFLICT (empresa_id) DO UPDATE SET
  activo = EXCLUDED.activo,
  ruc_emisor = EXCLUDED.ruc_emisor,
  razon_social_emisor = EXCLUDED.razon_social_emisor,
  nombre_fantasia = EXCLUDED.nombre_fantasia,
  actividad_economica = EXCLUDED.actividad_economica,
  direccion_matriz = EXCLUDED.direccion_matriz,
  telefono = EXCLUDED.telefono,
  timbrado_numero = EXCLUDED.timbrado_numero,
  timbrado_inicio_vigencia = EXCLUDED.timbrado_inicio_vigencia,
  timbrado_fin_vigencia = EXCLUDED.timbrado_fin_vigencia,
  establecimiento_codigo = EXCLUDED.establecimiento_codigo,
  punto_expedicion_codigo = EXCLUDED.punto_expedicion_codigo,
  numero_inicial = EXCLUDED.numero_inicial,
  numero_final = EXCLUDED.numero_final,
  numero_actual = EXCLUDED.numero_actual,
  tipo_documento_default = EXCLUDED.tipo_documento_default,
  formato_impresion_default = EXCLUDED.formato_impresion_default,
  observaciones = EXCLUDED.observaciones,
  updated_at = now();

-- El modo fiscal de DYMA queda en autoimpresor y el formato provisional es A4.
INSERT INTO dymaerp.empresa_facturacion_modo (
  empresa_id, modo, impresion_tipo_default, imprimir_al_confirmar,
  preguntar_datos_al_confirmar, activo
)
VALUES (
  '06255def-3835-4d37-8f7f-801af8043e8c',
  'autoimpresor', 'pdf_a4', false, false, true
)
ON CONFLICT (empresa_id) DO UPDATE SET
  modo = EXCLUDED.modo,
  impresion_tipo_default = EXCLUDED.impresion_tipo_default,
  activo = true,
  updated_at = now();

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
