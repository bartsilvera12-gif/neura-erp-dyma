-- =============================================================================
-- DYMA ERP — objetos extra de los módulos Gerencia y Cobranzas
-- =============================================================================
-- Ejecutar DESPUÉS de 01_schema_dymaerp.sql.
--
-- Instemaq no tiene estos módulos, así que su schema no los trae. Se portan
-- desde `neura` (repo neura-erp-sistemas-propio) al schema propio de DYMA:
--
--   * plan_categoria     — clasifica planes (categoría/naturaleza) para el MRR.
--   * cobranza_promesas  — promesas de pago del seguimiento de cartera.
--   * v_*                — 6 views read-only que alimentan el tablero Gerencia.
--
-- Todo vive dentro de `dymaerp`. No toca public, auth ni ningún otro schema.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) plan_categoria — mapea plan → categoría comercial. Alimenta v_mrr y
--    v_factura_categoria. Sin filas, las views caen al clasificador por texto.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.plan_categoria (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  plan_id uuid,
  categoria text NOT NULL,
  naturaleza text NOT NULL,
  label text,
  activo boolean DEFAULT true,
  created_at timestamp with time zone DEFAULT now(),
  updated_at timestamp with time zone DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'plan_categoria_pkey'
      AND conrelid = 'dymaerp.plan_categoria'::regclass
  ) THEN
    ALTER TABLE dymaerp.plan_categoria ADD CONSTRAINT plan_categoria_pkey PRIMARY KEY (id);
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'plan_categoria_plan_id_fkey'
      AND conrelid = 'dymaerp.plan_categoria'::regclass
  ) THEN
    ALTER TABLE dymaerp.plan_categoria
      ADD CONSTRAINT plan_categoria_plan_id_fkey FOREIGN KEY (plan_id)
      REFERENCES dymaerp.planes(id) ON DELETE CASCADE;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_plan_categoria_plan ON dymaerp.plan_categoria USING btree (plan_id) WHERE activo;

-- ---------------------------------------------------------------------------
-- 2) cobranza_promesas — promesas de pago registradas desde el módulo Cobranzas.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS dymaerp.cobranza_promesas (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  fecha_promesa date NOT NULL,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  creado_por uuid,
  creado_por_email text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'cobranza_promesas_pkey'
      AND conrelid = 'dymaerp.cobranza_promesas'::regclass
  ) THEN
    ALTER TABLE dymaerp.cobranza_promesas ADD CONSTRAINT cobranza_promesas_pkey PRIMARY KEY (id);
    ALTER TABLE dymaerp.cobranza_promesas ADD CONSTRAINT cobranza_promesas_estado_check
      CHECK (estado = ANY (ARRAY['pendiente'::text, 'cumplida'::text, 'cancelada'::text]));
    ALTER TABLE dymaerp.cobranza_promesas ADD CONSTRAINT cobranza_promesas_empresa_id_fkey
      FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.cobranza_promesas ADD CONSTRAINT cobranza_promesas_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
    ALTER TABLE dymaerp.cobranza_promesas ADD CONSTRAINT cobranza_promesas_creado_por_fkey
      FOREIGN KEY (creado_por) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS ix_cobranza_promesas_fecha
  ON dymaerp.cobranza_promesas USING btree (empresa_id, fecha_promesa);
CREATE INDEX IF NOT EXISTS ix_cobranza_promesas_cliente
  ON dymaerp.cobranza_promesas USING btree (empresa_id, cliente_id, estado);

-- ---------------------------------------------------------------------------
-- 3) RLS y permisos — mismo criterio que el resto de `dymaerp`: RLS activo y
--    aislamiento por empresa vía las funciones ya clonadas en 01_.
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.plan_categoria ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cobranza_promesas ENABLE ROW LEVEL SECURITY;

-- Mismo patrón que el resto del schema (ver `facturas`): 4 policies TO PUBLIC
-- filtrando por `puede_acceder_empresa`.
DROP POLICY IF EXISTS cobranza_promesas_select ON dymaerp.cobranza_promesas;
DROP POLICY IF EXISTS cobranza_promesas_insert ON dymaerp.cobranza_promesas;
DROP POLICY IF EXISTS cobranza_promesas_update ON dymaerp.cobranza_promesas;
DROP POLICY IF EXISTS cobranza_promesas_delete ON dymaerp.cobranza_promesas;
CREATE POLICY cobranza_promesas_select ON dymaerp.cobranza_promesas
  AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobranza_promesas_insert ON dymaerp.cobranza_promesas
  AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobranza_promesas_update ON dymaerp.cobranza_promesas
  AS PERMISSIVE FOR UPDATE TO PUBLIC
  USING (dymaerp.puede_acceder_empresa(empresa_id))
  WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobranza_promesas_delete ON dymaerp.cobranza_promesas
  AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));

