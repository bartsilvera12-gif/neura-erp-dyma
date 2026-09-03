-- =============================================================================
-- DYMA ERP — Simulador de plan de pago
-- =============================================================================
-- Ejecutar DESPUÉS de 09_vendedores_y_comisiones.sql.
--
-- Qué agrega:
--   plan_simulaciones            → historial de propuestas de pago por cliente
--   lote_ventas.simulacion_id    → qué simulación terminó siendo el contrato
--
-- El simulador es una herramienta de análisis: se prueban cuantas propuestas
-- haga falta antes de firmar. Por eso la tabla guarda el resultado calculado
-- (cuota, cantidad, monto financiado) y no solo los datos de entrada: lo que se
-- le mostró y prometió al cliente tiene que quedar tal cual, aunque mañana
-- cambie el motor de cálculo o el recargo estándar.
--
-- Las cuotas NO se guardan una por una: se regeneran del mismo motor cuando se
-- abre la simulación. Solo el contrato firmado materializa cuotas.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) Historial de simulaciones
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.plan_simulaciones (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  -- Para quién se simuló. Se puede simular sin cliente todavía (consulta suelta).
  cliente_id uuid,
  -- Sobre qué lote. Sin lote no se puede generar el contrato, pero sí simular.
  lote_id uuid,
  -- Etiqueta libre: "Propuesta 1", "Contrapropuesta del cliente".
  nombre text,

  -- Entrada
  precio_contado numeric NOT NULL,
  entrega_inicial numeric DEFAULT 0 NOT NULL,
  recargo_pct numeric DEFAULT 0.15 NOT NULL,
  frecuencia text DEFAULT 'mensual'::text NOT NULL,
  primer_vencimiento date NOT NULL,
  -- 'por_cuota' = el cliente propuso cuánto puede pagar y el sistema dedujo
  -- cuántas cuotas; 'por_cantidad' = al revés.
  modo text DEFAULT 'por_cantidad'::text NOT NULL,
  cuota_propuesta numeric,

  -- Resultado calculado, congelado tal como se le mostró al cliente
  capital numeric NOT NULL,
  interes_total numeric NOT NULL,
  monto_financiado numeric NOT NULL,
  cantidad_cuotas integer NOT NULL,
  cuota numeric NOT NULL,
  cuota_final numeric NOT NULL,
  ultimo_vencimiento date NOT NULL,

  observacion text,
  -- borrador | descartada | aprobada
  estado text DEFAULT 'borrador'::text NOT NULL,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'plan_simulaciones_pkey'
      AND conrelid = 'dymaerp.plan_simulaciones'::regclass
  ) THEN
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    -- CASCADE: una simulación no es un documento contable; si se va el cliente,
    -- su historial de propuestas se va con él.
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_lote_id_fkey
      FOREIGN KEY (lote_id) REFERENCES dymaerp.lotes(id) ON DELETE SET NULL;

    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_estado_check
      CHECK (estado = ANY (ARRAY['borrador'::text, 'descartada'::text, 'aprobada'::text]));
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_modo_check
      CHECK (modo = ANY (ARRAY['por_cuota'::text, 'por_cantidad'::text]));
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_frecuencia_check
      CHECK (frecuencia = ANY (ARRAY['quincenal'::text, 'mensual'::text, 'bimestral'::text,
                                     'trimestral'::text, 'semestral'::text, 'anual'::text]));
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_recargo_check
      CHECK (recargo_pct >= 0 AND recargo_pct <= 1);
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_montos_check
      CHECK (precio_contado > 0 AND entrega_inicial >= 0 AND entrega_inicial < precio_contado
         AND capital > 0 AND interes_total >= 0 AND monto_financiado > 0
         AND cantidad_cuotas >= 1 AND cuota > 0 AND cuota_final > 0);
    -- La misma coherencia que exige el contrato: si esto no cierra, el plan que
    -- se le mostró al cliente estaba mal.
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_aritmetica_check
      CHECK (capital = precio_contado - entrega_inicial
         AND monto_financiado = capital + interes_total);
    -- En modo por_cuota tiene que constar qué pidió el cliente.
    ALTER TABLE dymaerp.plan_simulaciones ADD CONSTRAINT plan_simulaciones_propuesta_check
      CHECK (modo <> 'por_cuota' OR (cuota_propuesta IS NOT NULL AND cuota_propuesta > 0));
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_plan_simulaciones_cliente
  ON dymaerp.plan_simulaciones USING btree (empresa_id, cliente_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_plan_simulaciones_lote
  ON dymaerp.plan_simulaciones USING btree (empresa_id, lote_id)
  WHERE lote_id IS NOT NULL;

COMMENT ON TABLE dymaerp.plan_simulaciones IS
  'Propuestas de plan de pago probadas antes de firmar. Guarda el resultado calculado, no solo la entrada: lo que se le mostró al cliente no debe cambiar si mañana cambia el motor.';
COMMENT ON COLUMN dymaerp.plan_simulaciones.estado IS
  'borrador = en análisis; descartada = no prosperó; aprobada = se convirtió en contrato.';

-- ---------------------------------------------------------------------------
-- 2) El contrato recuerda de qué simulación salió
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.lote_ventas ADD COLUMN IF NOT EXISTS simulacion_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'lote_ventas_simulacion_id_fkey'
      AND conrelid = 'dymaerp.lote_ventas'::regclass
  ) THEN
    -- SET NULL: si se limpia el historial de simulaciones, el contrato queda igual.
    ALTER TABLE dymaerp.lote_ventas ADD CONSTRAINT lote_ventas_simulacion_id_fkey
      FOREIGN KEY (simulacion_id) REFERENCES dymaerp.plan_simulaciones(id) ON DELETE SET NULL;
  END IF;
