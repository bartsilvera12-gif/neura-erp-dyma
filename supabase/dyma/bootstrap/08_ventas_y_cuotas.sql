-- =============================================================================
-- DYMA ERP — Venta de lotes, contrato y plan de cuotas (fase 2)
-- =============================================================================
-- Ejecutar DESPUÉS de 07_modulo_lotes.sql.
--
-- Modelo:
--   lote_ventas            → el contrato de compraventa de un lote
--   lote_venta_codeudores  → codeudores del contrato (además del titular)
--   lote_venta_cuotas      → el plan de pago generado
--
-- Las condiciones del financiamiento (recargo, mora, gracia) se CONGELAN en el
-- contrato en vez de leerse de una configuración global. Si mañana cambia la
-- política, los contratos viejos siguen calculando con lo que se firmó.
--
-- Reglas confirmadas por el cliente:
--   - Recargo 15% sobre el capital (contado − entrega), en cuotas iguales.
--   - Mora 5% diario acumulativo: 1,7% administrativo + 3,3% moratorio.
--   - 5 días de gracia; la mora corre desde el sexto día de atraso.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Contrato de compraventa
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.lote_ventas (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  lote_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  numero_contrato text NOT NULL,
  fecha_venta date NOT NULL,
  -- Precio congelado al momento de vender: el de lista puede cambiar después.
  precio_contado numeric NOT NULL,
  entrega_inicial numeric DEFAULT 0 NOT NULL,
  capital numeric NOT NULL,
  interes_total numeric NOT NULL,
  monto_financiado numeric NOT NULL,
  cantidad_cuotas integer NOT NULL,
  primer_vencimiento date NOT NULL,
  moneda text DEFAULT 'GS'::text NOT NULL,
  -- Condiciones congeladas del financiamiento.
  recargo_pct numeric DEFAULT 0.15 NOT NULL,
  dias_gracia integer DEFAULT 5 NOT NULL,
  mora_administrativa_pct numeric DEFAULT 0.017 NOT NULL,
  mora_moratoria_pct numeric DEFAULT 0.033 NOT NULL,
  -- vigente | cancelada (pagada por completo) | anulada
  estado text DEFAULT 'vigente'::text NOT NULL,
  anulada_motivo text,
  observacion text,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 2) Codeudores del contrato
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.lote_venta_codeudores (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  observacion text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 3) Cuotas del plan
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.lote_venta_cuotas (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  numero integer NOT NULL,
  vencimiento date NOT NULL,
  capital numeric NOT NULL,
  interes numeric NOT NULL,
  total numeric NOT NULL,
  -- Lo que falta cobrar de esta cuota. Admite pagos parciales.
  saldo numeric NOT NULL,
  -- pendiente | pagada | anulada
  estado text DEFAULT 'pendiente'::text NOT NULL,
  -- Factura emitida por esta cuota (facturación por cuota).
  factura_id uuid,
  pagada_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

-- ---------------------------------------------------------------------------
-- 4) Claves, unicidad y reglas
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_pkey'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    -- RESTRICT: un lote con contrato no se borra por accidente desde la estructura.
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_lote_id_fkey
      FOREIGN KEY (lote_id) REFERENCES dymaerp.lotes(id) ON DELETE RESTRICT;
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE RESTRICT;
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_numero_uq
      UNIQUE (empresa_id, numero_contrato);
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_estado_check
      CHECK (estado = ANY (ARRAY['vigente'::text, 'cancelada'::text, 'anulada'::text]));
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_moneda_check
      CHECK (moneda = ANY (ARRAY['GS'::text, 'USD'::text]));
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_montos_check
      CHECK (precio_contado > 0 AND entrega_inicial >= 0 AND entrega_inicial < precio_contado
         AND capital > 0 AND interes_total >= 0 AND monto_financiado > 0
         AND cantidad_cuotas >= 1);
    -- Coherencia aritmética del contrato: si esto se viola, el plan no cierra.
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_aritmetica_check
      CHECK (capital = precio_contado - entrega_inicial
         AND monto_financiado = capital + interes_total);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_venta_codeudores_pkey'
      AND conrelid = 'dymaerp.lote_venta_codeudores'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_venta_codeudores ADD CONSTRAINT lote_venta_codeudores_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.lote_venta_codeudores ADD CONSTRAINT lote_venta_codeudores_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.lote_venta_codeudores ADD CONSTRAINT lote_venta_codeudores_venta_id_fkey
      FOREIGN KEY (venta_id) REFERENCES dymaerp.lote_ventas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.lote_venta_codeudores ADD CONSTRAINT lote_venta_codeudores_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE RESTRICT;
    ALTER TABLE dymaerp.lote_venta_codeudores ADD CONSTRAINT lote_venta_codeudores_uq
      UNIQUE (venta_id, cliente_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_venta_cuotas_pkey'
      AND conrelid = 'dymaerp.lote_venta_cuotas'::regclass
  ) THEN
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_venta_id_fkey
      FOREIGN KEY (venta_id) REFERENCES dymaerp.lote_ventas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_factura_id_fkey
      FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE SET NULL;
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_numero_uq
      UNIQUE (venta_id, numero);
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_estado_check
      CHECK (estado = ANY (ARRAY['pendiente'::text, 'pagada'::text, 'anulada'::text]));
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_montos_check
      CHECK (total > 0 AND capital >= 0 AND interes >= 0
         AND capital + interes = total
         AND saldo >= 0 AND saldo <= total);
    -- Una cuota pagada no puede quedar con saldo, y una con saldo no puede estar pagada.
    ALTER TABLE dymaerp.lote_venta_cuotas ADD CONSTRAINT lote_venta_cuotas_saldo_estado_check
      CHECK ((estado = 'pagada' AND saldo = 0) OR estado <> 'pagada');
  END IF;