-- plan_categoria es catálogo sin empresa_id: lectura/escritura para la instancia.
DROP POLICY IF EXISTS plan_categoria_all ON dymaerp.plan_categoria;
CREATE POLICY plan_categoria_all ON dymaerp.plan_categoria
  AS PERMISSIVE FOR ALL TO PUBLIC USING (true) WITH CHECK (true);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.plan_categoria TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.plan_categoria TO anon, service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE dymaerp.cobranza_promesas TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cobranza_promesas TO anon, service_role;

-- ---------------------------------------------------------------------------
-- 4) Views del tablero Gerencia (read-only).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW dymaerp.v_factura_categoria AS
 SELECT f.id AS factura_id,
    f.empresa_id,
    COALESCE(pc.categoria,
        CASE
            WHEN it.d ~* 'contabilidad|contable|plan iva|plan irp|emprendedor|estrategia|tributar'::text THEN 'contabilidad'::text
            WHEN it.d ~* 'erp|sistema|sorteo|informatic|saas|automatiz|bot'::text THEN 'saas_erp'::text
            WHEN it.d ~* 'web|pagina|landing|ecommerce'::text THEN 'web_landing'::text
            WHEN it.d ~* 'branding'::text THEN 'branding'::text
            WHEN it.d ~* 'registro de marca|marca'::text THEN 'otros'::text
            ELSE 'sin_clasificar'::text
        END) AS categoria,
    COALESCE(pc.naturaleza,
        CASE
            WHEN f.tipo = 'suscripcion'::text THEN 'recurrente'::text
            ELSE 'unico'::text
        END) AS naturaleza
   FROM dymaerp.facturas f
     LEFT JOIN dymaerp.suscripciones s ON s.id = f.suscripcion_id
     LEFT JOIN dymaerp.plan_categoria pc ON pc.plan_id = s.plan_id AND pc.activo
     LEFT JOIN LATERAL ( SELECT string_agg(lower(fi.descripcion), ' '::text) AS d
           FROM dymaerp.factura_items fi
          WHERE fi.factura_id = f.id) it ON true;

CREATE OR REPLACE VIEW dymaerp.v_revenue_mensual AS
 WITH fact AS (
         SELECT facturas.empresa_id,
            date_trunc('month'::text, facturas.fecha::timestamp with time zone)::date AS mes,
            count(*) FILTER (WHERE facturas.estado <> 'Anulado'::text) AS facturas_count,
            COALESCE(sum(facturas.monto) FILTER (WHERE facturas.estado <> 'Anulado'::text), 0::numeric) AS facturado_total,
            COALESCE(sum(facturas.saldo) FILTER (WHERE facturas.estado = 'Pendiente'::text), 0::numeric) AS pendiente_total,
            count(*) FILTER (WHERE facturas.estado = 'Pagado'::text) AS facturas_pagadas,
            count(*) FILTER (WHERE facturas.estado = 'Pendiente'::text) AS facturas_pendientes,
            count(*) FILTER (WHERE facturas.estado = 'Anulado'::text) AS facturas_anuladas
           FROM dymaerp.facturas
          GROUP BY facturas.empresa_id, (date_trunc('month'::text, facturas.fecha::timestamp with time zone)::date)
        ), pag AS (
         SELECT pagos.empresa_id,
            date_trunc('month'::text, pagos.fecha_pago::timestamp with time zone)::date AS mes,
            COALESCE(sum(pagos.monto), 0::numeric) AS cobrado_total
           FROM dymaerp.pagos
          GROUP BY pagos.empresa_id, (date_trunc('month'::text, pagos.fecha_pago::timestamp with time zone)::date)
        )
 SELECT COALESCE(f.empresa_id, p.empresa_id) AS empresa_id,
    COALESCE(f.mes, p.mes) AS mes,
    COALESCE(f.facturas_count, 0::bigint) AS facturas_count,
    COALESCE(f.facturado_total, 0::numeric) AS facturado_total,
    COALESCE(p.cobrado_total, 0::numeric) AS cobrado_total,
    COALESCE(f.pendiente_total, 0::numeric) AS pendiente_total,
        CASE
            WHEN COALESCE(f.facturas_count, 0::bigint) > 0 THEN round(f.facturado_total / f.facturas_count::numeric)
            ELSE 0::numeric
        END AS ticket_promedio,
    COALESCE(f.facturas_pagadas, 0::bigint) AS facturas_pagadas,
    COALESCE(f.facturas_pendientes, 0::bigint) AS facturas_pendientes,
    COALESCE(f.facturas_anuladas, 0::bigint) AS facturas_anuladas
   FROM fact f
     FULL JOIN pag p ON f.empresa_id = p.empresa_id AND f.mes = p.mes;