END $$;

-- Una simulación no puede haber generado dos contratos.
CREATE UNIQUE INDEX IF NOT EXISTS uq_lote_ventas_simulacion
  ON dymaerp.lote_ventas (simulacion_id) WHERE simulacion_id IS NOT NULL;

COMMENT ON COLUMN dymaerp.lote_ventas.simulacion_id IS
  'Simulación aprobada que dio origen al contrato. Null = contrato cargado directo, sin pasar por el simulador.';

-- ---------------------------------------------------------------------------
-- 3) updated_at automático
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_plan_simulaciones_updated ON dymaerp.plan_simulaciones;
CREATE TRIGGER trg_plan_simulaciones_updated
  BEFORE UPDATE ON dymaerp.plan_simulaciones
  FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4) RLS y permisos
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.plan_simulaciones ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS plan_simulaciones_select ON dymaerp.plan_simulaciones;
DROP POLICY IF EXISTS plan_simulaciones_insert ON dymaerp.plan_simulaciones;
DROP POLICY IF EXISTS plan_simulaciones_update ON dymaerp.plan_simulaciones;
DROP POLICY IF EXISTS plan_simulaciones_delete ON dymaerp.plan_simulaciones;

CREATE POLICY plan_simulaciones_select ON dymaerp.plan_simulaciones
  AS PERMISSIVE FOR SELECT TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY plan_simulaciones_insert ON dymaerp.plan_simulaciones
  AS PERMISSIVE FOR INSERT TO PUBLIC
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY plan_simulaciones_update ON dymaerp.plan_simulaciones
  AS PERMISSIVE FOR UPDATE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY plan_simulaciones_delete ON dymaerp.plan_simulaciones
  AS PERMISSIVE FOR DELETE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id));

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.plan_simulaciones TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE dymaerp.plan_simulaciones TO anon, service_role;

COMMIT;

-- PostgREST cachea el esquema al arrancar: sin esto no ve la tabla ni la columna
-- nueva y responde 404 aunque existan.
NOTIFY pgrst, 'reload schema';

-- Verificación.
SELECT 'plan_simulaciones' AS objeto, count(*)::text AS detalle
FROM information_schema.tables
WHERE table_schema = 'dymaerp' AND table_name = 'plan_simulaciones'
UNION ALL
SELECT 'lote_ventas.simulacion_id', data_type
FROM information_schema.columns
WHERE table_schema = 'dymaerp' AND table_name = 'lote_ventas' AND column_name = 'simulacion_id'
ORDER BY 1;