END $$;

-- Un lote no puede tener dos contratos vigentes al mismo tiempo. Índice parcial:
-- los contratos anulados o cancelados no bloquean una venta nueva.
CREATE UNIQUE INDEX IF NOT EXISTS uq_lote_venta_vigente
  ON dymaerp.lote_ventas (lote_id) WHERE estado = 'vigente';

CREATE INDEX IF NOT EXISTS ix_lote_ventas_cliente
  ON dymaerp.lote_ventas USING btree (empresa_id, cliente_id);
CREATE INDEX IF NOT EXISTS ix_lote_ventas_estado
  ON dymaerp.lote_ventas USING btree (empresa_id, estado, fecha_venta DESC);
CREATE INDEX IF NOT EXISTS ix_cuotas_venta
  ON dymaerp.lote_venta_cuotas USING btree (venta_id, numero);
-- Alimenta el listado de mora y la proyección de cobros.
CREATE INDEX IF NOT EXISTS ix_cuotas_pendientes
  ON dymaerp.lote_venta_cuotas USING btree (empresa_id, vencimiento)
  WHERE estado = 'pendiente';
CREATE INDEX IF NOT EXISTS ix_codeudores_venta
  ON dymaerp.lote_venta_codeudores USING btree (venta_id);

COMMENT ON TABLE dymaerp.lote_ventas IS
  'Contrato de compraventa de un lote. Congela precio y condiciones de financiamiento: si cambia la política, los contratos firmados no se alteran.';
COMMENT ON COLUMN dymaerp.lote_ventas.recargo_pct IS
  'Recargo por financiar, sobre el capital (precio_contado - entrega_inicial). Default 0.15.';
COMMENT ON COLUMN dymaerp.lote_ventas.dias_gracia IS
  'Días de atraso sin mora. Con 5, la mora corre desde el sexto día.';
COMMENT ON TABLE dymaerp.lote_venta_cuotas IS
  'Plan de pago. Cada cuota puede emitir su propia factura (factura_id) al momento del cobro.';

-- ---------------------------------------------------------------------------
-- 5) updated_at automático
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lote_ventas','lote_venta_cuotas'] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS trg_%s_updated ON dymaerp.%I', t, t);
    EXECUTE format(
      'CREATE TRIGGER trg_%s_updated BEFORE UPDATE ON dymaerp.%I FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at()',
      t, t);
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------
-- 6) RLS y permisos
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['lote_ventas','lote_venta_codeudores','lote_venta_cuotas'] LOOP
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

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve las tablas recien
-- creadas y responde 404 aunque existan.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT table_name
FROM information_schema.tables
WHERE table_schema = 'dymaerp'
  AND table_name IN ('lote_ventas', 'lote_venta_codeudores', 'lote_venta_cuotas')
ORDER BY table_name;