CREATE OR REPLACE VIEW dymaerp.v_revenue_por_categoria AS
 SELECT f.empresa_id,
    date_trunc('month'::text, f.fecha::timestamp with time zone)::date AS mes,
    fc.categoria,
    count(*) AS facturas,
    COALESCE(sum(f.monto), 0::numeric) AS facturado
   FROM dymaerp.facturas f
     JOIN dymaerp.v_factura_categoria fc ON fc.factura_id = f.id
  WHERE f.estado <> 'Anulado'::text
  GROUP BY f.empresa_id, (date_trunc('month'::text, f.fecha::timestamp with time zone)::date), fc.categoria;

CREATE OR REPLACE VIEW dymaerp.v_mrr AS
 SELECT s.empresa_id,
    COALESCE(pc.categoria, 'sin_clasificar'::text) AS categoria,
    count(*) FILTER (WHERE s.estado = 'activa'::text) AS subs_activas,
    COALESCE(sum(s.precio) FILTER (WHERE s.estado = 'activa'::text), 0::numeric) AS mrr,
    count(*) FILTER (WHERE s.estado = 'cancelada'::text) AS subs_canceladas,
    COALESCE(sum(s.precio) FILTER (WHERE s.estado = 'cancelada'::text), 0::numeric) AS mrr_cancelado
   FROM dymaerp.suscripciones s
     LEFT JOIN dymaerp.plan_categoria pc ON pc.plan_id = s.plan_id AND pc.activo
  GROUP BY s.empresa_id, (COALESCE(pc.categoria, 'sin_clasificar'::text));

CREATE OR REPLACE VIEW dymaerp.v_cuentas_por_cobrar AS
 SELECT f.empresa_id,
    f.id AS factura_id,
    f.numero_factura,
    f.cliente_id,
    cl.nombre AS cliente,
    f.monto,
    f.saldo,
    f.fecha,
    f.fecha_vencimiento,
        CASE
            WHEN f.fecha_vencimiento IS NOT NULL THEN GREATEST(0, CURRENT_DATE - f.fecha_vencimiento)
            ELSE NULL::integer
        END AS dias_atraso
   FROM dymaerp.facturas f
     JOIN dymaerp.clientes cl ON cl.id = f.cliente_id
  WHERE f.estado = 'Pendiente'::text;

CREATE OR REPLACE VIEW dymaerp.v_clientes_recurrentes AS
 SELECT f.empresa_id,
    f.cliente_id,
    cl.nombre AS cliente,
    count(DISTINCT date_trunc('month'::text, f.fecha::timestamp with time zone)) AS meses_facturados,
    count(*) AS facturas,
    round(avg(f.monto)) AS monto_promedio,
    max(f.fecha) AS ultimo_mes,
    max(cl.estado) AS estado_cliente,
    mode() WITHIN GROUP (ORDER BY fc.categoria) AS categoria_estimada
   FROM dymaerp.facturas f
     JOIN dymaerp.clientes cl ON cl.id = f.cliente_id
     LEFT JOIN dymaerp.v_factura_categoria fc ON fc.factura_id = f.id
  WHERE f.estado <> 'Anulado'::text
  GROUP BY f.empresa_id, f.cliente_id, cl.nombre
 HAVING count(DISTINCT date_trunc('month'::text, f.fecha::timestamp with time zone)) >= 2;

GRANT SELECT ON dymaerp.v_factura_categoria      TO authenticated, anon, service_role;
GRANT SELECT ON dymaerp.v_revenue_mensual        TO authenticated, anon, service_role;
GRANT SELECT ON dymaerp.v_revenue_por_categoria  TO authenticated, anon, service_role;
GRANT SELECT ON dymaerp.v_mrr                    TO authenticated, anon, service_role;
GRANT SELECT ON dymaerp.v_cuentas_por_cobrar     TO authenticated, anon, service_role;
GRANT SELECT ON dymaerp.v_clientes_recurrentes   TO authenticated, anon, service_role;

COMMIT;
