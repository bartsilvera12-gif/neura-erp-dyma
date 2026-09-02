-- =============================================================================
-- DYMA ERP - clon exacto del schema `instemaq` como `dymaerp` (ESTRUCTURA, SIN DATOS)
-- Generado desde la base viva. No toca public, auth ni ningun otro schema.
-- =============================================================================

BEGIN;

-- En instemaq todo pertenece a supabase_admin. Se asume el mismo rol para que el
-- clon quede con identico owner y con los mismos grantors en los GRANT.
SET LOCAL ROLE supabase_admin;

CREATE SCHEMA IF NOT EXISTS dymaerp;

-- Las funciones se crean antes que las tablas porque constraints, indices y
-- policies las invocan. Los cuerpos se validan recien al ejecutarse.
SET LOCAL check_function_bodies = false;

-- ---------------------------------------------------------------------------
-- 0) FUNCIONES (33)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION dymaerp._ensure_categoria(p_empresa uuid, p_nombre text, p_codigo text, p_parent uuid)
 RETURNS uuid
 LANGUAGE plpgsql
AS $function$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM dymaerp.categorias_productos
    WHERE empresa_id = p_empresa AND nombre = p_nombre;
  IF v_id IS NULL THEN
    INSERT INTO dymaerp.categorias_productos (empresa_id, nombre, codigo, parent_id, activo)
    VALUES (p_empresa, p_nombre, p_codigo, p_parent, true)
    RETURNING id INTO v_id;
  ELSE
    UPDATE dymaerp.categorias_productos
    SET parent_id = COALESCE(p_parent, parent_id), activo = true
    WHERE id = v_id;
  END IF;
  RETURN v_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp._touch_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp._upsert_producto_menu(p_empresa uuid, p_categoria uuid, p_sku text, p_nombre text, p_precio numeric, p_descripcion text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM dymaerp.productos WHERE empresa_id = p_empresa AND sku = p_sku;
  IF v_id IS NULL THEN
    INSERT INTO dymaerp.productos (
      empresa_id, nombre, sku, descripcion,
      costo_promedio, precio_venta, stock_actual, stock_minimo,
      unidad_medida, metodo_valuacion, activo,
      categoria_principal_id,
      es_vendible, es_insumo, controla_stock, valorizado,
      tiempo_prep_minutos, factor_compra_receta
    ) VALUES (
      p_empresa, p_nombre, p_sku, p_descripcion,
      0, p_precio, 0, 0,
      'UNIDAD', 'CPP', true,
      p_categoria,
      true, false, false, false,
      0, 1
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE dymaerp.productos
    SET nombre = p_nombre, descripcion = p_descripcion, precio_venta = p_precio,
        es_vendible = true, es_insumo = false, controla_stock = false, valorizado = false,
        categoria_principal_id = p_categoria, unidad_medida = 'UNIDAD',
        activo = true, updated_at = now()
    WHERE id = v_id;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM dymaerp.producto_categorias
    WHERE empresa_id = p_empresa AND producto_id = v_id AND categoria_id = p_categoria
  ) THEN
    INSERT INTO dymaerp.producto_categorias (empresa_id, producto_id, categoria_id, es_principal)
    VALUES (p_empresa, v_id, p_categoria, true);
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp._upsert_producto_reventa(p_empresa uuid, p_categoria uuid, p_sku text, p_nombre text, p_precio numeric, p_descripcion text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE v_id uuid;
BEGIN
  SELECT id INTO v_id FROM dymaerp.productos WHERE empresa_id = p_empresa AND sku = p_sku;
  IF v_id IS NULL THEN
    INSERT INTO dymaerp.productos (
      empresa_id, nombre, sku, descripcion,
      costo_promedio, precio_venta, stock_actual, stock_minimo,
      unidad_medida, metodo_valuacion, activo,
      categoria_principal_id,
      es_vendible, es_insumo, controla_stock, valorizado,
      tiempo_prep_minutos, factor_compra_receta
    ) VALUES (
      p_empresa, p_nombre, p_sku, p_descripcion,
      0, p_precio, 0, 0,
      'UNIDAD', 'CPP', true,
      p_categoria,
      true, false, true, true,
      0, 1
    ) RETURNING id INTO v_id;
  ELSE
    UPDATE dymaerp.productos
    SET nombre = p_nombre, descripcion = p_descripcion, precio_venta = p_precio,
        es_vendible = true, es_insumo = false, controla_stock = true, valorizado = true,
        categoria_principal_id = p_categoria, unidad_medida = 'UNIDAD',
        activo = true, updated_at = now()
    WHERE id = v_id;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM dymaerp.producto_categorias
    WHERE empresa_id = p_empresa AND producto_id = v_id AND categoria_id = p_categoria
  ) THEN
    INSERT INTO dymaerp.producto_categorias (empresa_id, producto_id, categoria_id, es_principal)
    VALUES (p_empresa, v_id, p_categoria, true);
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.empresa_id_actual()
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'dymaerp'
AS $function$
  SELECT empresa_id
  FROM dymaerp.usuarios
  WHERE lower(trim(COALESCE(email, ''))) = dymaerp.jwt_email_normalized()
  LIMIT 1;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.es_super_admin()
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'dymaerp'
AS $function$
  SELECT rol = 'super_admin'
  FROM dymaerp.usuarios
  WHERE lower(trim(COALESCE(email, ''))) = dymaerp.jwt_email_normalized()
  LIMIT 1;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.fn_receta_costeo(p_receta_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'reservacaacupe', 'public'
AS $function$
DECLARE
  v_costo_total       numeric := 0;
  v_precio_venta      numeric := 0;
  v_rendimiento       numeric := 1;
  v_unidades_posibles numeric;
  v_items             jsonb;
  v_producto_id       uuid;
BEGIN
  SELECT r.producto_id, COALESCE(r.rendimiento_cantidad, 1), COALESCE(p.precio_venta, 0)
    INTO v_producto_id, v_rendimiento, v_precio_venta
  FROM dymaerp.recetas r
  JOIN dymaerp.productos p ON p.id = r.producto_id
  WHERE r.id = p_receta_id;

  IF v_producto_id IS NULL THEN
    RETURN jsonb_build_object('error', 'receta_no_encontrada');
  END IF;

  WITH base AS (
    SELECT
      ri.id, ri.insumo_producto_id, pi.nombre AS insumo_nombre, ri.orden,
      ri.cantidad, ri.unidad_medida, COALESCE(ri.merma_pct, 0) AS merma_pct,
      pi.costo_promedio, pi.stock_actual,
      upper(trim(COALESCE(NULLIF(ri.unidad_medida, ''), pi.unidad_medida))) AS u_item,
      upper(trim(pi.unidad_medida)) AS u_ins
    FROM dymaerp.receta_items ri
    JOIN dymaerp.productos pi ON pi.id = ri.insumo_producto_id
    WHERE ri.receta_id = p_receta_id
  ),
  fam AS (
    SELECT b.*,
      CASE u_item WHEN 'G' THEN 1 WHEN 'GR' THEN 1 WHEN 'GRS' THEN 1 WHEN 'KG' THEN 1000
                  WHEN 'ML' THEN 1 WHEN 'L' THEN 1000 WHEN 'LT' THEN 1000 WHEN 'LTS' THEN 1000
                  WHEN 'UNIDAD' THEN 1 WHEN 'UNID' THEN 1 WHEN 'U' THEN 1 ELSE NULL END AS f_item,
      CASE u_ins  WHEN 'G' THEN 1 WHEN 'GR' THEN 1 WHEN 'GRS' THEN 1 WHEN 'KG' THEN 1000
                  WHEN 'ML' THEN 1 WHEN 'L' THEN 1000 WHEN 'LT' THEN 1000 WHEN 'LTS' THEN 1000
                  WHEN 'UNIDAD' THEN 1 WHEN 'UNID' THEN 1 WHEN 'U' THEN 1 ELSE NULL END AS f_ins,
      CASE
        WHEN u_item IN ('G','GR','GRS','KG') AND u_ins IN ('G','GR','GRS','KG') THEN true
        WHEN u_item IN ('ML','L','LT','LTS') AND u_ins IN ('ML','L','LT','LTS') THEN true
        WHEN u_item IN ('UNIDAD','UNID','U') AND u_ins IN ('UNIDAD','UNID','U') THEN true
        ELSE false
      END AS compat
    FROM base b
  ),
  item_calc AS (
    SELECT *,
      (CASE WHEN compat AND f_ins > 0 THEN cantidad * f_item / f_ins ELSE NULL END) AS cant_insumo,
      (CASE WHEN compat AND f_ins > 0 THEN (cantidad * f_item / f_ins) * (1 + merma_pct) ELSE NULL END) AS cantidad_efectiva,
      (CASE WHEN compat AND f_ins > 0 THEN (cantidad * f_item / f_ins) * (1 + merma_pct) * COALESCE(costo_promedio, 0) ELSE 0 END) AS subcosto,
      (CASE WHEN compat AND f_ins > 0 AND (cantidad * f_item / f_ins) * (1 + merma_pct) > 0
            THEN FLOOR(COALESCE(stock_actual, 0) / ((cantidad * f_item / f_ins) * (1 + merma_pct)))
            ELSE NULL END) AS unidades_aporte,
      (NOT compat) AS unidad_incompatible
    FROM fam
  )
  SELECT
    COALESCE(SUM(subcosto), 0),
    COALESCE(MIN(unidades_aporte), 0),
    COALESCE(jsonb_agg(jsonb_build_object(
      'item_id', id,
      'insumo_producto_id', insumo_producto_id,
      'insumo_nombre', insumo_nombre,
      'cantidad', cantidad,
      'unidad_medida', unidad_medida,
      'merma_pct', merma_pct,
      'costo_promedio', costo_promedio,
      'stock_actual', stock_actual,
      'subcosto', subcosto,
      'unidades_aporte', unidades_aporte,
      'unidad_incompatible', unidad_incompatible
    ) ORDER BY orden, insumo_nombre), '[]'::jsonb)
    INTO v_costo_total, v_unidades_posibles, v_items
  FROM item_calc;

  IF NOT EXISTS (SELECT 1 FROM dymaerp.receta_items WHERE receta_id = p_receta_id) THEN
    v_unidades_posibles := NULL;
  END IF;

  RETURN jsonb_build_object(
    'receta_id', p_receta_id,
    'producto_id', v_producto_id,
    'rendimiento_cantidad', v_rendimiento,
    'costo_total', v_costo_total,
    'costo_unitario', CASE WHEN v_rendimiento > 0 THEN v_costo_total / v_rendimiento ELSE NULL END,
    'precio_venta', v_precio_venta,
    'margen_abs', v_precio_venta - (CASE WHEN v_rendimiento > 0 THEN v_costo_total / v_rendimiento ELSE 0 END),
    'margen_pct', CASE
      WHEN v_precio_venta > 0 AND v_rendimiento > 0
      THEN ROUND(((v_precio_venta - (v_costo_total / v_rendimiento)) / v_precio_venta * 100)::numeric, 2)
      ELSE NULL
    END,
    'unidades_posibles', v_unidades_posibles,
    'items', v_items
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.incrementar_secuencia_producto(p_empresa_id uuid)
 RETURNS bigint
 LANGUAGE plpgsql
AS $function$
      DECLARE v bigint;
      BEGIN
        INSERT INTO dymaerp.productos_codigo_secuencia (empresa_id, last_value)
        VALUES (p_empresa_id, 1)
        ON CONFLICT (empresa_id) DO UPDATE
          SET last_value = dymaerp.productos_codigo_secuencia.last_value + 1,
              updated_at = now()
        RETURNING last_value INTO v;
        RETURN v;
      END;
      $function$
;

CREATE OR REPLACE FUNCTION dymaerp.jwt_email_normalized()
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'dymaerp'
AS $function$
  SELECT lower(trim(COALESCE(auth.jwt() ->> 'email', '')));
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_clone_omnicanal_schema(p_target_schema text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'enlodemari', 'pg_catalog'
AS $function$
DECLARE
  v_tables text[] := ARRAY[
    'chat_flows',
    'chat_queues',
    'chat_channels',
    'chat_agents',
    'chat_contacts',
    'chat_conversations',
    'chat_flow_nodes',
    'chat_flow_options',
    'chat_messages',
    'chat_flow_sessions',
    'chat_flow_data',
    'chat_flow_events',
    'chat_flow_node_blocks',
    'chat_comprobante_validaciones',
    'chat_empresa_operator_roles',
    'chat_queue_supervisors',
    'chat_supervisor_agents'
  ];
  r RECORD;
  def text;
  idef text;
  tdef text;
  qual text;
  chk text;
  roles_clause text;
  tbl text;
BEGIN
  IF p_target_schema !~ '^er_[0-9a-f]{32}$' THEN
    RAISE EXCEPTION 'schema inválido (se espera er_ + uuid sin guiones): %', p_target_schema;
  END IF;

  IF EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = p_target_schema) THEN
    RAISE EXCEPTION 'el esquema % ya existe', p_target_schema;
  END IF;

  EXECUTE format('CREATE SCHEMA %I', p_target_schema);

  EXECUTE format(
    'GRANT USAGE ON SCHEMA %I TO postgres, anon, authenticated, service_role',
    p_target_schema
  );

  FOREACH tbl IN ARRAY v_tables
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'enlodemari' AND c.relname = tbl AND c.relkind = 'r'
    ) THEN
      RAISE NOTICE 'neura_clone: tabla enlodemari.% ausente, se omite', tbl;
      CONTINUE;
    END IF;
    EXECUTE format(
      'CREATE TABLE %I.%I (LIKE enlodemari.%I INCLUDING DEFAULTS INCLUDING GENERATED INCLUDING IDENTITY INCLUDING STATISTICS INCLUDING STORAGE INCLUDING COMMENTS EXCLUDING CONSTRAINTS EXCLUDING INDEXES)',
      p_target_schema,
      tbl,
      tbl
    );
  END LOOP;

  FOR r IN
    SELECT c.oid, c.conname::text AS conname, cf.relname::text AS relname, c.contype::text AS ctype
    FROM pg_constraint c
    JOIN pg_class cf ON cf.oid = c.conrelid
    JOIN pg_namespace nf ON nf.oid = cf.relnamespace
    WHERE nf.nspname = 'enlodemari'
      AND c.contype IN ('p', 'u', 'c')
      AND cf.relname = ANY (v_tables)
    ORDER BY
      CASE c.contype WHEN 'p' THEN 1 WHEN 'u' THEN 2 WHEN 'c' THEN 3 ELSE 4 END,
      c.conname
  LOOP
    def := pg_get_constraintdef(r.oid);
    def := enlodemari._neura_rewrite_schema_in_expr(def, quote_ident(p_target_schema), v_tables);
    BEGIN
      EXECUTE format(
        'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
        p_target_schema,
        r.relname,
        r.conname,
        def
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'neura_clone: constraint %.% omitido: %', r.relname, r.conname, SQLERRM;
    END;
  END LOOP;

  FOR r IN
    SELECT pg_get_indexdef(i.oid) AS idef
    FROM pg_class i
    JOIN pg_namespace n ON n.oid = i.relnamespace
    JOIN pg_index ix ON ix.indexrelid = i.oid
    JOIN pg_class tbl ON tbl.oid = ix.indrelid
    WHERE n.nspname = 'enlodemari'
      AND i.relkind = 'i'
      AND ix.indisprimary IS FALSE
      AND NOT EXISTS (SELECT 1 FROM pg_constraint co WHERE co.conindid = i.oid)
      AND tbl.relname = ANY (v_tables)
  LOOP
    idef := enlodemari._neura_rewrite_schema_in_expr(r.idef, quote_ident(p_target_schema), v_tables);
    BEGIN
      EXECUTE idef;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'neura_clone: índice omitido: %', SQLERRM;
    END;
  END LOOP;

  FOR r IN
    SELECT c.oid, c.conname::text AS conname, cf.relname::text AS from_table
    FROM pg_constraint c
    JOIN pg_class cf ON cf.oid = c.conrelid
    JOIN pg_namespace nf ON nf.oid = cf.relnamespace
    WHERE nf.nspname = 'enlodemari'
      AND c.contype = 'f'
      AND cf.relname = ANY (v_tables)
    ORDER BY c.conname
  LOOP
    def := pg_get_constraintdef(r.oid);
    def := enlodemari._neura_rewrite_schema_in_expr(def, quote_ident(p_target_schema), v_tables);
    BEGIN
      EXECUTE format(
        'ALTER TABLE %I.%I ADD CONSTRAINT %I %s',
        p_target_schema,
        r.from_table,
        r.conname,
        def
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'neura_clone: FK %.% omitido: %', r.from_table, r.conname, SQLERRM;
    END;
  END LOOP;

  FOR r IN
    SELECT
      tg.tgname::text AS tgname,
      c.relname::text AS tablename,
      pg_get_triggerdef(tg.oid, true) AS tdef
    FROM pg_trigger tg
    JOIN pg_class c ON c.oid = tg.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'enlodemari'
      AND NOT tg.tgisinternal
      AND c.relname = ANY (v_tables)
  LOOP
    tdef := r.tdef;
    tdef := replace(tdef, ' ON enlodemari.' || r.tablename || ' ', ' ON ' || quote_ident(p_target_schema) || '.' || r.tablename || ' ');
    tdef := replace(tdef, ' ON enlodemari."' || r.tablename || '" ', ' ON ' || quote_ident(p_target_schema) || '."' || r.tablename || '" ');
    BEGIN
      EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', r.tgname, p_target_schema, r.tablename);
      EXECUTE tdef;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'neura_clone: trigger % en % omitido: %', r.tgname, r.tablename, SQLERRM;
    END;
  END LOOP;

  FOREACH tbl IN ARRAY v_tables
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = p_target_schema AND c.relname = tbl AND c.relkind = 'r'
    ) THEN
      EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', p_target_schema, tbl);
    END IF;
  END LOOP;

  FOR r IN
    SELECT
      pol.polname::text AS polname,
      c.relname::text AS tablename,
      pol.polcmd::text AS cmd,
      pol.polpermissive AS permissive,
      pg_get_expr(pol.polqual, pol.polrelid) AS polqual,
      pg_get_expr(pol.polwithcheck, pol.polrelid) AS polwithcheck,
      ARRAY(SELECT rolname FROM pg_roles WHERE oid = ANY (pol.polroles)) AS roles
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'enlodemari'
      AND c.relname = ANY (v_tables)
  LOOP
    BEGIN
      qual := enlodemari._neura_rewrite_schema_in_expr(r.polqual, quote_ident(p_target_schema), v_tables);
      chk := enlodemari._neura_rewrite_schema_in_expr(r.polwithcheck, quote_ident(p_target_schema), v_tables);

      IF r.roles IS NULL OR coalesce(cardinality(r.roles), 0) = 0 THEN
        roles_clause := '';
      ELSE
        roles_clause := ' TO ' || (SELECT string_agg(quote_ident(x), ', ') FROM unnest(r.roles) AS x);
      END IF;

      EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.polname, p_target_schema, r.tablename);

      IF r.cmd = 'r' THEN
        EXECUTE format(
          'CREATE POLICY %I ON %I.%I AS %s FOR SELECT%s USING (%s)',
          r.polname,
          p_target_schema,
          r.tablename,
          CASE WHEN r.permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
          roles_clause,
          coalesce(qual, 'true')
        );
      ELSIF r.cmd = 'a' THEN
        EXECUTE format(
          'CREATE POLICY %I ON %I.%I AS %s FOR INSERT%s WITH CHECK (%s)',
          r.polname,
          p_target_schema,
          r.tablename,
          CASE WHEN r.permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
          roles_clause,
          coalesce(chk, qual, 'true')
        );
      ELSIF r.cmd = 'w' THEN
        EXECUTE format(
          'CREATE POLICY %I ON %I.%I AS %s FOR UPDATE%s USING (%s) WITH CHECK (%s)',
          r.polname,
          p_target_schema,
          r.tablename,
          CASE WHEN r.permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
          roles_clause,
          coalesce(qual, 'true'),
          coalesce(chk, qual, 'true')
        );
      ELSIF r.cmd = 'd' THEN
        EXECUTE format(
          'CREATE POLICY %I ON %I.%I AS %s FOR DELETE%s USING (%s)',
          r.polname,
          p_target_schema,
          r.tablename,
          CASE WHEN r.permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
          roles_clause,
          coalesce(qual, 'true')
        );
      ELSIF r.cmd = '*' THEN
        EXECUTE format(
          'CREATE POLICY %I ON %I.%I AS %s FOR ALL%s USING (%s) WITH CHECK (%s)',
          r.polname,
          p_target_schema,
          r.tablename,
          CASE WHEN r.permissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
          roles_clause,
          coalesce(qual, 'true'),
          coalesce(chk, qual, 'true')
        );
      END IF;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'neura_clone: policy % en % omitido: %', r.polname, r.tablename, SQLERRM;
    END;
  END LOOP;

  EXECUTE format(
    'GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA %I TO authenticated',
    p_target_schema
  );
  EXECUTE format(
    'GRANT ALL ON ALL TABLES IN SCHEMA %I TO postgres, service_role',
    p_target_schema
  );
  EXECUTE format(
    'GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA %I TO authenticated',
    p_target_schema
  );
  EXECUTE format(
    'GRANT ALL ON ALL SEQUENCES IN SCHEMA %I TO postgres, service_role',
    p_target_schema
  );

  EXECUTE format(
    'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated',
    p_target_schema
  );
  EXECUTE format(
    'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA %I GRANT ALL ON TABLES TO postgres, service_role',
    p_target_schema
  );

  BEGIN
    EXECUTE format(
      'ALTER PUBLICATION supabase_realtime ADD TABLE %I.chat_messages',
      p_target_schema
    );
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;
  BEGIN
    EXECUTE format(
      'ALTER PUBLICATION supabase_realtime ADD TABLE %I.chat_conversations',
      p_target_schema
    );
  EXCEPTION WHEN duplicate_object THEN
    NULL;
  END;

  PERFORM pg_notify('pgrst', 'reload schema');
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_clone_zentra_erp_to_tenant(p_target_schema text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'enlodemari', 'pg_catalog'
AS $function$
BEGIN
  RAISE EXCEPTION
    'ELEVATE: clonado de schema tenant deshabilitado (instancia monocliente)';
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_fix_foreign_keys_retarget_from_public(p_schema text)
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
DECLARE
  r          record;
  v_new_ns   text;
  v_del      text;
  v_upd      text;
  v_extra    text;
  v_sql      text;
  v_cnt      integer := 0;
BEGIN
  IF p_schema IS NULL OR btrim(p_schema) = '' THEN
    RAISE EXCEPTION 'p_schema vacío';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = p_schema) THEN
    RAISE NOTICE 'neura_fix_fk: schema % no existe', p_schema;
    RETURN 0;
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS _neura_fk_fix_queue (
    conname     text NOT NULL,
    src_table   text NOT NULL,
    ref_table   text NOT NULL,
    src_cols    text NOT NULL,
    ref_cols    text NOT NULL,
    confdeltype "char",
    confupdtype "char",
    condeferrable boolean,
    condeferred   boolean,
    convalidated  boolean
  ) ON COMMIT DROP;

  TRUNCATE _neura_fk_fix_queue;

  INSERT INTO _neura_fk_fix_queue (
    conname, src_table, ref_table, src_cols, ref_cols,
    confdeltype, confupdtype, condeferrable, condeferred, convalidated
  )
  SELECT
    c.conname::text,
    cl.relname::text,
    cr.relname::text,
    (
      SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY u.ord)
      FROM unnest(c.conkey) WITH ORDINALITY AS u(attnum, ord)
      JOIN pg_attribute a
        ON a.attrelid = c.conrelid AND a.attnum = u.attnum AND NOT a.attisdropped
    ),
    (
      SELECT string_agg(quote_ident(a.attname), ', ' ORDER BY u.ord)
      FROM unnest(c.confkey) WITH ORDINALITY AS u(attnum, ord)
      JOIN pg_attribute a
        ON a.attrelid = c.confrelid AND a.attnum = u.attnum AND NOT a.attisdropped
    ),
    c.confdeltype,
    c.confupdtype,
    c.condeferrable,
    c.condeferred,
    c.convalidated
  FROM pg_constraint c
  JOIN pg_class cl ON cl.oid = c.conrelid
  JOIN pg_namespace n ON n.oid = cl.relnamespace
  JOIN pg_class cr ON cr.oid = c.confrelid
  JOIN pg_namespace nr ON nr.oid = cr.relnamespace
  WHERE c.contype = 'f'
    AND n.nspname = p_schema
    AND nr.nspname = 'enlodemari';

  FOR r IN SELECT * FROM _neura_fk_fix_queue
  LOOP
    EXECUTE format(
      'ALTER TABLE %I.%I DROP CONSTRAINT IF EXISTS %I',
      p_schema,
      r.src_table,
      r.conname
    );
  END LOOP;

  FOR r IN SELECT * FROM _neura_fk_fix_queue
  LOOP
    IF EXISTS (
      SELECT 1 FROM pg_tables
      WHERE schemaname = p_schema AND tablename = r.ref_table
    ) THEN
      v_new_ns := p_schema;
    ELSIF EXISTS (
      SELECT 1 FROM pg_tables
      WHERE schemaname = 'enlodemari' AND tablename = r.ref_table
    ) THEN
      v_new_ns := 'enlodemari';
    ELSE
      RAISE NOTICE 'neura_fix_fk: sin destino para %.% -> public.% (omitido ADD)',
        p_schema, r.src_table, r.ref_table;
      CONTINUE;
    END IF;

    v_del := CASE r.confdeltype
      WHEN 'a' THEN ''
      WHEN 'r' THEN ' ON DELETE RESTRICT'
      WHEN 'c' THEN ' ON DELETE CASCADE'
      WHEN 'n' THEN ' ON DELETE SET NULL'
      WHEN 'd' THEN ' ON DELETE SET DEFAULT'
      ELSE ''
    END;

    v_upd := CASE r.confupdtype
      WHEN 'a' THEN ''
      WHEN 'r' THEN ' ON UPDATE RESTRICT'
      WHEN 'c' THEN ' ON UPDATE CASCADE'
      WHEN 'n' THEN ' ON UPDATE SET NULL'
      WHEN 'd' THEN ' ON UPDATE SET DEFAULT'
      ELSE ''
    END;

    v_extra := v_del || v_upd;

    IF r.condeferrable THEN
      v_extra := v_extra || CASE WHEN r.condeferred
        THEN ' DEFERRABLE INITIALLY DEFERRED'
        ELSE ' DEFERRABLE INITIALLY IMMEDIATE'
      END;
    END IF;

    IF NOT r.convalidated THEN
      v_extra := v_extra || ' NOT VALID';
    END IF;

    v_sql := format(
      'ALTER TABLE %I.%I ADD CONSTRAINT %I FOREIGN KEY (%s) REFERENCES %I.%I (%s)%s',
      p_schema,
      r.src_table,
      r.conname,
      r.src_cols,
      v_new_ns,
      r.ref_table,
      r.ref_cols,
      v_extra
    );

    BEGIN
      EXECUTE v_sql;
      v_cnt := v_cnt + 1;
    EXCEPTION WHEN OTHERS THEN
      RAISE NOTICE 'neura_fix_fk: ADD falló %: %', r.conname, SQLERRM;
    END;
  END LOOP;

  RETURN v_cnt;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_inbox_awaiting_reply_since_batch(p_schema text, p_empresa_id uuid, p_conversation_ids uuid[])
 RETURNS TABLE(conversation_id uuid, awaiting_since timestamp with time zone, client_turn_since timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
DECLARE
  sch text := trim(both from coalesce(p_schema, ''));
BEGIN
  IF sch IS NULL OR sch = '' OR sch !~ '^(zentra_erp|public|er_[0-9a-f]{32}|erp_[a-z0-9_]+)$' THEN
    RAISE EXCEPTION 'schema no permitido: %', p_schema;
  END IF;

  RETURN QUERY EXECUTE format(
    $q$
    WITH conv AS (SELECT unnest($1::uuid[]) AS id),
    last_contact AS (
      SELECT DISTINCT ON (m.conversation_id)
        m.conversation_id,
        m.created_at AS at
      FROM %I.chat_messages m
      INNER JOIN conv c ON c.id = m.conversation_id
      WHERE m.empresa_id = $2::uuid
        AND m.from_me = false
        AND lower(coalesce(m.sender_type, 'contact')) IN ('contact')
      ORDER BY m.conversation_id, m.created_at DESC
    ),
    last_human AS (
      SELECT m.conversation_id, max(m.created_at) AS at
      FROM %I.chat_messages m
      INNER JOIN conv c ON c.id = m.conversation_id
      WHERE m.empresa_id = $2::uuid
        AND m.from_me = true
        AND lower(coalesce(m.sender_type, '')) = 'human'
      GROUP BY m.conversation_id
    ),
    last_global AS (
      SELECT DISTINCT ON (m.conversation_id)
        m.conversation_id,
        m.from_me,
        m.created_at AS at
      FROM %I.chat_messages m
      INNER JOIN conv c ON c.id = m.conversation_id
      WHERE m.empresa_id = $2::uuid
      ORDER BY m.conversation_id, m.created_at DESC
    )
    SELECT
      conv.id AS conversation_id,
      CASE
        WHEN lc.at IS NOT NULL AND lc.at > coalesce(lh.at, '-infinity'::timestamptz) THEN lc.at
        ELSE NULL::timestamptz
      END AS awaiting_since,
      CASE
        WHEN lc.at IS NOT NULL AND lc.at > coalesce(lh.at, '-infinity'::timestamptz) THEN NULL::timestamptz
        WHEN lg.from_me IS TRUE THEN lg.at
        ELSE NULL::timestamptz
      END AS client_turn_since
    FROM conv
    LEFT JOIN last_contact lc ON lc.conversation_id = conv.id
    LEFT JOIN last_human lh ON lh.conversation_id = conv.id
    LEFT JOIN last_global lg ON lg.conversation_id = conv.id
    $q$,
    sch
  )
  USING p_conversation_ids, p_empresa_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_install_nota_credito_tables(p_schema text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  s text := btrim(p_schema);
  fq text;
  cq text;
BEGIN
  IF s IS NULL OR s = '' THEN
    RAISE EXCEPTION 'neura_install_nota_credito_tables: schema vacío';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
    RAISE NOTICE 'neura_install_nota_credito_tables: schema % no existe (omitido)', s;
    RETURN;
  END IF;

  IF s = 'enlodemari' THEN
    fq := 'enlodemari';
  ELSE
    fq := quote_ident(s);
  END IF;

  -- nota_credito
  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS %1$s.nota_credito (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      empresa_id uuid NOT NULL REFERENCES dymaerp.empresas(id) ON DELETE CASCADE,
      cliente_id uuid NOT NULL REFERENCES %2$s.clientes(id) ON DELETE RESTRICT,
      factura_id uuid NOT NULL REFERENCES %2$s.facturas(id) ON DELETE RESTRICT,
      monto numeric NOT NULL CHECK (monto > 0),
      motivo text NOT NULL,
      observacion_interna text,
      estado_erp text NOT NULL DEFAULT 'borrador',
      created_by_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
      created_by_email_snapshot text,
      created_by_nombre_snapshot text,
      saldo_previo_snapshot numeric NOT NULL,
      monto_factura_snapshot numeric NOT NULL,
      suma_pagos_snapshot numeric NOT NULL,
      moneda_snapshot text NOT NULL,
      factura_electronica_origen_id uuid REFERENCES %2$s.factura_electronica(id) ON DELETE SET NULL,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT nota_credito_estado_erp_check CHECK (estado_erp IN (
        'borrador',
        'pendiente_envio_sifen',
        'aprobada',
        'rechazada',
        'error',
        'anulada_borrador'
      )),
      CONSTRAINT nota_credito_moneda_snapshot_check CHECK (moneda_snapshot IN ('GS', 'USD')),
      CONSTRAINT nota_credito_motivo_len_check CHECK (length(trim(motivo)) >= 5 AND length(motivo) <= 2000)
    )
  $ddl$, quote_ident(s), fq);

  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_nota_credito_empresa ON %I.nota_credito (empresa_id)',
    s
  );
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_nota_credito_factura ON %I.nota_credito (factura_id)',
    s
  );
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_nota_credito_empresa_created ON %I.nota_credito (empresa_id, created_at DESC)',
    s
  );

  -- Una sola NC "activa" por factura (borrador, pendiente envío o aprobada)
  EXECUTE format('DROP INDEX IF EXISTS %I.%I', s, 'uq_nota_credito_factura_estado_activo');
  EXECUTE format(
    'CREATE UNIQUE INDEX IF NOT EXISTS %I ON %I.nota_credito (factura_id) WHERE (estado_erp IN (''borrador'', ''pendiente_envio_sifen'', ''aprobada''))',
    'uq_nota_credito_factura_estado_activo',
    s
  );

  -- nota_credito_electronica (ciclo SIFEN; fase 1 deja fila en sin_envio)
  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS %1$s.nota_credito_electronica (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      empresa_id uuid NOT NULL REFERENCES dymaerp.empresas(id) ON DELETE CASCADE,
      nota_credito_id uuid NOT NULL UNIQUE REFERENCES %1$s.nota_credito(id) ON DELETE CASCADE,
      estado_sifen text NOT NULL DEFAULT 'sin_envio',
      cdc text,
      cdc_factura_origen text,
      xml_path text,
      xml_firmado_path text,
      kude_url text,
      response_json jsonb,
      error text,
      created_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT nota_credito_electronica_estado_sifen_check CHECK (estado_sifen IN (
        'sin_envio',
        'borrador',
        'generado',
        'firmado',
        'enviado',
        'aprobado',
        'rechazado',
        'error_envio',
        'cancelado'
      ))
    )
  $ddl$, quote_ident(s));

  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_nota_credito_electronica_empresa ON %I.nota_credito_electronica (empresa_id)',
    s
  );

  -- Auditoría / eventos de negocio (no confundir con eventos SOAP de SIFEN)
  EXECUTE format($ddl$
    CREATE TABLE IF NOT EXISTS %1$s.nota_credito_evento (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      empresa_id uuid NOT NULL REFERENCES dymaerp.empresas(id) ON DELETE CASCADE,
      nota_credito_id uuid NOT NULL REFERENCES %1$s.nota_credito(id) ON DELETE CASCADE,
      actor_user_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
      tipo_evento text NOT NULL,
      detalle_json jsonb NOT NULL DEFAULT '{}'::jsonb,
      created_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT nota_credito_evento_tipo_check CHECK (tipo_evento IN (
        'creacion',
        'validacion',
        'rechazo_negocio',
        'cambio_estado_erp',
        'preparacion_sifen',
        'error',
        'observacion_operativa',
        'anulacion_borrador'
      ))
    )
  $ddl$, quote_ident(s));

  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_nota_credito_evento_nc ON %I.nota_credito_evento (nota_credito_id, created_at DESC)',
    s
  );
  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS idx_nota_credito_evento_empresa ON %I.nota_credito_evento (empresa_id)',
    s
  );

  EXECUTE format(
    'DROP TRIGGER IF EXISTS nota_credito_updated_at ON %I.nota_credito',
    s
  );
  EXECUTE format(
    'CREATE TRIGGER nota_credito_updated_at BEFORE UPDATE ON %I.nota_credito FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at()',
    s
  );
  EXECUTE format(
    'DROP TRIGGER IF EXISTS nota_credito_electronica_updated_at ON %I.nota_credito_electronica',
    s
  );
  EXECUTE format(
    'CREATE TRIGGER nota_credito_electronica_updated_at BEFORE UPDATE ON %I.nota_credito_electronica FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at()',
    s
  );

  -- RLS
  EXECUTE format('ALTER TABLE %I.nota_credito ENABLE ROW LEVEL SECURITY', s);
  EXECUTE format('ALTER TABLE %I.nota_credito_electronica ENABLE ROW LEVEL SECURITY', s);
  EXECUTE format('ALTER TABLE %I.nota_credito_evento ENABLE ROW LEVEL SECURITY', s);

  EXECUTE format('DROP POLICY IF EXISTS nota_credito_select ON %I.nota_credito', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_insert ON %I.nota_credito', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_update ON %I.nota_credito', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_delete ON %I.nota_credito', s);
  EXECUTE format(
    'CREATE POLICY nota_credito_select ON %I.nota_credito FOR SELECT USING (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_insert ON %I.nota_credito FOR INSERT WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_update ON %I.nota_credito FOR UPDATE USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_delete ON %I.nota_credito FOR DELETE USING (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );

  EXECUTE format('DROP POLICY IF EXISTS nota_credito_electronica_select ON %I.nota_credito_electronica', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_electronica_insert ON %I.nota_credito_electronica', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_electronica_update ON %I.nota_credito_electronica', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_electronica_delete ON %I.nota_credito_electronica', s);
  EXECUTE format(
    'CREATE POLICY nota_credito_electronica_select ON %I.nota_credito_electronica FOR SELECT USING (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_electronica_insert ON %I.nota_credito_electronica FOR INSERT WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_electronica_update ON %I.nota_credito_electronica FOR UPDATE USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_electronica_delete ON %I.nota_credito_electronica FOR DELETE USING (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );

  EXECUTE format('DROP POLICY IF EXISTS nota_credito_evento_select ON %I.nota_credito_evento', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_evento_insert ON %I.nota_credito_evento', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_evento_update ON %I.nota_credito_evento', s);
  EXECUTE format('DROP POLICY IF EXISTS nota_credito_evento_delete ON %I.nota_credito_evento', s);
  EXECUTE format(
    'CREATE POLICY nota_credito_evento_select ON %I.nota_credito_evento FOR SELECT USING (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_evento_insert ON %I.nota_credito_evento FOR INSERT WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_evento_update ON %I.nota_credito_evento FOR UPDATE USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
  EXECUTE format(
    'CREATE POLICY nota_credito_evento_delete ON %I.nota_credito_evento FOR DELETE USING (dymaerp.puede_acceder_empresa(empresa_id))',
    s
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_provision_empresa_data_schema(p_empresa_id uuid, p_schema_slug text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'enlodemari', 'pg_catalog'
AS $function$
BEGIN
  RAISE EXCEPTION
    'ELEVATE: provisioning multiempresa deshabilitado en esta instancia monocliente';
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_teardown_provision_failed(p_empresa_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'enlodemari', 'pg_catalog'
AS $function$
BEGIN
  -- No-op: en monocliente no hay cleanup de schemas tenant.
  RETURN;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_upgrade_factura_correlativo(p_schema text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  s text := btrim(p_schema);
BEGIN
  IF s IS NULL OR s = '' THEN
    RAISE EXCEPTION 'neura_upgrade_factura_correlativo: schema vacío';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
    RAISE NOTICE 'neura_upgrade_factura_correlativo: schema % no existe (omitido)', s;
    RETURN;
  END IF;

  EXECUTE format(
    'CREATE TABLE IF NOT EXISTS %I.factura_correlativos (
      empresa_id uuid PRIMARY KEY,
      prefijo text NOT NULL DEFAULT ''FAC-'',
      ultimo_numero bigint NOT NULL DEFAULT 0 CHECK (ultimo_numero >= 0),
      updated_at timestamptz NOT NULL DEFAULT now()
    )',
    s
  );

  EXECUTE format(
    'CREATE OR REPLACE FUNCTION %I.next_numero_factura_empresa(
      p_empresa_id uuid,
      p_prefijo_default text DEFAULT ''FAC-''
    )
    RETURNS text
    LANGUAGE plpgsql
    AS $f$
    DECLARE
      v_prefijo text;
      v_num bigint;
      v_ancho int := 6;
    BEGIN
      IF p_empresa_id IS NULL THEN
        RAISE EXCEPTION ''next_numero_factura_empresa: empresa_id es obligatorio'';
      END IF;

      -- Inicializa contador si no existe (toma max numérico real de facturas de la empresa).
      IF NOT EXISTS (
        SELECT 1 FROM %1$I.factura_correlativos c WHERE c.empresa_id = p_empresa_id
      ) THEN
        SELECT
          COALESCE(
            (
              SELECT NULLIF(regexp_replace(f.numero_factura, ''([0-9]+)$'', ''''), '''')
              FROM %1$I.facturas f
              WHERE f.empresa_id = p_empresa_id
                AND f.numero_factura ~ ''[0-9]+$''
              ORDER BY COALESCE(f.created_at, f.updated_at) DESC NULLS LAST, f.id DESC
              LIMIT 1
            ),
            NULLIF(btrim(p_prefijo_default), ''''),
            ''FAC-''
          ),
          COALESCE(
            (
              SELECT max((regexp_match(f.numero_factura, ''([0-9]+)$''))[1]::bigint)
              FROM %1$I.facturas f
              WHERE f.empresa_id = p_empresa_id
                AND f.numero_factura ~ ''[0-9]+$''
            ),
            0
          )
        INTO v_prefijo, v_num;

        INSERT INTO %1$I.factura_correlativos(empresa_id, prefijo, ultimo_numero)
        VALUES (p_empresa_id, v_prefijo, v_num)
        ON CONFLICT (empresa_id) DO NOTHING;
      END IF;

      UPDATE %1$I.factura_correlativos c
      SET
        prefijo = COALESCE(NULLIF(btrim(p_prefijo_default), ''''), c.prefijo, ''FAC-''),
        ultimo_numero = c.ultimo_numero + 1,
        updated_at = now()
      WHERE c.empresa_id = p_empresa_id
      RETURNING c.prefijo, c.ultimo_numero
      INTO v_prefijo, v_num;

      IF v_num IS NULL THEN
        RAISE EXCEPTION ''No se pudo reservar correlativo de factura'';
      END IF;

      RETURN COALESCE(v_prefijo, ''FAC-'') || lpad(v_num::text, v_ancho, ''0'');
    END;
    $f$',
    s
  );

  EXECUTE format('GRANT EXECUTE ON FUNCTION %I.next_numero_factura_empresa(uuid, text) TO service_role', s);
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_upgrade_factura_estado_corregida_nc(p_schema text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  s text := btrim(p_schema);
BEGIN
  IF s IS NULL OR s = '' THEN
    RAISE EXCEPTION 'neura_upgrade_factura_estado_corregida_nc: schema vacío';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
    RAISE NOTICE 'neura_upgrade_factura_estado_corregida_nc: schema % no existe (omitido)', s;
    RETURN;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM information_schema.tables WHERE table_schema = s AND table_name = 'facturas'
  ) THEN
    RAISE NOTICE 'neura_upgrade_factura_estado_corregida_nc: sin tabla facturas en % (omitido)', s;
    RETURN;
  END IF;

  EXECUTE format(
    'ALTER TABLE %I.facturas DROP CONSTRAINT IF EXISTS facturas_estado_check',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.facturas ADD CONSTRAINT facturas_estado_check CHECK (estado IN (
      ''Pagado'',
      ''Pendiente'',
      ''Vencido'',
      ''Anulado'',
      ''Corregida NC''
    ))',
    s
  );

  -- Datos ya consistentes en saldo pero estado ERP desactualizado (pre-migración).
  IF EXISTS (
    SELECT 1 FROM information_schema.tables WHERE table_schema = s AND table_name = 'nota_credito'
  ) THEN
    EXECUTE format(
      'UPDATE %I.facturas f SET estado = ''Corregida NC'', updated_at = now()
       WHERE f.saldo <= 0.0001
         AND f.estado IN (''Pendiente'', ''Vencido'')
         AND EXISTS (
           SELECT 1 FROM %I.nota_credito nc
           WHERE nc.factura_id = f.id AND nc.empresa_id = f.empresa_id
             AND nc.estado_erp = ''aprobada''
         )',
      s,
      s
    );
  ELSE
    RAISE NOTICE 'neura_upgrade_factura_estado_corregida_nc: sin tabla nota_credito en % (solo CHECK)', s;
  END IF;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.neura_upgrade_nota_credito_fase2(p_schema text)
 RETURNS void
 LANGUAGE plpgsql
AS $function$
DECLARE
  s text := btrim(p_schema);
BEGIN
  IF s IS NULL OR s = '' THEN
    RAISE EXCEPTION 'neura_upgrade_nota_credito_fase2: schema vacío';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = s) THEN
    RAISE NOTICE 'neura_upgrade_nota_credito_fase2: schema % no existe (omitido)', s;
    RETURN;
  END IF;

  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD COLUMN IF NOT EXISTS sifen_d_prot_cons_lote text',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD COLUMN IF NOT EXISTS sifen_ultima_respuesta_recibe_lote jsonb',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD COLUMN IF NOT EXISTS sifen_ultima_respuesta_consulta_lote jsonb',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD COLUMN IF NOT EXISTS sifen_aprobado_at timestamptz',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD COLUMN IF NOT EXISTS last_response_json jsonb',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD COLUMN IF NOT EXISTS last_error text',
    s
  );

  EXECUTE format(
    'UPDATE %I.nota_credito_electronica SET estado_sifen = ''sin_envio'' WHERE estado_sifen = ''borrador''',
    s
  );

  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica DROP CONSTRAINT IF EXISTS nota_credito_electronica_estado_sifen_check',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_electronica ADD CONSTRAINT nota_credito_electronica_estado_sifen_check CHECK (estado_sifen IN (
      ''sin_envio'',
      ''generado'',
      ''firmado'',
      ''enviado'',
      ''en_proceso'',
      ''aprobado'',
      ''rechazado'',
      ''error_envio'',
      ''cancelado''
    ))',
    s
  );

  EXECUTE format(
    'ALTER TABLE %I.nota_credito_evento DROP CONSTRAINT IF EXISTS nota_credito_evento_tipo_check',
    s
  );
  EXECUTE format(
    'ALTER TABLE %I.nota_credito_evento ADD CONSTRAINT nota_credito_evento_tipo_check CHECK (tipo_evento IN (
      ''creacion'',
      ''validacion'',
      ''rechazo_negocio'',
      ''cambio_estado_erp'',
      ''preparacion_sifen'',
      ''error'',
      ''observacion_operativa'',
      ''anulacion_borrador'',
      ''xml_generado'',
      ''xml_firmado'',
      ''enviado_set'',
      ''respuesta_set'',
      ''aprobado'',
      ''rechazado'',
      ''impacto_saldo_aplicado'',
      ''error_envio''
    ))',
    s
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.next_numero_factura_empresa(p_empresa_id uuid, p_prefijo_default text DEFAULT 'FAC-'::text)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
    DECLARE
      v_prefijo text;
      v_num bigint;
      v_ancho int := 6;
    BEGIN
      IF p_empresa_id IS NULL THEN
        RAISE EXCEPTION 'next_numero_factura_empresa: empresa_id es obligatorio';
      END IF;

      -- Inicializa contador si no existe (toma max numérico real de facturas de la empresa).
      IF NOT EXISTS (
        SELECT 1 FROM dymaerp.factura_correlativos c WHERE c.empresa_id = p_empresa_id
      ) THEN
        SELECT
          COALESCE(
            (
              SELECT NULLIF(regexp_replace(f.numero_factura, '([0-9]+)$', ''), '')
              FROM dymaerp.facturas f
              WHERE f.empresa_id = p_empresa_id
                AND f.numero_factura ~ '[0-9]+$'
              ORDER BY COALESCE(f.created_at, f.updated_at) DESC NULLS LAST, f.id DESC
              LIMIT 1
            ),
            NULLIF(btrim(p_prefijo_default), ''),
            'FAC-'
          ),
          COALESCE(
            (
              SELECT max((regexp_match(f.numero_factura, '([0-9]+)$'))[1]::bigint)
              FROM dymaerp.facturas f
              WHERE f.empresa_id = p_empresa_id
                AND f.numero_factura ~ '[0-9]+$'
            ),
            0
          )
        INTO v_prefijo, v_num;

        INSERT INTO dymaerp.factura_correlativos(empresa_id, prefijo, ultimo_numero)
        VALUES (p_empresa_id, v_prefijo, v_num)
        ON CONFLICT (empresa_id) DO NOTHING;
      END IF;

      UPDATE dymaerp.factura_correlativos c
      SET
        prefijo = COALESCE(NULLIF(btrim(p_prefijo_default), ''), c.prefijo, 'FAC-'),
        ultimo_numero = c.ultimo_numero + 1,
        updated_at = now()
      WHERE c.empresa_id = p_empresa_id
      RETURNING c.prefijo, c.ultimo_numero
      INTO v_prefijo, v_num;

      IF v_num IS NULL THEN
        RAISE EXCEPTION 'No se pudo reservar correlativo de factura';
      END IF;

      RETURN COALESCE(v_prefijo, 'FAC-') || lpad(v_num::text, v_ancho, '0');
    END;
    $function$
;

CREATE OR REPLACE FUNCTION dymaerp.nota_credito_aplicar_aprobacion_set(p_data_schema text, p_nota_credito_id uuid, p_factura_id uuid, p_empresa_id uuid, p_monto numeric)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
DECLARE
  s text := btrim(p_data_schema);
  fq text := quote_ident(btrim(p_data_schema));
  saldo_act numeric;
  otra uuid;
BEGIN
  IF s IS NULL OR s = '' THEN
    RAISE EXCEPTION 'nota_credito_aplicar_aprobacion_set: schema vacío';
  END IF;

  EXECUTE format(
    'SELECT id FROM %s.nota_credito
     WHERE factura_id = $1 AND empresa_id = $2 AND estado_erp = ''aprobada'' AND id <> $3
     LIMIT 1',
    fq
  ) INTO otra USING p_factura_id, p_empresa_id, p_nota_credito_id;
  IF otra IS NOT NULL THEN
    RAISE EXCEPTION 'Ya existe otra nota de crédito aprobada para esta factura';
  END IF;

  EXECUTE format(
    'SELECT saldo FROM %s.facturas WHERE id = $1 AND empresa_id = $2 FOR UPDATE',
    fq
  ) INTO saldo_act USING p_factura_id, p_empresa_id;

  IF saldo_act IS NULL THEN
    RAISE EXCEPTION 'Factura no encontrada';
  END IF;
  IF p_monto > saldo_act + 0.02 THEN
    RAISE EXCEPTION 'El monto de la NC (%) supera el saldo pendiente (%)', p_monto, saldo_act;
  END IF;

  EXECUTE format(
    'UPDATE %s.facturas SET
       saldo = GREATEST(0::numeric, saldo - $1),
       estado = CASE
         WHEN estado = ''Anulado'' THEN ''Anulado''
         WHEN GREATEST(0::numeric, saldo - $1) <= 0.0001 THEN ''Corregida NC''
         ELSE estado
       END,
       updated_at = now()
     WHERE id = $2 AND empresa_id = $3',
    fq
  ) USING p_monto, p_factura_id, p_empresa_id;

  EXECUTE format(
    'UPDATE %s.nota_credito SET estado_erp = ''aprobada'', updated_at = now()
     WHERE id = $1 AND empresa_id = $2 AND estado_erp <> ''anulada_borrador''',
    fq
  ) USING p_nota_credito_id, p_empresa_id;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.nota_credito_tras_aprobacion_set_transaccional(p_data_schema text, p_ne_id uuid, p_nc_id uuid, p_factura_id uuid, p_empresa_id uuid, p_monto numeric, p_ultima_consulta jsonb, p_sifen_aprobado_at timestamp with time zone)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_temp'
AS $function$
DECLARE
  sch text := btrim(p_data_schema);
  prev_ne text;
BEGIN
  IF sch IS NULL OR sch = '' THEN
    RAISE EXCEPTION 'nota_credito_tras_aprobacion_set_transaccional: schema vacío';
  END IF;

  EXECUTE format(
    'SELECT estado_sifen::text FROM %I.nota_credito_electronica WHERE id = $1 AND empresa_id = $2 FOR UPDATE',
    sch
  ) INTO prev_ne USING p_ne_id, p_empresa_id;

  IF prev_ne IS NULL THEN
    RAISE EXCEPTION 'nota_credito_electronica no encontrada';
  END IF;
  IF prev_ne = 'aprobado' THEN
    RETURN;
  END IF;

  EXECUTE format(
    'UPDATE %I.nota_credito_electronica SET
       estado_sifen = ''aprobado'',
       sifen_aprobado_at = $1,
       sifen_ultima_respuesta_consulta_lote = $2,
       last_response_json = $2,
       last_error = NULL,
       error = NULL,
       updated_at = now()
     WHERE id = $3 AND empresa_id = $4 AND estado_sifen <> ''aprobado''',
    sch
  ) USING p_sifen_aprobado_at, p_ultima_consulta, p_ne_id, p_empresa_id;

  PERFORM dymaerp.nota_credito_aplicar_aprobacion_set(
    sch,
    p_nc_id,
    p_factura_id,
    p_empresa_id,
    p_monto
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.puede_acceder_empresa(empresa_uuid uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'dymaerp'
AS $function$
  SELECT dymaerp.es_super_admin()
     OR empresa_uuid = dymaerp.empresa_id_actual();
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.set_chat_contact_phone_normalized()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.phone_normalized := NULLIF(regexp_replace(COALESCE(NEW.phone_number, ''), '\D', '', 'g'), '');
  IF NEW.phone_normalized IS NOT NULL THEN
    NEW.phone_number := NEW.phone_normalized;
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.set_crm_prospectos_updated()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  NEW.fecha_actualizacion = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.sorteos_ensure_order_from_chat(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_empresa_id          uuid := (p->>'empresa_id')::uuid;
  v_sorteo_id           uuid := (p->>'sorteo_id')::uuid;
  v_conv_id             uuid := (p->>'chat_conversation_id')::uuid;
  v_flow_code           text := nullif(trim(p->>'flow_code'), '');
  v_idem                text := nullif(trim(p->>'idempotency_key'), '');
  v_wa                  text := trim(p->>'whatsapp_numero');
  v_nombre              text := trim(p->>'nombre_completo');
  v_cedula              text := nullif(trim(p->>'cedula'), '');
  v_ciudad              text := nullif(trim(p->>'ciudad'), '');
  v_qty                 int := coalesce((p->>'cantidad_boletos')::int, 0);
  v_comp_url            text := nullif(trim(p->>'comprobante_url'), '');
  v_validado_por        text := coalesce(nullif(trim(p->>'validado_por'), ''), 'chat_flow');

  v_monto_explicit      numeric := NULL;
  v_promo_nombre        text := nullif(trim(p->>'promo_nombre'), '');
  v_precio_regular_ref  numeric := NULL;

  v_revendedor_id       uuid := NULL;
  v_codigo_ref_snap     text := NULL;

  s                     record;
  v_entrada_id          uuid;
  v_numero_orden        int;
  v_cliente_id          uuid;
  v_monto_total         numeric;
  v_precio_fuente_ins   text;
  v_lista_calc          numeric;
  i                     int;
  v_num                 int;
  v_num_str             text;
  v_existing            record;
  v_cant_existente      int;
  v_mt_existente        numeric;
  v_promo_existente     text;
  v_pf_existente        text;
BEGIN
  IF v_empresa_id IS NULL OR v_sorteo_id IS NULL OR v_conv_id IS NULL OR v_idem IS NULL OR v_idem = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Faltan empresa_id, sorteo_id, chat_conversation_id o idempotency_key');
  END IF;
  IF v_wa = '' OR v_nombre = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Faltan whatsapp_numero o nombre_completo');
  END IF;
  IF v_qty < 1 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'cantidad_boletos debe ser mayor a 0');
  END IF;

  IF p ? 'monto_compra' THEN
    BEGIN
      v_monto_explicit := NULLIF(trim(p->>'monto_compra'), '')::numeric;
    EXCEPTION WHEN OTHERS THEN
      v_monto_explicit := NULL;
    END;
  END IF;
  IF v_monto_explicit IS NOT NULL AND v_monto_explicit <= 0 THEN
    v_monto_explicit := NULL;
  END IF;

  IF p ? 'precio_regular_referencia' THEN
    BEGIN
      v_precio_regular_ref := NULLIF(trim(p->>'precio_regular_referencia'), '')::numeric;
    EXCEPTION WHEN OTHERS THEN
      v_precio_regular_ref := NULL;
    END;
  END IF;
  IF v_precio_regular_ref IS NOT NULL AND v_precio_regular_ref <= 0 THEN
    v_precio_regular_ref := NULL;
  END IF;

  v_codigo_ref_snap := nullif(trim(p->>'codigo_referido'), '');
  IF p ? 'revendedor_id' AND nullif(trim(p->>'revendedor_id'), '') IS NOT NULL THEN
    BEGIN
      v_revendedor_id := (p->>'revendedor_id')::uuid;
    EXCEPTION WHEN OTHERS THEN
      v_revendedor_id := NULL;
    END;
  END IF;

  SELECT e.id, e.numero_orden, e.estado_pago
  INTO v_existing
  FROM dymaerp.sorteo_entradas e
  WHERE e.idempotency_key = v_idem
  LIMIT 1;

  IF FOUND THEN
    SELECT
      e.cantidad_boletos,
      e.monto_total,
      e.promo_nombre,
      e.precio_fuente
    INTO v_cant_existente, v_mt_existente, v_promo_existente, v_pf_existente
    FROM dymaerp.sorteo_entradas e
    WHERE e.id = (v_existing).id;

    RETURN jsonb_build_object(
      'ok', true,
      'idempotent', true,
      'message', 'Orden ya existía (idempotencia)',
      'entrada', jsonb_build_object(
        'id', (v_existing).id,
        'numero_orden', (v_existing).numero_orden,
        'cantidad_boletos', coalesce(v_cant_existente, v_qty),
        'monto_total', v_mt_existente,
        'promo_nombre', coalesce(v_promo_existente, ''),
        'precio_fuente', coalesce(v_pf_existente, 'lista'),
        'estado_pago', (v_existing).estado_pago
      ),
      'cupones', (
        SELECT coalesce(jsonb_agg(
          jsonb_build_object('id', c.id, 'numero_cupon', c.numero_cupon)
          ORDER BY c.numero_cupon
        ), '[]'::jsonb)
        FROM dymaerp.sorteo_cupones c
        WHERE c.entrada_id = (v_existing).id
      )
    );
  END IF;

  SELECT * INTO s FROM dymaerp.sorteos WHERE id = v_sorteo_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Sorteo no encontrado');
  END IF;
  IF s.empresa_id IS DISTINCT FROM v_empresa_id THEN
    RETURN jsonb_build_object('ok', false, 'message', 'El sorteo no pertenece a la empresa indicada');
  END IF;
  IF s.estado IS DISTINCT FROM 'activo' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'El sorteo no está activo');
  END IF;
  IF s.total_boletos_vendidos + v_qty > s.max_boletos THEN
    RETURN jsonb_build_object('ok', false, 'message', 'No hay boletos disponibles para esta cantidad');
  END IF;

  v_lista_calc := s.precio_por_boleto * v_qty;

  IF v_monto_explicit IS NOT NULL THEN
    v_monto_total := v_monto_explicit;
    v_precio_fuente_ins := 'promo';
    IF v_precio_regular_ref IS NULL THEN
      v_precio_regular_ref := v_lista_calc;
    END IF;
  ELSE
    v_monto_total := v_lista_calc;
    v_precio_fuente_ins := 'lista';
    v_precio_regular_ref := NULL;
  END IF;

  SELECT id INTO v_cliente_id
  FROM dymaerp.clientes
  WHERE empresa_id = v_empresa_id
    AND deleted_at IS NULL
    AND (
      (v_cedula IS NOT NULL AND documento IS NOT NULL AND trim(documento) = v_cedula)
      OR (trim(telefono) = v_wa)
    )
  LIMIT 1;

  IF v_cliente_id IS NULL THEN
    INSERT INTO dymaerp.clientes (
      empresa_id, tipo_cliente, nombre_contacto, nombre, documento, telefono, ciudad, origen
    ) VALUES (
      v_empresa_id, 'persona', v_nombre, v_nombre, v_cedula, v_wa, v_ciudad, 'SORTEO_CHAT'
    )
    RETURNING id INTO v_cliente_id;
  END IF;

  v_numero_orden := s.ultimo_numero_orden + 1;

  IF v_revendedor_id IS NOT NULL THEN
    IF NOT EXISTS (
      SELECT 1 FROM dymaerp.sorteo_revendedores r
      WHERE r.id = v_revendedor_id
        AND r.empresa_id = v_empresa_id
        AND r.sorteo_id = v_sorteo_id
        AND r.activo = true
    ) THEN
      v_revendedor_id := NULL;
      v_codigo_ref_snap := NULL;
    END IF;
  ELSE
    v_codigo_ref_snap := NULL;
  END IF;

  INSERT INTO dymaerp.sorteo_entradas (
    empresa_id,
    sorteo_id,
    conversacion_id,
    cliente_id,
    whatsapp_numero,
    nombre_participante,
    documento,
    cantidad_boletos,
    monto_total,
    moneda,
    estado_pago,
    comprobante_url,
    validado_por,
    numero_orden,
    chat_conversation_id,
    flow_code,
    idempotency_key,
    promo_nombre,
    precio_fuente,
    precio_regular_referencia,
    revendedor_id,
    codigo_referido_snapshot
  ) VALUES (
    v_empresa_id,
    v_sorteo_id,
    NULL,
    v_cliente_id,
    v_wa,
    v_nombre,
    v_cedula,
    v_qty,
    v_monto_total,
    'PYG',
    'pendiente_revision',
    v_comp_url,
    v_validado_por,
    v_numero_orden,
    v_conv_id,
    v_flow_code,
    v_idem,
    v_promo_nombre,
    v_precio_fuente_ins,
    v_precio_regular_ref,
    v_revendedor_id,
    v_codigo_ref_snap
  )
  RETURNING id INTO v_entrada_id;

  FOR i IN 1..v_qty LOOP
    v_num := s.ultimo_numero_cupon + i;
    v_num_str := lpad(v_num::text, 4, '0');
    INSERT INTO dymaerp.sorteo_cupones (empresa_id, sorteo_id, entrada_id, numero_cupon)
    VALUES (v_empresa_id, v_sorteo_id, v_entrada_id, v_num_str);
  END LOOP;

  UPDATE dymaerp.sorteos SET
    total_boletos_vendidos = total_boletos_vendidos + v_qty,
    ultimo_numero_cupon = s.ultimo_numero_cupon + v_qty,
    ultimo_numero_orden = v_numero_orden,
    updated_at = now()
  WHERE id = v_sorteo_id;

  RETURN jsonb_build_object(
    'ok', true,
    'idempotent', false,
    'message', 'Orden y cupones creados',
    'entrada', jsonb_build_object(
      'id', v_entrada_id,
      'numero_orden', v_numero_orden,
      'cantidad_boletos', v_qty,
      'monto_total', v_monto_total,
      'promo_nombre', coalesce(v_promo_nombre, ''),
      'precio_fuente', v_precio_fuente_ins,
      'estado_pago', 'pendiente_revision'
    ),
    'cupones', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object('id', c.id, 'numero_cupon', c.numero_cupon)
        ORDER BY c.numero_cupon
      ), '[]'::jsonb)
      FROM dymaerp.sorteo_cupones c
      WHERE c.entrada_id = v_entrada_id
    )
  );

EXCEPTION
  WHEN unique_violation THEN
    SELECT e.id, e.numero_orden, e.estado_pago
    INTO v_existing
    FROM dymaerp.sorteo_entradas e
    WHERE e.idempotency_key = v_idem
    LIMIT 1;
    IF FOUND THEN
      SELECT
        e.cantidad_boletos,
        e.monto_total,
        e.promo_nombre,
        e.precio_fuente
      INTO v_cant_existente, v_mt_existente, v_promo_existente, v_pf_existente
      FROM dymaerp.sorteo_entradas e
      WHERE e.id = (v_existing).id;
      RETURN jsonb_build_object(
        'ok', true,
        'idempotent', true,
        'message', 'Orden ya existía (carrera concurrente)',
        'entrada', jsonb_build_object(
          'id', (v_existing).id,
          'numero_orden', (v_existing).numero_orden,
          'cantidad_boletos', coalesce(v_cant_existente, v_qty),
          'monto_total', v_mt_existente,
          'promo_nombre', coalesce(v_promo_existente, ''),
          'precio_fuente', coalesce(v_pf_existente, 'lista'),
          'estado_pago', (v_existing).estado_pago
        ),
        'cupones', (
          SELECT coalesce(jsonb_agg(
            jsonb_build_object('id', c.id, 'numero_cupon', c.numero_cupon)
            ORDER BY c.numero_cupon
          ), '[]'::jsonb)
          FROM dymaerp.sorteo_cupones c
          WHERE c.entrada_id = (v_existing).id
        )
      );
    END IF;
    RETURN jsonb_build_object('ok', false, 'message', 'Error de unicidad al crear orden');
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.sorteos_registrar_compra_n8n(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_empresa_id       uuid := (p->>'empresa_id')::uuid;
  v_sorteo_id        uuid := (p->>'sorteo_id')::uuid;
  v_wa               text := trim(p->>'whatsapp_numero');
  v_nombre           text := trim(p->>'nombre_completo');
  v_cedula           text := nullif(trim(p->>'cedula'), '');
  v_celular          text := nullif(trim(p->>'celular'), '');
  v_ciudad           text := nullif(trim(p->>'ciudad'), '');
  v_qty              int := coalesce((p->>'cantidad_boletos')::int, 0);
  v_fecha_pago       timestamptz := nullif(p->>'fecha_pago', '')::timestamptz;
  v_monto_pago       numeric := coalesce((p->>'monto_pago')::numeric, 0);
  v_banco            text := nullif(trim(p->>'banco_origen'), '');
  v_comp_url         text := p->>'comprobante_url';
  v_ultimo_msg       text := p->>'ultimo_mensaje';

  s                  record;
  v_cliente_id       uuid;
  v_conv_id          uuid;
  v_entrada_id       uuid;
  v_monto_total      numeric;
  i                  int;
  v_num              int;
  v_num_str          text;
BEGIN
  IF v_empresa_id IS NULL OR v_sorteo_id IS NULL OR v_wa = '' OR v_nombre = '' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Faltan datos obligatorios (empresa_id, sorteo_id, whatsapp_numero, nombre_completo)');
  END IF;
  IF v_qty < 1 THEN
    RETURN jsonb_build_object('ok', false, 'message', 'cantidad_boletos debe ser mayor a 0');
  END IF;

  SELECT * INTO s FROM dymaerp.sorteos WHERE id = v_sorteo_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'message', 'Sorteo no encontrado');
  END IF;
  IF s.empresa_id IS DISTINCT FROM v_empresa_id THEN
    RETURN jsonb_build_object('ok', false, 'message', 'El sorteo no pertenece a la empresa indicada');
  END IF;
  IF s.estado IS DISTINCT FROM 'activo' THEN
    RETURN jsonb_build_object('ok', false, 'message', 'El sorteo no está activo');
  END IF;
  IF s.total_boletos_vendidos + v_qty > s.max_boletos THEN
    RETURN jsonb_build_object('ok', false, 'message', 'No hay boletos disponibles para esta cantidad');
  END IF;

  v_monto_total := s.precio_por_boleto * v_qty;

  -- Cliente: por documento o teléfono en la empresa
  SELECT id INTO v_cliente_id
  FROM dymaerp.clientes
  WHERE empresa_id = v_empresa_id
    AND deleted_at IS NULL
    AND (
      (v_cedula IS NOT NULL AND documento IS NOT NULL AND trim(documento) = v_cedula)
      OR (v_celular IS NOT NULL AND telefono IS NOT NULL AND trim(telefono) = v_celular)
    )
  LIMIT 1;

  IF v_cliente_id IS NULL THEN
    INSERT INTO dymaerp.clientes (
      empresa_id, tipo_cliente, nombre_contacto, nombre, documento, telefono, ciudad, origen
    ) VALUES (
      v_empresa_id, 'persona', v_nombre, v_nombre, v_cedula, coalesce(v_celular, v_wa), v_ciudad, 'SORTEO'
    )
    RETURNING id INTO v_cliente_id;
  END IF;

  SELECT id INTO v_conv_id
  FROM dymaerp.sorteo_conversaciones
  WHERE sorteo_id = v_sorteo_id AND whatsapp_numero = v_wa AND activa = true
  LIMIT 1;

  IF v_conv_id IS NULL THEN
    INSERT INTO dymaerp.sorteo_conversaciones (
      empresa_id, sorteo_id, whatsapp_numero, cliente_id, estado, ultimo_mensaje, cantidad_boletos, datos_cliente
    ) VALUES (
      v_empresa_id, v_sorteo_id, v_wa, v_cliente_id, 'paid_confirmed', v_ultimo_msg, v_qty,
      jsonb_build_object('nombre_completo', v_nombre, 'cedula', v_cedula, 'celular', v_celular, 'ciudad', v_ciudad)
    )
    RETURNING id INTO v_conv_id;
  ELSE
    UPDATE dymaerp.sorteo_conversaciones SET
      cliente_id = coalesce(v_cliente_id, cliente_id),
      estado = 'paid_confirmed',
      ultimo_mensaje = coalesce(v_ultimo_msg, ultimo_mensaje),
      cantidad_boletos = v_qty,
      datos_cliente = coalesce(datos_cliente, '{}'::jsonb) || jsonb_build_object(
        'nombre_completo', v_nombre, 'cedula', v_cedula, 'celular', v_celular, 'ciudad', v_ciudad
      ),
      updated_at = now()
    WHERE id = v_conv_id;
  END IF;

  INSERT INTO dymaerp.sorteo_entradas (
    empresa_id, sorteo_id, conversacion_id, cliente_id, whatsapp_numero, nombre_participante, documento,
    cantidad_boletos, monto_total, moneda, estado_pago, fecha_pago, monto_pagado, banco_origen, comprobante_url, validado_por
  ) VALUES (
    v_empresa_id, v_sorteo_id, v_conv_id, v_cliente_id, v_wa, v_nombre, v_cedula,
    v_qty, v_monto_total, 'PYG', 'confirmado', v_fecha_pago, v_monto_pago, v_banco, v_comp_url, 'n8n'
  )
  RETURNING id INTO v_entrada_id;

  FOR i IN 1..v_qty LOOP
    v_num := s.ultimo_numero_cupon + i;
    v_num_str := lpad(v_num::text, 4, '0');
    INSERT INTO dymaerp.sorteo_cupones (empresa_id, sorteo_id, entrada_id, numero_cupon)
    VALUES (v_empresa_id, v_sorteo_id, v_entrada_id, v_num_str);
  END LOOP;

  UPDATE dymaerp.sorteos SET
    total_boletos_vendidos = total_boletos_vendidos + v_qty,
    ultimo_numero_cupon = s.ultimo_numero_cupon + v_qty,
    updated_at = now()
  WHERE id = v_sorteo_id;

  RETURN jsonb_build_object(
    'ok', true,
    'message', 'Compra registrada correctamente',
    'cliente', jsonb_build_object('id', v_cliente_id, 'nombre', v_nombre),
    'conversacion', jsonb_build_object('id', v_conv_id, 'estado', 'paid_confirmed'),
    'entrada', jsonb_build_object(
      'id', v_entrada_id,
      'cantidad_boletos', v_qty,
      'monto_total', v_monto_total,
      'estado_pago', 'confirmado'
    ),
    'cupones', (
      SELECT coalesce(jsonb_agg(
        jsonb_build_object('id', c.id, 'numero_cupon', c.numero_cupon)
        ORDER BY c.numero_cupon
      ), '[]'::jsonb)
      FROM dymaerp.sorteo_cupones c
      WHERE c.entrada_id = v_entrada_id
    )
  );
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.touch_cajas_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.touch_pedidos_caja_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.touch_producto_presentaciones_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.trg_clientes_tipo_servicio_requiere_catalogo()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  sch   text := TG_TABLE_SCHEMA;
  tslug text;
  ok    boolean;
BEGIN
  IF (TG_OP = 'INSERT' OR TG_OP = 'UPDATE') AND NEW.empresa_id IS NOT NULL THEN
    tslug := NEW.tipo_servicio_cliente;
    IF tslug IS NULL OR btrim(tslug) = '' THEN
      NEW.tipo_servicio_cliente := NULL;
    ELSE
      NEW.tipo_servicio_cliente := lower(btrim(tslug));
      tslug := NEW.tipo_servicio_cliente;
      EXECUTE format(
        $f$
        SELECT EXISTS(
          SELECT 1
          FROM %I.cliente_tipos_servicio_catalogo t
          WHERE t.empresa_id = $1
            AND t.slug = $2
        )
        $f$,
        sch
      ) INTO ok USING NEW.empresa_id, tslug;
      IF NOT coalesce(ok, false) THEN
        RAISE EXCEPTION 'tipo_servicio_cliente inexistente en el catálogo: % (empresa %, schema %)', tslug, NEW.empresa_id, sch
          USING ERRCODE = '23514';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$
;

CREATE OR REPLACE FUNCTION dymaerp.trg_usuario_modulos_validar_modulo_empresa()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_empresa_id uuid;
BEGIN
  SELECT u.empresa_id INTO v_empresa_id
  FROM dymaerp.usuarios u
  WHERE u.id = NEW.usuario_id;

  IF v_empresa_id IS NULL THEN
    RAISE EXCEPTION 'usuario_modulos: el usuario % no tiene empresa asignada', NEW.usuario_id
      USING ERRCODE = '23514';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM dymaerp.empresa_modulos em
    WHERE em.empresa_id = v_empresa_id
      AND em.modulo_id = NEW.modulo_id
      AND em.activo IS TRUE
  ) THEN
    RAISE EXCEPTION 'usuario_modulos: el módulo % no está habilitado para la empresa del usuario', NEW.modulo_id
      USING ERRCODE = '23514';
  END IF;

  RETURN NEW;
END;
$function$
;

-- ---------------------------------------------------------------------------
-- 1) TABLAS (135)
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS dymaerp.caja_movimientos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  caja_id uuid NOT NULL,
  tipo text NOT NULL,
  concepto text NOT NULL,
  monto numeric NOT NULL,
  medio_pago text DEFAULT 'efectivo'::text NOT NULL,
  usuario_id uuid,
  observacion text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  anulado_at timestamp with time zone,
  anulado_por_id uuid,
  anulado_motivo text,
  usuario_email text,
  anulado_por uuid,
  venta_id uuid,
  devolucion_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.cajas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  estado text DEFAULT 'abierta'::text NOT NULL,
  abierta_por uuid,
  cerrada_por uuid,
  fecha_apertura timestamp with time zone DEFAULT now() NOT NULL,
  fecha_cierre timestamp with time zone,
  monto_apertura numeric DEFAULT 0 NOT NULL,
  monto_cierre_contado numeric,
  monto_esperado_efectivo numeric,
  diferencia numeric,
  observacion_apertura text,
  observacion_cierre text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  numero_caja integer DEFAULT 1 NOT NULL,
  arqueo_apertura_json jsonb,
  arqueo_cierre_json jsonb
);

CREATE TABLE IF NOT EXISTS dymaerp.categorias_productos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  codigo text,
  descripcion text,
  parent_id uuid,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  imagen_url text
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_agents (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  is_online boolean DEFAULT false NOT NULL,
  max_conversations integer DEFAULT 5 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  receives_new_chats boolean DEFAULT true NOT NULL,
  priority_in_queue integer DEFAULT 0 NOT NULL,
  operational_status_changed_at timestamp with time zone DEFAULT now() NOT NULL,
  last_heartbeat_at timestamp with time zone,
  operational_status text DEFAULT 'ready'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_campaign_events (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  campaign_id uuid NOT NULL,
  recipient_id uuid,
  event_type text NOT NULL,
  event_payload_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_campaign_jobs (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  campaign_id uuid NOT NULL,
  status text DEFAULT 'pending'::text NOT NULL,
  batch_size integer DEFAULT 25 NOT NULL,
  locked_at timestamp with time zone,
  locked_by text,
  attempts integer DEFAULT 0 NOT NULL,
  last_error text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_campaign_recipients (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  campaign_id uuid NOT NULL,
  row_number integer NOT NULL,
  phone_raw text,
  phone_e164 text NOT NULL,
  contact_id uuid,
  conversation_id uuid,
  row_payload_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  mapped_variables_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  status text DEFAULT 'pending'::text NOT NULL,
  validation_error text,
  provider_message_id text,
  provider_payload_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  last_status_raw_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  error_code text,
  error_message text,
  queued_at timestamp with time zone,
  sent_at timestamp with time zone,
  failed_at timestamp with time zone,
  first_reply_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_campaign_templates (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  channel_id uuid NOT NULL,
  provider text NOT NULL,
  provider_template_id text,
  name text NOT NULL,
  language text DEFAULT 'es'::text NOT NULL,
  category text,
  status text DEFAULT 'unknown'::text NOT NULL,
  components_json jsonb DEFAULT '[]'::jsonb NOT NULL,
  variable_schema_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  provider_payload_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  last_synced_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_campaigns (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  name text NOT NULL,
  channel_id uuid NOT NULL,
  queue_id uuid,
  provider text NOT NULL,
  template_id uuid,
  template_name text NOT NULL,
  template_language text DEFAULT 'es'::text NOT NULL,
  template_category text,
  template_components_json jsonb DEFAULT '[]'::jsonb NOT NULL,
  variable_mapping_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  import_original_filename text,
  import_storage_bucket text,
  import_storage_path text,
  status text DEFAULT 'draft'::text NOT NULL,
  total_count integer DEFAULT 0 NOT NULL,
  valid_count integer DEFAULT 0 NOT NULL,
  invalid_count integer DEFAULT 0 NOT NULL,
  pending_count integer DEFAULT 0 NOT NULL,
  queued_count integer DEFAULT 0 NOT NULL,
  sent_count integer DEFAULT 0 NOT NULL,
  failed_count integer DEFAULT 0 NOT NULL,
  replied_count integer DEFAULT 0 NOT NULL,
  send_config_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_by uuid,
  started_at timestamp with time zone,
  completed_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_channel_quick_replies (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  channel_id uuid NOT NULL,
  title text NOT NULL,
  body text NOT NULL,
  sort_order integer DEFAULT 0 NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_channels (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  type text DEFAULT 'whatsapp'::text NOT NULL,
  meta_phone_number_id text,
  config jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  nombre text,
  provider text DEFAULT 'meta'::text NOT NULL,
  provider_channel_id text,
  activo boolean DEFAULT true NOT NULL,
  whatsapp_access_token text,
  connection_mode text,
  config_status text DEFAULT 'incomplete'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_comprobante_validaciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  flow_session_id uuid NOT NULL,
  channel_id uuid,
  flow_code text DEFAULT ''::text NOT NULL,
  comprobante_url text,
  comprobante_media_id text,
  comprobante_hash text NOT NULL,
  estado_validacion text DEFAULT 'pendiente'::text NOT NULL,
  motivo_validacion text,
  ocr_text_raw text,
  ocr_monto text,
  ocr_referencia text,
  ocr_fecha text,
  ocr_hora text,
  ocr_banco text,
  ocr_fingerprint text,
  sorteo_entrada_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  monto_validacion_esperado_gs bigint,
  monto_validacion_ocr_gs bigint,
  monto_validacion_diferencia_gs bigint,
  monto_validacion_status text,
  bank_val_titular_esperado text,
  bank_val_cuenta_esperada text,
  bank_val_alias_esperado text,
  bank_val_titular_ocr text,
  bank_val_cuenta_ocr text,
  bank_val_alias_ocr text,
  bank_val_coincidencias integer,
  bank_val_min_requeridas integer,
  bank_val_status text,
  manual_approval_usuario_id uuid,
  manual_approval_at timestamp with time zone,
  manual_approval_source text,
  manual_approval_note text,
  previous_estado_validacion text,
  previous_motivo_validacion text
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_contacts (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  phone_number text NOT NULL,
  name text,
  cliente_id uuid,
  crm_prospecto_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  phone_normalized text,
  last_routed_chat_agent_id uuid,
  last_routed_at timestamp with time zone,
  last_routed_channel_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_conversation_closures (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  queue_id uuid,
  closure_state_id uuid,
  closure_substate_id uuid,
  closure_state_label text NOT NULL,
  closure_substate_label text NOT NULL,
  comment text NOT NULL,
  closed_at timestamp with time zone DEFAULT now() NOT NULL,
  closed_by_usuario_id uuid NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_conversations (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  channel_id uuid NOT NULL,
  contact_id uuid NOT NULL,
  status text DEFAULT 'open'::text NOT NULL,
  last_message_at timestamp with time zone,
  last_message_preview text,
  unread_count integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  flow_code text,
  flow_current_node text,
  flow_status text DEFAULT 'bot'::text NOT NULL,
  human_taken_over boolean DEFAULT false NOT NULL,
  active_flow_session_id uuid,
  first_revendedor_id uuid,
  first_referral_captured_at timestamp with time zone,
  assigned_agent_id uuid,
  queue_id uuid,
  priority text DEFAULT 'medium'::text NOT NULL,
  closed_at timestamp with time zone,
  closed_by_usuario_id uuid,
  initial_assignment_at timestamp with time zone,
  first_human_response_at timestamp with time zone,
  initial_reassign_count integer DEFAULT 0 NOT NULL,
  assignment_wait_code text
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_empresa_operator_roles (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  role text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_data (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  flow_code text NOT NULL,
  field_name text NOT NULL,
  field_value text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  flow_session_id uuid NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_events (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  flow_code text,
  node_code text,
  event_type text NOT NULL,
  selected_option_id uuid,
  meta_button_id text,
  payload jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  flow_session_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_node_blocks (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  node_id uuid NOT NULL,
  block_type text NOT NULL,
  content_text text,
  media_url text,
  sort_order integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_nodes (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  flow_code text NOT NULL,
  node_code text NOT NULL,
  message_text text,
  node_type text NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  save_as_field text,
  next_node_code text,
  crm_action_type text,
  crm_action_config jsonb DEFAULT '{}'::jsonb NOT NULL,
  sort_order integer NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_options (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  node_id uuid NOT NULL,
  label text NOT NULL,
  option_value text NOT NULL,
  meta_button_id text NOT NULL,
  next_node_code text,
  sort_order integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  option_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
  group_title text,
  group_order integer DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_recontact_rules (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  flow_code text NOT NULL,
  nombre text NOT NULL,
  descripcion text,
  activo boolean DEFAULT false NOT NULL,
  prioridad integer DEFAULT 100 NOT NULL,
  included_node_codes jsonb DEFAULT '[]'::jsonb NOT NULL,
  excluded_node_codes jsonb DEFAULT '[]'::jsonb NOT NULL,
  idle_after_seconds integer DEFAULT 3600 NOT NULL,
  max_attempts integer DEFAULT 1 NOT NULL,
  cooldown_seconds integer DEFAULT 86400 NOT NULL,
  schedule_config jsonb DEFAULT '{}'::jsonb NOT NULL,
  guard_config jsonb DEFAULT '{}'::jsonb NOT NULL,
  message_config jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_recontact_runs (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  rule_id uuid NOT NULL,
  flow_code text NOT NULL,
  conversation_id uuid,
  flow_session_id uuid,
  decision text NOT NULL,
  skip_reason text,
  attempt_no integer,
  correlation_id text,
  payload_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flow_sessions (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  flow_code text NOT NULL,
  status text DEFAULT 'active'::text NOT NULL,
  started_at timestamp with time zone DEFAULT now() NOT NULL,
  ended_at timestamp with time zone,
  end_reason text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  revendedor_id uuid,
  codigo_referido_snapshot text,
  referral_source text
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_flows (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  flow_code text NOT NULL,
  label text,
  channel text DEFAULT 'whatsapp'::text NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  sorteo_id uuid,
  sorteo_datos_incompletos_message text,
  flow_config jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_messages (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  wa_message_id text,
  from_me boolean DEFAULT false NOT NULL,
  message_type text DEFAULT 'text'::text NOT NULL,
  content text,
  raw_payload jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  sender_type text DEFAULT 'system'::text,
  sent_by_user_id uuid,
  sent_by_user_name text,
  automation_source text,
  whatsapp_delivery_status text,
  whatsapp_delivered_at timestamp with time zone,
  whatsapp_read_at timestamp with time zone
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_omnicanal_work_schedules (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  time_start time without time zone NOT NULL,
  time_end time without time zone NOT NULL,
  days_of_week smallint[] DEFAULT '{}'::smallint[] NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_queue_channels (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  channel_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_queue_closure_states (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  label text NOT NULL,
  sort_order integer DEFAULT 0 NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_queue_closure_substates (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  closure_state_id uuid NOT NULL,
  label text NOT NULL,
  sort_order integer DEFAULT 0 NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_queue_supervisors (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  queue_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_queues (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  is_active boolean DEFAULT true NOT NULL,
  channel_type text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  descripcion text,
  distribution_strategy text DEFAULT 'least_load'::text NOT NULL,
  priority integer DEFAULT 0 NOT NULL,
  routing_config jsonb DEFAULT '{}'::jsonb NOT NULL,
  assignment_state jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_routing_events (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  conversation_id uuid NOT NULL,
  queue_id uuid,
  event_type text NOT NULL,
  payload jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_supervisor_agents (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  supervisor_usuario_id uuid NOT NULL,
  agent_usuario_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.chat_usuario_omnicanal (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  omnicanal_agent_enabled boolean DEFAULT false NOT NULL,
  work_schedule_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.cliente_historial (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  suscripcion_id uuid,
  tipo text NOT NULL,
  accion text NOT NULL,
  plan_anterior_id uuid,
  plan_nuevo_id uuid,
  plan_anterior_nombre text,
  plan_nuevo_nombre text,
  modo text,
  factura_id uuid,
  plan_pendiente_vigente_desde date,
  creado_por_auth_user_id uuid,
  creado_por_email text,
  detalle jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.cliente_obligaciones_tributarias (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_perfil_id uuid NOT NULL,
  obligacion_catalogo_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.cliente_perfil_tributario (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  perfil_activo boolean DEFAULT false NOT NULL,
  dv text,
  razon_social_fiscal text,
  clave_tributaria_encrypted text,
  honorario_mensual numeric,
  honorario_anual numeric,
  notas_tributarias text,
  obligacion_otro_detalle text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  dia_vencimiento_tributario smallint
);

CREATE TABLE IF NOT EXISTS dymaerp.cliente_tipos_servicio_catalogo (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  slug text NOT NULL,
  nombre text NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  orden smallint DEFAULT 0 NOT NULL,
  es_sistema boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.clientes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid,
  nombre text,
  telefono text,
  email text,
  direccion text,
  created_at timestamp without time zone DEFAULT now(),
  tipo_cliente text DEFAULT 'empresa'::text,
  empresa text,
  ruc text,
  documento text,
  telefono_secundario text,
  email_secundario text,
  ciudad text,
  pais text,
  sitio_web text,
  instagram text,
  linkedin text,
  categoria_cliente text,
  industria text,
  valor_cliente numeric,
  condicion_pago text,
  moneda_preferida text DEFAULT 'GS'::text,
  vendedor_asignado text,
  origen text DEFAULT 'MANUAL'::text,
  prospecto_id integer,
  estado text DEFAULT 'activo'::text,
  notas jsonb DEFAULT '[]'::jsonb,
  updated_at timestamp with time zone DEFAULT now(),
  nombre_contacto text,
  created_by_user_id uuid,
  created_by_nombre text,
  tipo_servicio_cliente text,
  deleted_at timestamp with time zone,
  deleted_by_user_id uuid,
  deletion_reason text,
  baja_operativa_at timestamp with time zone,
  baja_operativa_by_user_id uuid,
  baja_operativa_motivo text,
  baja_operativa_anulo_factura boolean,
  baja_operativa_by_nombre text,
  vendedor_usuario_id uuid,
  sifen_receptor_extranjero boolean DEFAULT false NOT NULL,
  sifen_codigo_pais text,
  sifen_tipo_doc_receptor smallint,
  sifen_receptor_manual boolean DEFAULT false NOT NULL,
  sifen_receptor_naturaleza text,
  sifen_ti_ope smallint,
  sifen_num_id_de text,
  sifen_direccion_de text,
  sifen_num_casa_de integer,
  sifen_descripcion_tipo_doc text,
  plan_comercial_id uuid,
  usa_nota_remision boolean DEFAULT false NOT NULL,
  project_manager_id uuid,
  sifen_receptor_innominado boolean DEFAULT false NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.cobros_clientes (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  cuenta_por_cobrar_id uuid NOT NULL,
  venta_id uuid,
  fecha_pago timestamp with time zone DEFAULT now() NOT NULL,
  monto numeric DEFAULT 0 NOT NULL,
  metodo_pago text DEFAULT 'efectivo'::text NOT NULL,
  entidad_bancaria_id uuid,
  referencia text,
  titular text,
  observaciones text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  usuario_id uuid,
  usuario_nombre text,
  entidad_nombre_snapshot text,
  conciliacion_estado text DEFAULT 'pendiente'::text NOT NULL,
  conciliado_at timestamp with time zone,
  conciliado_por text
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_ajustes (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  periodo_id uuid,
  linea_id uuid,
  monto numeric(18,2) NOT NULL,
  motivo text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_equipo_miembros (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  equipo_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_equipos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  supervisor_usuario_id uuid NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_escalas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  politica_id uuid NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  desde_monto numeric(18,2) NOT NULL,
  hasta_monto numeric(18,2),
  porcentaje_comision numeric(9,4) NOT NULL,
  premio_fijo numeric(18,2),
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_lineas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  periodo_id uuid NOT NULL,
  usuario_vendedor_id uuid NOT NULL,
  fuente_tipo text,
  fuente_id uuid,
  monto_base numeric(18,2) DEFAULT 0 NOT NULL,
  monto_comision numeric(18,2) DEFAULT 0 NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_periodos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  politica_id uuid NOT NULL,
  estado text DEFAULT 'borrador'::text NOT NULL,
  fecha_inicio timestamp with time zone NOT NULL,
  fecha_fin timestamp with time zone NOT NULL,
  label text,
  congelado_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_politica_versiones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  politica_id uuid NOT NULL,
  version_no integer NOT NULL,
  nombre text NOT NULL,
  activo boolean NOT NULL,
  base_calculo text NOT NULL,
  timezone text NOT NULL,
  modo_periodo text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.comision_politicas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  base_calculo text NOT NULL,
  timezone text DEFAULT 'America/Asuncion'::text NOT NULL,
  modo_periodo text DEFAULT 'mensual_penultimo_dia_habil'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid,
  updated_by uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.compras (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proveedor_id uuid NOT NULL,
  proveedor_nombre text NOT NULL,
  producto_id uuid NOT NULL,
  producto_nombre text NOT NULL,
  cantidad numeric NOT NULL,
  moneda text DEFAULT 'PYG'::text NOT NULL,
  tipo_cambio numeric DEFAULT 1 NOT NULL,
  costo_unitario_original numeric NOT NULL,
  costo_unitario numeric NOT NULL,
  iva_tipo text DEFAULT '10'::text NOT NULL,
  subtotal numeric NOT NULL,
  monto_iva numeric NOT NULL,
  total numeric NOT NULL,
  precio_venta numeric NOT NULL,
  margen_venta numeric,
  tipo_pago text DEFAULT 'contado'::text NOT NULL,
  plazo_dias integer,
  nro_timbrado text NOT NULL,
  numero_control text NOT NULL,
  estado text DEFAULT 'registrada'::text NOT NULL,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid,
  usuario_nombre text,
  comprobante_url text,
  comprobante_storage_path text,
  comprobante_nombre text,
  comprobante_mime_type text,
  numero_factura text,
  orden_compra_numero text,
  orden_compra_item_id uuid,
  fecha_factura date,
  observacion text,
  anulada_at timestamp with time zone,
  anulada_por uuid,
  anulada_motivo text
);

CREATE TABLE IF NOT EXISTS dymaerp.crm_etapas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  codigo text NOT NULL,
  nombre text NOT NULL,
  color text DEFAULT 'gray'::text NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.crm_notas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  prospecto_id uuid NOT NULL,
  texto text NOT NULL,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.crm_prospectos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  numero_control text NOT NULL,
  empresa text NOT NULL,
  contacto text NOT NULL,
  email text,
  telefono text,
  servicio text NOT NULL,
  valor_estimado numeric DEFAULT 0,
  etapa text DEFAULT 'LEAD'::text NOT NULL,
  proxima_accion text,
  fecha_proxima_accion date,
  creado_por text,
  responsable text,
  cliente_creado boolean DEFAULT false,
  fecha_creacion timestamp with time zone DEFAULT now() NOT NULL,
  fecha_actualizacion timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  origen_creacion text DEFAULT 'manual'::text NOT NULL,
  origen_detalle text,
  observaciones text
);

CREATE TABLE IF NOT EXISTS dymaerp.cuentas_por_cobrar (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  numero_venta text,
  fecha_emision date DEFAULT CURRENT_DATE NOT NULL,
  fecha_vencimiento date,
  moneda text DEFAULT 'PYG'::text NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  saldo numeric DEFAULT 0 NOT NULL,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  observaciones text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.dashboard_views (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  slug text NOT NULL,
  nombre text NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.devoluciones_venta (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  numero_devolucion text NOT NULL,
  venta_id uuid NOT NULL,
  venta_numero_control text,
  venta_fecha timestamp with time zone,
  cliente_id uuid,
  cliente_nombre text,
  tipo text DEFAULT 'parcial'::text NOT NULL,
  resolucion text DEFAULT 'reembolso'::text NOT NULL,
  estado text DEFAULT 'confirmada'::text NOT NULL,
  motivo text,
  total_devuelto numeric DEFAULT 0 NOT NULL,
  total_entregado numeric DEFAULT 0 NOT NULL,
  diferencia numeric DEFAULT 0 NOT NULL,
  metodo_reembolso text,
  caja_id uuid,
  caja_movimiento_id uuid,
  requiere_nota_credito boolean DEFAULT false NOT NULL,
  idempotency_key text,
  created_by uuid,
  usuario_nombre text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  anulada_at timestamp with time zone,
  anulada_por uuid,
  anulada_motivo text,
  anulada_caja_movimiento_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.devoluciones_venta_cambios (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  devolucion_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  producto_nombre text NOT NULL,
  sku text,
  cantidad numeric NOT NULL,
  precio_unitario numeric NOT NULL,
  tipo_iva text DEFAULT '10%'::text NOT NULL,
  monto_iva numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.devoluciones_venta_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  devolucion_id uuid NOT NULL,
  venta_item_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  producto_nombre text NOT NULL,
  sku text,
  cantidad_vendida numeric NOT NULL,
  cantidad_devuelta numeric NOT NULL,
  precio_unitario numeric NOT NULL,
  tipo_iva text NOT NULL,
  monto_iva numeric DEFAULT 0 NOT NULL,
  total_devuelto numeric DEFAULT 0 NOT NULL,
  condicion text DEFAULT 'buen_estado'::text NOT NULL,
  reintegra_stock boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.empresa_autoimpresor_config (
  empresa_id uuid NOT NULL,
  activo boolean DEFAULT false NOT NULL,
  ruc_emisor text,
  razon_social_emisor text,
  nombre_fantasia text,
  direccion_matriz text,
  telefono text,
  timbrado_numero text,
  timbrado_inicio_vigencia date,
  timbrado_fin_vigencia date,
  establecimiento_codigo text,
  punto_expedicion_codigo text,
  numero_actual integer,
  numero_inicial integer,
  numero_final integer,
  tipo_documento_default text DEFAULT 'factura'::text NOT NULL,
  formato_impresion_default text DEFAULT 'pdf_a4'::text NOT NULL,
  leyenda_papel_termico text,
  observaciones text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.empresa_dashboard_views (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  dashboard_view_id uuid NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.empresa_facturacion_modo (
  empresa_id uuid NOT NULL,
  modo text DEFAULT 'sin_factura_fiscal'::text NOT NULL,
  impresion_tipo_default text DEFAULT 'pdf_a4'::text NOT NULL,
  imprimir_al_confirmar boolean DEFAULT false NOT NULL,
  preguntar_datos_al_confirmar boolean DEFAULT false NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.empresa_modulos (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  created_at timestamp without time zone DEFAULT now() NOT NULL,
  empresa_id uuid NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  modulo_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.empresa_sifen_config (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  ambiente text DEFAULT 'test'::text NOT NULL,
  ruc text NOT NULL,
  razon_social text NOT NULL,
  timbrado_numero text NOT NULL,
  establecimiento text NOT NULL,
  punto_expedicion text NOT NULL,
  csc text,
  certificado_path text,
  certificado_vencimiento timestamp with time zone,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  certificado_password_encrypted text,
  direccion_fiscal text,
  timbrado_fecha_inicio_vigencia date,
  actividad_economica_codigo text,
  actividad_economica_descripcion text,
  sifen_plazo_cancelacion_horas integer DEFAULT 48 NOT NULL,
  kude_logo_path text,
  kude_color_primario text,
  kude_color_primario_fill text
);

CREATE TABLE IF NOT EXISTS dymaerp.empresas (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  nombre_empresa text NOT NULL,
  ruc text,
  telefono text,
  email text,
  direccion text,
  pais text DEFAULT 'PARAGUAY'::text,
  plan text,
  estado text DEFAULT 'ACTIVA'::text,
  created_at timestamp without time zone DEFAULT now(),
  data_schema text,
  gestion_tributaria_clientes boolean DEFAULT false NOT NULL,
  ofertas_countdown_end timestamp with time zone
);

CREATE TABLE IF NOT EXISTS dymaerp.entidades_bancarias (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  tipo text,
  activo boolean DEFAULT true NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  codigo text
);

CREATE TABLE IF NOT EXISTS dymaerp.factura_autoimpresor (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  numero_secuencia integer NOT NULL,
  numero_completo text NOT NULL,
  establecimiento_codigo text NOT NULL,
  punto_expedicion_codigo text NOT NULL,
  timbrado_numero text NOT NULL,
  timbrado_inicio_vigencia date,
  timbrado_fin_vigencia date,
  condicion text DEFAULT 'contado'::text NOT NULL,
  gravado_10 numeric DEFAULT 0 NOT NULL,
  iva_10 numeric DEFAULT 0 NOT NULL,
  gravado_5 numeric DEFAULT 0 NOT NULL,
  iva_5 numeric DEFAULT 0 NOT NULL,
  exentas numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  emitida_at timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.factura_correlativos (
  empresa_id uuid NOT NULL,
  prefijo text DEFAULT 'FAC-'::text NOT NULL,
  ultimo_numero bigint DEFAULT 0 NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.factura_electronica (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  factura_id uuid NOT NULL,
  estado_sifen text DEFAULT 'borrador'::text NOT NULL,
  cdc text,
  xml_path text,
  kude_url text,
  qr_data text,
  error text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  xml_firmado_path text,
  sifen_d_prot_cons_lote text,
  sifen_ultima_respuesta_recibe_lote jsonb,
  sifen_ultima_respuesta_consulta_lote jsonb,
  sifen_aprobado_at timestamp with time zone,
  sifen_cancelado_at timestamp with time zone,
  sifen_cancelacion_motivo text,
  sifen_regeneracion_seq integer DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.factura_electronica_evento (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  factura_electronica_id uuid NOT NULL,
  tipo text NOT NULL,
  detalle jsonb,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.factura_items (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  factura_id uuid NOT NULL,
  empresa_id uuid NOT NULL,
  descripcion text NOT NULL,
  cantidad numeric DEFAULT 1 NOT NULL,
  precio_unitario numeric DEFAULT 0 NOT NULL,
  subtotal numeric DEFAULT 0 NOT NULL,
  iva numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.facturas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  numero_factura text NOT NULL,
  fecha date NOT NULL,
  fecha_vencimiento date NOT NULL,
  monto numeric NOT NULL,
  saldo numeric DEFAULT 0 NOT NULL,
  estado text DEFAULT 'Pendiente'::text NOT NULL,
  tipo text NOT NULL,
  moneda text DEFAULT 'GS'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  suscripcion_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.gastos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  categoria text,
  descripcion text,
  monto numeric(12,2) NOT NULL,
  tipo text DEFAULT 'variable'::text NOT NULL,
  recurrente boolean DEFAULT false NOT NULL,
  frecuencia text,
  fecha date NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  descuenta_caja boolean DEFAULT false NOT NULL,
  caja_movimiento_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.imports_audit (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  entidad text NOT NULL,
  filename text,
  total_rows integer DEFAULT 0 NOT NULL,
  inserted_count integer DEFAULT 0 NOT NULL,
  updated_count integer DEFAULT 0 NOT NULL,
  skipped_count integer DEFAULT 0 NOT NULL,
  error_count integer DEFAULT 0 NOT NULL,
  warning_count integer DEFAULT 0 NOT NULL,
  errors_json jsonb,
  warnings_json jsonb,
  created_by text,
  usuario_nombre text,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.inventario_stock_ubicacion (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  ubicacion_id uuid NOT NULL,
  stock_actual numeric DEFAULT 0 NOT NULL,
  stock_minimo numeric,
  stock_maximo numeric,
  es_principal boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.inventario_ubicaciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  codigo text,
  tipo text DEFAULT 'deposito'::text NOT NULL,
  parent_id uuid,
  descripcion text,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.marketing_calendarios (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid,
  mes text,
  semana integer,
  fecha_inicio date,
  fecha_fin date,
  estado_calendario text DEFAULT 'pendiente'::text NOT NULL,
  enviado_estado text DEFAULT 'no_enviado'::text NOT NULL,
  aprobado_estado text DEFAULT 'pendiente'::text NOT NULL,
  observaciones text,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_by uuid,
  updated_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.marketing_comentarios (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  pieza_id uuid NOT NULL,
  usuario_id uuid,
  comentario text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.marketing_historial_estados (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  pieza_id uuid NOT NULL,
  campo text NOT NULL,
  estado_anterior text,
  estado_nuevo text,
  changed_by uuid,
  changed_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.marketing_piezas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  calendario_id uuid,
  cliente_id uuid,
  titulo text NOT NULL,
  tipo_pieza text,
  canal text,
  responsable_id uuid,
  fecha_limite date,
  fecha_publicacion date,
  prioridad text DEFAULT 'media'::text NOT NULL,
  estado_produccion text DEFAULT 'por_hacer'::text NOT NULL,
  estado_cliente text DEFAULT 'no_enviado'::text NOT NULL,
  estado_publicacion text DEFAULT 'pendiente'::text NOT NULL,
  link_archivo text,
  observaciones text,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_by uuid,
  updated_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.marketing_tasks (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  titulo text NOT NULL,
  descripcion text,
  tipo_contenido text NOT NULL,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  fecha_entrega date NOT NULL,
  responsable_user_id uuid,
  prioridad text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  suscripcion_id uuid,
  plan_id uuid,
  generada_automaticamente boolean DEFAULT false NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.modulos (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  nombre text,
  descripcion text,
  slug text
);

CREATE TABLE IF NOT EXISTS dymaerp.movimientos_inventario (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  producto_nombre text NOT NULL,
  producto_sku text NOT NULL,
  tipo text NOT NULL,
  cantidad numeric NOT NULL,
  costo_unitario numeric DEFAULT 0 NOT NULL,
  origen text NOT NULL,
  referencia text,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  venta_id uuid,
  created_by uuid,
  usuario_nombre text,
  produccion_id uuid,
  anulado_at timestamp with time zone,
  anulado_por uuid,
  devolucion_id uuid,
  ubicacion_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.nota_credito (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  factura_id uuid NOT NULL,
  monto numeric NOT NULL,
  motivo text NOT NULL,
  observacion_interna text,
  estado_erp text DEFAULT 'borrador'::text NOT NULL,
  created_by_user_id uuid,
  created_by_email_snapshot text,
  created_by_nombre_snapshot text,
  saldo_previo_snapshot numeric NOT NULL,
  monto_factura_snapshot numeric NOT NULL,
  suma_pagos_snapshot numeric NOT NULL,
  moneda_snapshot text NOT NULL,
  factura_electronica_origen_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.nota_credito_electronica (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nota_credito_id uuid NOT NULL,
  estado_sifen text DEFAULT 'sin_envio'::text NOT NULL,
  cdc text,
  cdc_factura_origen text,
  xml_path text,
  xml_firmado_path text,
  kude_url text,
  response_json jsonb,
  error text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  sifen_d_prot_cons_lote text,
  sifen_ultima_respuesta_recibe_lote jsonb,
  sifen_ultima_respuesta_consulta_lote jsonb,
  sifen_aprobado_at timestamp with time zone,
  last_response_json jsonb,
  last_error text
);

CREATE TABLE IF NOT EXISTS dymaerp.nota_credito_evento (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nota_credito_id uuid NOT NULL,
  actor_user_id uuid,
  tipo_evento text NOT NULL,
  detalle_json jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.notas_remision (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  numero text NOT NULL,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  emisor text NOT NULL,
  ubicacion_origen_id uuid NOT NULL,
  ubicacion_destino_id uuid,
  motivo text DEFAULT 'traslado'::text NOT NULL,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  motivo_rechazo text,
  aprobada_at timestamp with time zone,
  aprobada_por text,
  transportista text,
  ruc_transportista text,
  conductor text,
  ci_conductor text,
  chapa text,
  fecha_inicio_traslado date,
  fecha_fin_traslado date,
  observaciones text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  destino_tipo text DEFAULT 'deposito'::text NOT NULL,
  cliente_id uuid,
  destino_nombre text,
  destino_direccion text,
  destino_ciudad text
);

CREATE TABLE IF NOT EXISTS dymaerp.notas_remision_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  nota_remision_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  cantidad numeric NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.notificaciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  tipo text NOT NULL,
  titulo text NOT NULL,
  mensaje text NOT NULL,
  producto_id uuid,
  url text,
  leida boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.obligaciones_tributarias_catalogo (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  slug text NOT NULL,
  nombre text NOT NULL,
  requiere_detalle_otro boolean DEFAULT false NOT NULL,
  orden smallint DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.omnichannel_routes (
  meta_phone_number_id text NOT NULL,
  empresa_id uuid NOT NULL,
  channel_id uuid NOT NULL,
  data_schema text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.ordenes_compra (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  numero_oc text NOT NULL,
  proveedor_id uuid NOT NULL,
  proveedor_nombre text DEFAULT ''::text NOT NULL,
  producto_id uuid NOT NULL,
  producto_nombre text DEFAULT ''::text NOT NULL,
  cantidad numeric DEFAULT 0 NOT NULL,
  moneda text DEFAULT 'PYG'::text NOT NULL,
  tipo_cambio numeric DEFAULT 1 NOT NULL,
  costo_unitario_original numeric DEFAULT 0 NOT NULL,
  costo_unitario numeric DEFAULT 0 NOT NULL,
  iva_tipo text DEFAULT '10'::text NOT NULL,
  subtotal numeric DEFAULT 0 NOT NULL,
  monto_iva numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  precio_venta numeric DEFAULT 0 NOT NULL,
  margen_venta numeric,
  tipo_pago text DEFAULT 'contado'::text NOT NULL,
  plazo_dias integer,
  estado text DEFAULT 'abierta'::text NOT NULL,
  observacion text,
  compra_numero_control text,
  recibida_at timestamp with time zone,
  cancelada_at timestamp with time zone,
  cancelada_motivo text,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid,
  usuario_nombre text,
  cantidad_recibida numeric DEFAULT 0 NOT NULL,
  cancelada_por uuid,
  nro_timbrado text,
  numero_factura text,
  comprobante_url text,
  comprobante_storage_path text,
  comprobante_nombre text,
  comprobante_mime_type text
);

CREATE TABLE IF NOT EXISTS dymaerp.pagos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  factura_id uuid NOT NULL,
  monto numeric NOT NULL,
  fecha_pago date NOT NULL,
  metodo_pago text DEFAULT 'efectivo'::text NOT NULL,
  referencia text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  cliente_id uuid,
  usuario_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.pedidos_caja (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  titulo text NOT NULL,
  cliente_id uuid,
  cliente_nombre text,
  cliente_telefono text,
  observacion text,
  items jsonb DEFAULT '[]'::jsonb NOT NULL,
  total_estimado numeric DEFAULT 0 NOT NULL,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  armado_por_id uuid,
  armado_por_email text,
  venta_id uuid,
  venta_numero text,
  facturado_at timestamp with time zone,
  cancelado_por_id uuid,
  cancelado_motivo text,
  cancelado_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  numero text,
  abierto_por_id uuid,
  abierto_por_email text,
  abierto_at timestamp with time zone,
  en_cola_caja boolean DEFAULT true NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.planes (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  codigo_plan text NOT NULL,
  nombre text NOT NULL,
  descripcion text,
  precio numeric NOT NULL,
  moneda text DEFAULT 'GS'::text NOT NULL,
  periodicidad text DEFAULT 'mensual'::text NOT NULL,
  limite_usuarios integer,
  limite_clientes integer,
  limite_facturas integer,
  estado text DEFAULT 'activo'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  es_plan_marketing boolean DEFAULT false NOT NULL,
  plantilla_operativa jsonb
);

CREATE TABLE IF NOT EXISTS dymaerp.presupuesto_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  presupuesto_id uuid NOT NULL,
  producto_id uuid,
  producto_nombre text NOT NULL,
  sku text,
  cantidad numeric NOT NULL,
  unidad_medida text,
  precio_unitario numeric DEFAULT 0 NOT NULL,
  iva_tipo text DEFAULT '10%'::text NOT NULL,
  subtotal numeric DEFAULT 0 NOT NULL,
  monto_iva numeric DEFAULT 0 NOT NULL,
  descuento numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  costo_unitario numeric
);

CREATE TABLE IF NOT EXISTS dymaerp.presupuestos (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid,
  cliente_nombre text NOT NULL,
  cliente_ruc text,
  cliente_telefono text,
  cliente_direccion text,
  numero_control text NOT NULL,
  estado text DEFAULT 'creado'::text NOT NULL,
  moneda text DEFAULT 'PYG'::text NOT NULL,
  subtotal numeric DEFAULT 0 NOT NULL,
  monto_iva numeric DEFAULT 0 NOT NULL,
  descuento_total numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  validez_dias integer,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  fecha_vencimiento date,
  forma_pago text,
  plazo_entrega text,
  observaciones text,
  convertido_pedido_id uuid,
  convertido_venta_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  condicion text DEFAULT 'contado'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.produccion_items (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  produccion_id uuid NOT NULL,
  insumo_producto_id uuid NOT NULL,
  insumo_nombre text NOT NULL,
  cantidad numeric NOT NULL,
  unidad_medida text,
  costo_unitario numeric DEFAULT 0 NOT NULL,
  subcosto numeric DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.producciones (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  receta_id uuid,
  producto_id uuid NOT NULL,
  producto_nombre text NOT NULL,
  cantidad_fabricada numeric NOT NULL,
  rendimiento_cantidad numeric DEFAULT 1 NOT NULL,
  unidad_rendimiento text,
  costo_total numeric DEFAULT 0 NOT NULL,
  costo_unitario numeric DEFAULT 0 NOT NULL,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  usuario_id uuid,
  usuario_nombre text,
  observaciones text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.producto_categorias (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  categoria_id uuid NOT NULL,
  es_principal boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.producto_presentaciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  nombre text NOT NULL,
  cantidad_base numeric NOT NULL,
  precio_venta numeric,
  es_default boolean DEFAULT false NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.productos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  sku text NOT NULL,
  costo_promedio numeric DEFAULT 0 NOT NULL,
  precio_venta numeric DEFAULT 0 NOT NULL,
  stock_actual numeric DEFAULT 0 NOT NULL,
  stock_minimo numeric DEFAULT 0 NOT NULL,
  unidad_medida text DEFAULT 'Unidad'::text NOT NULL,
  metodo_valuacion text DEFAULT 'CPP'::text NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  imagen_url text,
  imagen_path text,
  codigo_barras text,
  codigo_barras_interno boolean DEFAULT false NOT NULL,
  proveedor_principal_id uuid,
  categoria_principal_id uuid,
  ubicacion_principal_id uuid,
  es_insumo boolean DEFAULT false NOT NULL,
  es_vendible boolean DEFAULT true NOT NULL,
  controla_stock boolean DEFAULT true NOT NULL,
  valorizado boolean DEFAULT true NOT NULL,
  unidad_compra text,
  unidad_receta text,
  factor_compra_receta numeric DEFAULT 1 NOT NULL,
  tiempo_prep_minutos integer DEFAULT 0 NOT NULL,
  descripcion text,
  precio_mayorista numeric,
  cantidad_minima_mayorista numeric,
  precio_distribuidor numeric,
  modo_receta text DEFAULT 'preparado_al_vender'::text NOT NULL,
  destacado boolean DEFAULT false NOT NULL,
  discount_type text,
  discount_value numeric(12,2) DEFAULT 0 NOT NULL,
  discount_starts_at timestamp with time zone,
  discount_ends_at timestamp with time zone,
  oferta_semana_destacada boolean DEFAULT false NOT NULL,
  tipo_producto text DEFAULT 'reventa'::text NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.productos_codigo_secuencia (
  empresa_id uuid NOT NULL,
  last_value bigint DEFAULT 0 NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.productos_stock_ubicacion (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  ubicacion_id uuid NOT NULL,
  stock numeric DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proveedor_categoria_rel (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proveedor_id uuid NOT NULL,
  categoria_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proveedor_categorias (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  descripcion text,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proveedor_productos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  proveedor_id uuid NOT NULL,
  es_principal boolean DEFAULT false NOT NULL,
  codigo_proveedor text,
  costo_habitual numeric,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  marca text
);

CREATE TABLE IF NOT EXISTS dymaerp.proveedores (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  ruc text,
  telefono text,
  email text,
  direccion text,
  contacto text,
  estado text DEFAULT 'activo'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  nombre_comercial text,
  razon_social text,
  condicion_pago text,
  plazo_pago_dias integer,
  moneda_preferida text,
  observaciones text
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_archivos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proyecto_id uuid NOT NULL,
  nombre text NOT NULL,
  storage_bucket text DEFAULT 'proyectos'::text NOT NULL,
  storage_path text NOT NULL,
  mime_type text,
  size_bytes bigint,
  uploaded_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_comentarios (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proyecto_id uuid NOT NULL,
  usuario_id uuid NOT NULL,
  comentario text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_estado_historial (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proyecto_id uuid NOT NULL,
  estado_anterior_id uuid,
  estado_nuevo_id uuid NOT NULL,
  changed_by uuid,
  changed_at timestamp with time zone DEFAULT now() NOT NULL,
  entered_at timestamp with time zone DEFAULT now() NOT NULL,
  exited_at timestamp with time zone,
  duration_seconds bigint,
  tipo_sla_snapshot text,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_estados (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  codigo text NOT NULL,
  descripcion text,
  color text DEFAULT '#64748b'::text NOT NULL,
  sort_order integer DEFAULT 0 NOT NULL,
  cuenta_sla boolean DEFAULT true NOT NULL,
  tipo_sla text NOT NULL,
  sla_horas_objetivo integer,
  es_estado_inicial boolean DEFAULT false NOT NULL,
  es_estado_final boolean DEFAULT false NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_prioridades_config (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  codigo text NOT NULL,
  nombre text NOT NULL,
  color text,
  bg_color text,
  text_color text,
  border_color text,
  sort_order integer DEFAULT 0 NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_qa_revisiones (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proyecto_id uuid NOT NULL,
  qa_responsable_id uuid,
  entrada_at timestamp with time zone DEFAULT now() NOT NULL,
  salida_at timestamp with time zone,
  ms_laborables bigint,
  resultado text,
  estado_salida_id uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_tareas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  proyecto_id uuid NOT NULL,
  titulo text NOT NULL,
  descripcion text,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  responsable_id uuid,
  fecha_limite timestamp with time zone,
  sort_order integer DEFAULT 0 NOT NULL,
  completed_at timestamp with time zone,
  created_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyecto_tipos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  codigo text NOT NULL,
  descripcion text,
  config jsonb DEFAULT '{}'::jsonb NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.proyectos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid,
  tipo_id uuid NOT NULL,
  estado_id uuid NOT NULL,
  titulo text NOT NULL,
  descripcion text,
  prioridad text DEFAULT 'normal'::text NOT NULL,
  responsable_comercial_id uuid,
  responsable_tecnico_id uuid,
  fecha_ingreso timestamp with time zone DEFAULT now() NOT NULL,
  fecha_prometida timestamp with time zone,
  fecha_entrega timestamp with time zone,
  monto_vendido numeric(14,2),
  observaciones_comerciales text,
  brief_data jsonb DEFAULT '{}'::jsonb NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  bloqueado boolean DEFAULT false NOT NULL,
  bloqueo_motivo text,
  archivado boolean DEFAULT false NOT NULL,
  ultimo_movimiento_at timestamp with time zone DEFAULT now() NOT NULL,
  last_activity_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid,
  updated_by uuid,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.receta_items (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  receta_id uuid NOT NULL,
  insumo_producto_id uuid NOT NULL,
  cantidad numeric NOT NULL,
  unidad_medida text,
  merma_pct numeric DEFAULT 0 NOT NULL,
  orden integer DEFAULT 0 NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.recetas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  producto_id uuid NOT NULL,
  nombre text,
  rendimiento_cantidad numeric DEFAULT 1 NOT NULL,
  rendimiento_unidad text,
  notas text,
  activa boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  created_by uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.recibos_dinero (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  numero_recibo text NOT NULL,
  cliente_id uuid,
  cliente_nombre text NOT NULL,
  cliente_documento text,
  origen text DEFAULT 'manual'::text NOT NULL,
  venta_id uuid,
  cuenta_por_cobrar_id uuid,
  cobro_cliente_id uuid,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  moneda text DEFAULT 'PYG'::text NOT NULL,
  monto numeric DEFAULT 0 NOT NULL,
  metodo_pago text,
  entidad_bancaria_id uuid,
  referencia text,
  concepto text,
  observaciones text,
  usuario_id uuid,
  usuario_nombre text,
  anulado boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.sifen_jobs (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  data_schema text NOT NULL,
  factura_id uuid NOT NULL,
  factura_electronica_id uuid NOT NULL,
  estado text DEFAULT 'pendiente'::text NOT NULL,
  etapa text,
  intentos integer DEFAULT 0 NOT NULL,
  max_intentos_auto integer DEFAULT 2 NOT NULL,
  intentos_log jsonb DEFAULT '[]'::jsonb NOT NULL,
  codigo_error_set text,
  codigo_sub_error_set text,
  mensaje_set text,
  ultimo_error text,
  tipo_error text,
  respuesta_recibe_lote jsonb,
  respuesta_consulta_lote jsonb,
  cdc text,
  protocolo_lote text,
  tiempo_xml_ms integer,
  tiempo_firmar_ms integer,
  tiempo_enviar_ms integer,
  tiempo_consulta_ms integer,
  tiempo_total_ms integer,
  origen text DEFAULT 'auto_venta'::text NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  started_at timestamp with time zone,
  finished_at timestamp with time zone,
  procesando_desde timestamp with time zone,
  lock_owner text,
  proximo_reintento_at timestamp with time zone,
  veces_re_encolado_consulta integer DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteo_conversaciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  sorteo_id uuid NOT NULL,
  whatsapp_numero text NOT NULL,
  cliente_id uuid,
  estado text DEFAULT 'new_lead'::text NOT NULL,
  ultimo_mensaje text,
  cantidad_boletos integer,
  datos_cliente jsonb DEFAULT '{}'::jsonb,
  recordatorio_24h boolean DEFAULT false,
  recordatorio_48h boolean DEFAULT false,
  recordatorio_72h boolean DEFAULT false,
  ultimo_recordatorio_at timestamp with time zone,
  human_handoff_at timestamp with time zone,
  activa boolean DEFAULT true NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteo_cupones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  sorteo_id uuid NOT NULL,
  entrada_id uuid NOT NULL,
  numero_cupon text NOT NULL,
  ganador boolean DEFAULT false,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  coupon_number_value integer
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteo_entradas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  sorteo_id uuid NOT NULL,
  conversacion_id uuid,
  cliente_id uuid,
  whatsapp_numero text NOT NULL,
  nombre_participante text NOT NULL,
  documento text,
  cantidad_boletos integer NOT NULL,
  monto_total numeric NOT NULL,
  moneda text DEFAULT 'PYG'::text NOT NULL,
  estado_pago text DEFAULT 'pendiente'::text NOT NULL,
  fecha_pago timestamp with time zone,
  monto_pagado numeric,
  banco_origen text,
  comprobante_url text,
  comprobante_ia_resultado jsonb DEFAULT '{}'::jsonb,
  comprobante_ia_confianza numeric,
  validado_por text DEFAULT 'IA'::text,
  validado_por_user_id uuid,
  validado_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  numero_orden integer NOT NULL,
  chat_conversation_id uuid,
  flow_code text,
  idempotency_key text,
  promo_nombre text,
  precio_fuente text,
  precio_regular_referencia numeric,
  comprobante_validacion_id uuid,
  revendedor_id uuid,
  codigo_referido_snapshot text,
  observacion_interna text,
  venta_origen text,
  venta_canal text,
  pago_metodo text,
  cupones_impresos_at timestamp with time zone,
  cupones_impresos_by uuid,
  cupones_impresion_count integer
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteo_revendedor_clicks (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  sorteo_id uuid NOT NULL,
  revendedor_id uuid NOT NULL,
  attribution_token text NOT NULL,
  user_agent text,
  ip_hash text,
  conversation_id uuid,
  flow_session_id uuid,
  contact_phone_norm text,
  redeemed_at timestamp with time zone,
  expires_at timestamp with time zone NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteo_revendedores (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  sorteo_id uuid NOT NULL,
  nombre text NOT NULL,
  telefono text,
  codigo_referido text NOT NULL,
  activo boolean DEFAULT true NOT NULL,
  metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteo_ticket_deliveries (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  sorteo_id uuid NOT NULL,
  entrada_id uuid NOT NULL,
  conversation_id uuid,
  flow_session_id uuid,
  delivery_mode text NOT NULL,
  status text NOT NULL,
  cliente_nombre text,
  cliente_documento text,
  telefono text,
  numero_orden text,
  cupones jsonb DEFAULT '[]'::jsonb NOT NULL,
  storage_bucket text,
  storage_path text,
  whatsapp_message_id text,
  provider text,
  channel_id uuid,
  error_message text,
  payload_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  config_snapshot jsonb DEFAULT '{}'::jsonb NOT NULL,
  template_revision integer DEFAULT 1 NOT NULL,
  is_current boolean DEFAULT true NOT NULL,
  png_bytes_hash text,
  generated_at timestamp with time zone,
  sent_at timestamp with time zone,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.sorteos (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  nombre text NOT NULL,
  descripcion text,
  precio_por_boleto numeric DEFAULT 0 NOT NULL,
  max_boletos integer DEFAULT 100 NOT NULL,
  total_boletos_vendidos integer DEFAULT 0 NOT NULL,
  ultimo_numero_cupon integer DEFAULT 0 NOT NULL,
  fecha_sorteo timestamp with time zone,
  estado text DEFAULT 'activo'::text NOT NULL,
  datos_bancarios jsonb DEFAULT '{}'::jsonb NOT NULL,
  imagen_url text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  ultimo_numero_orden integer DEFAULT 0 NOT NULL,
  ticket_delivery_mode text DEFAULT 'text_only'::text NOT NULL,
  ticket_image_config jsonb DEFAULT '{}'::jsonb NOT NULL,
  coupon_numbering_enabled boolean DEFAULT false NOT NULL,
  coupon_number_start integer,
  coupon_number_mode text,
  coupon_number_limit integer
);

CREATE TABLE IF NOT EXISTS dymaerp.suscripciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  plan_id uuid,
  precio numeric DEFAULT 0 NOT NULL,
  moneda text DEFAULT 'GS'::text NOT NULL,
  fecha_inicio date NOT NULL,
  duracion_meses integer DEFAULT 12 NOT NULL,
  dia_facturacion integer DEFAULT 1 NOT NULL,
  dia_vencimiento integer DEFAULT 10 NOT NULL,
  estado text DEFAULT 'activa'::text NOT NULL,
  generar_factura_este_mes boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  plan_pendiente_id uuid,
  precio_pendiente numeric,
  moneda_pendiente text,
  plan_pendiente_vigente_desde date,
  mes_facturacion smallint DEFAULT 12 NOT NULL,
  meses_hasta_vencimiento smallint DEFAULT 0 NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.tipificaciones (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid NOT NULL,
  usuario text NOT NULL,
  tipo_gestion text NOT NULL,
  resultado text NOT NULL,
  observacion text NOT NULL,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.usuario_dashboard_views (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  usuario_id uuid NOT NULL,
  dashboard_view_id uuid NOT NULL,
  es_default boolean DEFAULT false NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.usuario_modulos (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  usuario_id uuid NOT NULL,
  modulo_id uuid NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TABLE IF NOT EXISTS dymaerp.usuarios (
  id uuid DEFAULT gen_random_uuid() NOT NULL,
  email text,
  nombre text,
  rol text,
  empresa_id uuid,
  auth_user_id uuid,
  created_at timestamp with time zone DEFAULT now(),
  activo boolean DEFAULT true,
  porcentaje_comision numeric,
  estado text DEFAULT 'activo'::text NOT NULL,
  telefono text,
  fecha_nacimiento date,
  fecha_ingreso date,
  tipo_contrato text,
  salario_base numeric,
  ips boolean DEFAULT false NOT NULL,
  area text
);

CREATE TABLE IF NOT EXISTS dymaerp.ventas (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  cliente_id uuid,
  numero_control text NOT NULL,
  moneda text DEFAULT 'GS'::text NOT NULL,
  tipo_cambio numeric DEFAULT 1 NOT NULL,
  subtotal numeric DEFAULT 0 NOT NULL,
  monto_iva numeric DEFAULT 0 NOT NULL,
  total numeric DEFAULT 0 NOT NULL,
  estado text DEFAULT 'completada'::text NOT NULL,
  tipo_venta text DEFAULT 'CONTADO'::text NOT NULL,
  plazo_dias integer,
  fecha timestamp with time zone DEFAULT now() NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  observaciones text,
  metodo_pago text,
  genera_nota_remision boolean DEFAULT false NOT NULL,
  nota_remision_numero text,
  caja_id uuid,
  created_by uuid,
  usuario_nombre text,
  anulada_at timestamp with time zone,
  anulada_motivo text,
  anulada_por uuid,
  factura_id uuid
);

CREATE TABLE IF NOT EXISTS dymaerp.ventas_items (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  producto_id uuid,
  producto_nombre text NOT NULL,
  sku text,
  cantidad numeric NOT NULL,
  precio_venta_original numeric NOT NULL,
  precio_venta numeric NOT NULL,
  tipo_iva text DEFAULT '10%'::text NOT NULL,
  subtotal numeric NOT NULL,
  monto_iva numeric NOT NULL,
  total_linea numeric NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  tipo_precio text DEFAULT 'minorista'::text NOT NULL,
  presentacion_id uuid,
  presentacion_nombre text,
  presentacion_cantidad_base numeric,
  cantidad_total_base numeric,
  es_manual boolean DEFAULT false NOT NULL,
  costo_unitario numeric
);

CREATE TABLE IF NOT EXISTS dymaerp.ventas_pagos_detalle (
  id uuid DEFAULT extensions.gen_random_uuid() NOT NULL,
  empresa_id uuid NOT NULL,
  venta_id uuid NOT NULL,
  metodo_pago text NOT NULL,
  entidad_bancaria_id uuid,
  entidad_nombre_snapshot text,
  monto numeric DEFAULT 0 NOT NULL,
  referencia text,
  fecha_pago timestamp with time zone DEFAULT now() NOT NULL,
  fecha_acreditacion date,
  observacion text,
  created_at timestamp with time zone DEFAULT now() NOT NULL,
  updated_at timestamp with time zone DEFAULT now() NOT NULL,
  titular text,
  conciliacion_estado text DEFAULT 'pendiente'::text NOT NULL,
  conciliado_at timestamp with time zone,
  conciliado_por text
);

-- ---------------------------------------------------------------------------
-- 2) CONSTRAINTS PK / UNIQUE / CHECK (346)
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.caja_movimientos ADD CONSTRAINT caja_movimientos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cajas ADD CONSTRAINT cajas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.categorias_productos ADD CONSTRAINT categorias_productos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_campaign_events ADD CONSTRAINT chat_campaign_events_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_campaign_jobs ADD CONSTRAINT chat_campaign_jobs_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_campaign_recipients ADD CONSTRAINT chat_campaign_recipients_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_campaign_templates ADD CONSTRAINT chat_campaign_templates_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_channel_quick_replies ADD CONSTRAINT chat_channel_quick_replies_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_channels ADD CONSTRAINT chat_channels_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_contacts ADD CONSTRAINT chat_contacts_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_conversation_closures ADD CONSTRAINT chat_conversation_closures_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_empresa_operator_roles ADD CONSTRAINT chat_empresa_operator_roles_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_data ADD CONSTRAINT chat_flow_data_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_events ADD CONSTRAINT chat_flow_events_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_node_blocks ADD CONSTRAINT chat_flow_node_blocks_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_nodes ADD CONSTRAINT chat_flow_nodes_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_options ADD CONSTRAINT chat_flow_options_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_recontact_rules ADD CONSTRAINT chat_flow_recontact_rules_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_recontact_runs ADD CONSTRAINT chat_flow_recontact_runs_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flow_sessions ADD CONSTRAINT chat_flow_sessions_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_flows ADD CONSTRAINT chat_flows_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_messages ADD CONSTRAINT chat_messages_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_omnicanal_work_schedules ADD CONSTRAINT chat_omnicanal_work_schedules_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_queue_channels ADD CONSTRAINT chat_queue_channels_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_queue_closure_states ADD CONSTRAINT chat_queue_closure_states_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_queue_closure_substates ADD CONSTRAINT chat_queue_closure_substates_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_queue_supervisors ADD CONSTRAINT chat_queue_supervisors_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_queues ADD CONSTRAINT chat_queues_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_routing_events ADD CONSTRAINT chat_routing_events_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_supervisor_agents ADD CONSTRAINT chat_supervisor_agents_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_usuario_omnicanal ADD CONSTRAINT chat_usuario_omnicanal_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cliente_historial ADD CONSTRAINT cliente_historial_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cliente_obligaciones_tributarias ADD CONSTRAINT cliente_obligaciones_tributarias_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cliente_perfil_tributario ADD CONSTRAINT cliente_perfil_tributario_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cliente_tipos_servicio_catalogo ADD CONSTRAINT cliente_tipos_servicio_catalogo_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cobros_clientes ADD CONSTRAINT cobros_clientes_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_ajustes ADD CONSTRAINT comision_ajustes_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_equipo_miembros ADD CONSTRAINT comision_equipo_miembros_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_equipos ADD CONSTRAINT comision_equipos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_escalas ADD CONSTRAINT comision_escalas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_lineas ADD CONSTRAINT comision_lineas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_periodos ADD CONSTRAINT comision_periodos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_politica_versiones ADD CONSTRAINT comision_politica_versiones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT comision_politicas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.crm_etapas ADD CONSTRAINT crm_etapas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.crm_notas ADD CONSTRAINT crm_notas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.crm_prospectos ADD CONSTRAINT crm_prospectos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.cuentas_por_cobrar ADD CONSTRAINT cuentas_por_cobrar_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.dashboard_views ADD CONSTRAINT dashboard_views_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.devoluciones_venta ADD CONSTRAINT devoluciones_venta_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.devoluciones_venta_cambios ADD CONSTRAINT devoluciones_venta_cambios_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.devoluciones_venta_items ADD CONSTRAINT devoluciones_venta_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.empresa_autoimpresor_config ADD CONSTRAINT empresa_autoimpresor_config_pkey PRIMARY KEY (empresa_id);
ALTER TABLE dymaerp.empresa_dashboard_views ADD CONSTRAINT empresa_dashboard_views_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.empresa_facturacion_modo ADD CONSTRAINT empresa_facturacion_modo_pkey PRIMARY KEY (empresa_id);
ALTER TABLE dymaerp.empresa_modulos ADD CONSTRAINT empresa_modulos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.empresas ADD CONSTRAINT empresas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.entidades_bancarias ADD CONSTRAINT entidades_bancarias_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.factura_autoimpresor ADD CONSTRAINT factura_autoimpresor_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.factura_correlativos ADD CONSTRAINT factura_correlativos_pkey PRIMARY KEY (empresa_id);
ALTER TABLE dymaerp.factura_electronica ADD CONSTRAINT factura_electronica_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.factura_electronica_evento ADD CONSTRAINT factura_electronica_evento_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.factura_items ADD CONSTRAINT factura_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.gastos ADD CONSTRAINT gastos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.imports_audit ADD CONSTRAINT imports_audit_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.inventario_stock_ubicacion ADD CONSTRAINT inventario_stock_ubicacion_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.inventario_ubicaciones ADD CONSTRAINT inventario_ubicaciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.marketing_calendarios ADD CONSTRAINT marketing_calendarios_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.marketing_comentarios ADD CONSTRAINT marketing_comentarios_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.marketing_historial_estados ADD CONSTRAINT marketing_historial_estados_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.modulos ADD CONSTRAINT modulos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.nota_credito_electronica ADD CONSTRAINT nota_credito_electronica_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.nota_credito_evento ADD CONSTRAINT nota_credito_evento_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.notas_remision_items ADD CONSTRAINT notas_remision_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.notificaciones ADD CONSTRAINT notificaciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.obligaciones_tributarias_catalogo ADD CONSTRAINT obligaciones_tributarias_catalogo_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.omnichannel_routes ADD CONSTRAINT omnichannel_routes_pkey PRIMARY KEY (meta_phone_number_id);
ALTER TABLE dymaerp.ordenes_compra ADD CONSTRAINT ordenes_compra_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.pagos ADD CONSTRAINT pagos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.pedidos_caja ADD CONSTRAINT pedidos_caja_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.planes ADD CONSTRAINT planes_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.presupuesto_items ADD CONSTRAINT presupuesto_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.presupuestos ADD CONSTRAINT presupuestos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.produccion_items ADD CONSTRAINT produccion_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.producciones ADD CONSTRAINT producciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.producto_categorias ADD CONSTRAINT producto_categorias_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.producto_presentaciones ADD CONSTRAINT producto_presentaciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.productos_codigo_secuencia ADD CONSTRAINT productos_codigo_secuencia_pkey PRIMARY KEY (empresa_id);
ALTER TABLE dymaerp.productos_stock_ubicacion ADD CONSTRAINT productos_stock_ubicacion_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proveedor_categoria_rel ADD CONSTRAINT proveedor_categoria_rel_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proveedor_categorias ADD CONSTRAINT proveedor_categorias_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proveedor_productos ADD CONSTRAINT proveedor_productos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proveedores ADD CONSTRAINT proveedores_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_archivos ADD CONSTRAINT proyecto_archivos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_comentarios ADD CONSTRAINT proyecto_comentarios_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_estado_historial ADD CONSTRAINT proyecto_estado_historial_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_estados ADD CONSTRAINT proyecto_estados_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT proyecto_prioridades_config_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_qa_revisiones ADD CONSTRAINT proyecto_qa_revisiones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT proyecto_tareas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyecto_tipos ADD CONSTRAINT proyecto_tipos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.recetas ADD CONSTRAINT recetas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.recibos_dinero ADD CONSTRAINT recibos_dinero_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sifen_jobs ADD CONSTRAINT sifen_jobs_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteo_conversaciones ADD CONSTRAINT sorteo_conversaciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteo_cupones ADD CONSTRAINT sorteo_cupones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteo_revendedor_clicks ADD CONSTRAINT sorteo_revendedor_clicks_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteo_revendedores ADD CONSTRAINT sorteo_revendedores_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.sorteos ADD CONSTRAINT sorteos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.tipificaciones ADD CONSTRAINT tipificaciones_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.usuario_dashboard_views ADD CONSTRAINT usuario_dashboard_views_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.usuario_modulos ADD CONSTRAINT usuario_modulos_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.ventas_pagos_detalle ADD CONSTRAINT ventas_pagos_detalle_pkey PRIMARY KEY (id);
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_usuario_id_queue_id_key UNIQUE (usuario_id, queue_id);
ALTER TABLE dymaerp.chat_contacts ADD CONSTRAINT chat_contacts_empresa_id_phone_number_key UNIQUE (empresa_id, phone_number);
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_contact_id_channel_id_key UNIQUE (contact_id, channel_id);
ALTER TABLE dymaerp.chat_empresa_operator_roles ADD CONSTRAINT chat_empresa_operator_roles_empresa_id_usuario_id_key UNIQUE (empresa_id, usuario_id);
ALTER TABLE dymaerp.chat_flow_nodes ADD CONSTRAINT chat_flow_nodes_empresa_id_flow_code_node_code_key UNIQUE (empresa_id, flow_code, node_code);
ALTER TABLE dymaerp.chat_flow_options ADD CONSTRAINT chat_flow_options_node_id_meta_button_id_key UNIQUE (node_id, meta_button_id);
ALTER TABLE dymaerp.chat_flows ADD CONSTRAINT chat_flows_empresa_id_flow_code_key UNIQUE (empresa_id, flow_code);
ALTER TABLE dymaerp.chat_queue_channels ADD CONSTRAINT chat_queue_channels_queue_id_channel_id_key UNIQUE (queue_id, channel_id);
ALTER TABLE dymaerp.chat_queue_supervisors ADD CONSTRAINT chat_queue_supervisors_queue_id_usuario_id_key UNIQUE (queue_id, usuario_id);
ALTER TABLE dymaerp.chat_supervisor_agents ADD CONSTRAINT chat_supervisor_agents_empresa_id_supervisor_usuario_id_age_key UNIQUE (empresa_id, supervisor_usuario_id, agent_usuario_id);
ALTER TABLE dymaerp.chat_usuario_omnicanal ADD CONSTRAINT chat_usuario_omnicanal_empresa_id_usuario_id_key UNIQUE (empresa_id, usuario_id);
ALTER TABLE dymaerp.cliente_obligaciones_tributarias ADD CONSTRAINT cliente_obligaciones_tributar_cliente_perfil_id_obligacion__key UNIQUE (cliente_perfil_id, obligacion_catalogo_id);
ALTER TABLE dymaerp.cliente_perfil_tributario ADD CONSTRAINT cliente_perfil_tributario_empresa_id_cliente_id_key UNIQUE (empresa_id, cliente_id);
ALTER TABLE dymaerp.cliente_tipos_servicio_catalogo ADD CONSTRAINT cliente_tipos_servicio_catalogo_empresa_id_slug_key UNIQUE (empresa_id, slug);
ALTER TABLE dymaerp.comision_equipo_miembros ADD CONSTRAINT comision_equipo_miembros_equipo_id_usuario_id_key UNIQUE (equipo_id, usuario_id);
ALTER TABLE dymaerp.comision_politica_versiones ADD CONSTRAINT comision_politica_versiones_politica_id_version_no_key UNIQUE (politica_id, version_no);
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT comision_politicas_empresa_id_key UNIQUE (empresa_id);
ALTER TABLE dymaerp.crm_etapas ADD CONSTRAINT crm_etapas_empresa_id_codigo_key UNIQUE (empresa_id, codigo);
ALTER TABLE dymaerp.dashboard_views ADD CONSTRAINT dashboard_views_slug_key UNIQUE (slug);
ALTER TABLE dymaerp.empresa_dashboard_views ADD CONSTRAINT empresa_dashboard_views_empresa_id_dashboard_view_id_key UNIQUE (empresa_id, dashboard_view_id);
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_empresa_id_key UNIQUE (empresa_id);
ALTER TABLE dymaerp.factura_electronica ADD CONSTRAINT factura_electronica_factura_id_key UNIQUE (factura_id);
ALTER TABLE dymaerp.nota_credito_electronica ADD CONSTRAINT nota_credito_electronica_nota_credito_id_key UNIQUE (nota_credito_id);
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_empresa_id_numero_key UNIQUE (empresa_id, numero);
ALTER TABLE dymaerp.obligaciones_tributarias_catalogo ADD CONSTRAINT obligaciones_tributarias_catalogo_slug_key UNIQUE (slug);
ALTER TABLE dymaerp.productos_stock_ubicacion ADD CONSTRAINT productos_stock_ubicacion_empresa_producto_ubicacion_key UNIQUE (empresa_id, producto_id, ubicacion_id);
ALTER TABLE dymaerp.proveedor_categoria_rel ADD CONSTRAINT proveedor_categoria_rel_proveedor_id_categoria_id_key UNIQUE (proveedor_id, categoria_id);
ALTER TABLE dymaerp.proveedor_productos ADD CONSTRAINT proveedor_productos_empresa_id_producto_id_proveedor_id_key UNIQUE (empresa_id, producto_id, proveedor_id);
ALTER TABLE dymaerp.proyecto_archivos ADD CONSTRAINT proyecto_archivos_empresa_id_storage_bucket_storage_path_key UNIQUE (empresa_id, storage_bucket, storage_path);
ALTER TABLE dymaerp.proyecto_estados ADD CONSTRAINT proyecto_estados_empresa_id_codigo_key UNIQUE (empresa_id, codigo);
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT proyecto_prioridades_config_empresa_id_codigo_key UNIQUE (empresa_id, codigo);
ALTER TABLE dymaerp.proyecto_tipos ADD CONSTRAINT proyecto_tipos_empresa_id_codigo_key UNIQUE (empresa_id, codigo);
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_receta_id_insumo_producto_id_key UNIQUE (receta_id, insumo_producto_id);
ALTER TABLE dymaerp.recetas ADD CONSTRAINT recetas_empresa_id_producto_id_key UNIQUE (empresa_id, producto_id);
ALTER TABLE dymaerp.sorteo_cupones ADD CONSTRAINT sorteo_cupones_sorteo_id_numero_cupon_key UNIQUE (sorteo_id, numero_cupon);
ALTER TABLE dymaerp.usuario_dashboard_views ADD CONSTRAINT usuario_dashboard_views_usuario_id_dashboard_view_id_key UNIQUE (usuario_id, dashboard_view_id);
ALTER TABLE dymaerp.usuario_modulos ADD CONSTRAINT usuario_modulos_usuario_id_modulo_id_key UNIQUE (usuario_id, modulo_id);
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_email_key UNIQUE (email);
ALTER TABLE dymaerp.caja_movimientos ADD CONSTRAINT caja_movimientos_medio_pago_check CHECK ((medio_pago = ANY (ARRAY['efectivo'::text, 'tarjeta'::text, 'transferencia'::text, 'otro'::text])));
ALTER TABLE dymaerp.caja_movimientos ADD CONSTRAINT caja_movimientos_tipo_check CHECK ((tipo = ANY (ARRAY['ingreso'::text, 'egreso'::text, 'retiro'::text, 'ajuste'::text])));
ALTER TABLE dymaerp.cajas ADD CONSTRAINT cajas_estado_check CHECK ((estado = ANY (ARRAY['abierta'::text, 'en_cierre'::text, 'cerrada'::text])));
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_max_conversations_check CHECK ((max_conversations >= 1));
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_operational_status_check CHECK ((operational_status = ANY (ARRAY['ready'::text, 'offline'::text])));
ALTER TABLE dymaerp.chat_campaign_jobs ADD CONSTRAINT chat_campaign_jobs_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'running'::text, 'done'::text, 'failed'::text])));
ALTER TABLE dymaerp.chat_campaign_recipients ADD CONSTRAINT chat_campaign_recipients_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'invalid'::text, 'queued'::text, 'sending'::text, 'sent'::text, 'failed'::text, 'replied'::text, 'skipped'::text])));
ALTER TABLE dymaerp.chat_campaign_templates ADD CONSTRAINT chat_campaign_templates_name_trim CHECK ((length(TRIM(BOTH FROM name)) > 0));
ALTER TABLE dymaerp.chat_campaign_templates ADD CONSTRAINT chat_campaign_templates_provider_check CHECK ((provider = ANY (ARRAY['meta'::text, 'ycloud'::text])));
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_name_trim CHECK ((length(TRIM(BOTH FROM name)) > 0));
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_provider_check CHECK ((provider = ANY (ARRAY['meta'::text, 'ycloud'::text])));
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_status_check CHECK ((status = ANY (ARRAY['draft'::text, 'ready'::text, 'sending'::text, 'completed'::text, 'failed'::text, 'cancelled'::text])));
ALTER TABLE dymaerp.chat_channel_quick_replies ADD CONSTRAINT chat_channel_quick_replies_body_trim CHECK ((length(TRIM(BOTH FROM body)) > 0));
ALTER TABLE dymaerp.chat_channel_quick_replies ADD CONSTRAINT chat_channel_quick_replies_title_trim CHECK ((length(TRIM(BOTH FROM title)) > 0));
ALTER TABLE dymaerp.chat_channels ADD CONSTRAINT chat_channels_config_status_check CHECK ((config_status = ANY (ARRAY['inactive'::text, 'incomplete'::text, 'active'::text])));
ALTER TABLE dymaerp.chat_channels ADD CONSTRAINT chat_channels_type_check CHECK ((type = ANY (ARRAY['whatsapp'::text, 'instagram'::text, 'facebook'::text, 'email'::text, 'linkedin'::text])));
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_estado_validacion_check CHECK ((estado_validacion = ANY (ARRAY['pendiente'::text, 'valido'::text, 'duplicado_hash'::text, 'duplicado_ocr'::text, 'revision_manual'::text, 'ocr_error'::text, 'monto_incoherente'::text, 'datos_bancarios_incoherentes'::text, 'aprobado_manual'::text, 'rechazado_manual'::text])));
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_priority_check CHECK ((priority = ANY (ARRAY['low'::text, 'medium'::text, 'high'::text])));
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_status_check CHECK ((status = ANY (ARRAY['open'::text, 'pending'::text, 'closed'::text])));
ALTER TABLE dymaerp.chat_empresa_operator_roles ADD CONSTRAINT chat_empresa_operator_roles_role_check CHECK ((role = ANY (ARRAY['admin'::text, 'supervisor'::text, 'agente'::text])));
ALTER TABLE dymaerp.chat_flow_node_blocks ADD CONSTRAINT chat_flow_node_blocks_block_type_check CHECK ((block_type = ANY (ARRAY['text'::text, 'image'::text, 'buttons'::text])));
ALTER TABLE dymaerp.chat_flow_nodes ADD CONSTRAINT chat_flow_nodes_node_type_check CHECK ((node_type = ANY (ARRAY['buttons'::text, 'list'::text, 'text'::text, 'media'::text, 'image_input'::text, 'human'::text, 'end'::text])));
ALTER TABLE dymaerp.chat_flow_recontact_rules ADD CONSTRAINT cfr_rules_cooldown_min CHECK ((cooldown_seconds >= 60));
ALTER TABLE dymaerp.chat_flow_recontact_rules ADD CONSTRAINT cfr_rules_idle_min CHECK ((idle_after_seconds >= 60));
ALTER TABLE dymaerp.chat_flow_recontact_rules ADD CONSTRAINT cfr_rules_max_attempts CHECK ((max_attempts >= 1));
ALTER TABLE dymaerp.chat_flow_sessions ADD CONSTRAINT chat_flow_sessions_referral_source_check CHECK (((referral_source IS NULL) OR (referral_source = ANY (ARRAY['click_token'::text, 'inbound_text'::text]))));
ALTER TABLE dymaerp.chat_flow_sessions ADD CONSTRAINT chat_flow_sessions_status_check CHECK ((status = ANY (ARRAY['active'::text, 'completed'::text, 'abandoned'::text, 'restarted'::text])));
ALTER TABLE dymaerp.chat_messages ADD CONSTRAINT chat_messages_sender_type_check CHECK ((sender_type = ANY (ARRAY['contact'::text, 'ai'::text, 'human'::text, 'system'::text])));
ALTER TABLE dymaerp.chat_omnicanal_work_schedules ADD CONSTRAINT chat_omnicanal_work_schedules_days_check CHECK ((days_of_week <@ ARRAY[(1)::smallint, (2)::smallint, (3)::smallint, (4)::smallint, (5)::smallint, (6)::smallint, (7)::smallint]));
ALTER TABLE dymaerp.chat_queues ADD CONSTRAINT chat_queues_channel_type_check CHECK (((channel_type IS NULL) OR (channel_type = ANY (ARRAY['whatsapp'::text, 'instagram'::text, 'facebook'::text, 'email'::text, 'linkedin'::text]))));
ALTER TABLE dymaerp.chat_queues ADD CONSTRAINT chat_queues_distribution_strategy_check CHECK ((distribution_strategy = ANY (ARRAY['round_robin'::text, 'least_load'::text, 'manual_pull'::text])));
ALTER TABLE dymaerp.chat_supervisor_agents ADD CONSTRAINT chat_supervisor_agents_no_self CHECK ((supervisor_usuario_id <> agent_usuario_id));
ALTER TABLE dymaerp.cliente_historial ADD CONSTRAINT cliente_historial_modo_check CHECK (((modo IS NULL) OR (modo = ANY (ARRAY['inmediato'::text, 'proximo_mes'::text, 'actualizar_factura_pendiente'::text]))));
ALTER TABLE dymaerp.cliente_perfil_tributario ADD CONSTRAINT cliente_perfil_tributario_dia_vencimiento_range CHECK (((dia_vencimiento_tributario IS NULL) OR ((dia_vencimiento_tributario >= 1) AND (dia_vencimiento_tributario <= 31))));
ALTER TABLE dymaerp.cliente_tipos_servicio_catalogo ADD CONSTRAINT c_cliente_tipo_cat_slug_format CHECK (((char_length(btrim(slug)) > 0) AND (slug = lower(btrim(slug))) AND (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'::text)));
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_sifen_receptor_naturaleza_check CHECK (((sifen_receptor_naturaleza IS NULL) OR (sifen_receptor_naturaleza = ANY (ARRAY['contribuyente_paraguayo'::text, 'no_contribuyente'::text, 'extranjero'::text]))));
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_sifen_ti_ope_check CHECK (((sifen_ti_ope IS NULL) OR ((sifen_ti_ope >= 1) AND (sifen_ti_ope <= 4))));
ALTER TABLE dymaerp.cobros_clientes ADD CONSTRAINT cc_conciliacion_estado_check CHECK ((conciliacion_estado = ANY (ARRAY['pendiente'::text, 'aprobado'::text, 'rechazado'::text])));
ALTER TABLE dymaerp.comision_ajustes ADD CONSTRAINT chk_comision_ajustes_motivo CHECK ((length(TRIM(BOTH FROM motivo)) > 0));
ALTER TABLE dymaerp.comision_equipos ADD CONSTRAINT chk_comision_equipos_nombre CHECK ((length(TRIM(BOTH FROM nombre)) > 0));
ALTER TABLE dymaerp.comision_periodos ADD CONSTRAINT comision_periodos_estado_check CHECK ((estado = ANY (ARRAY['borrador'::text, 'cerrado'::text, 'congelado'::text, 'aprobado'::text, 'pagado'::text])));
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT chk_comision_politicas_nombre CHECK ((length(TRIM(BOTH FROM nombre)) > 0));
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT comision_politicas_base_calculo_check CHECK ((base_calculo = ANY (ARRAY['pago_registrado'::text, 'factura_emitida'::text, 'factura_pagada'::text])));
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_estado_check CHECK ((estado = ANY (ARRAY['registrada'::text, 'pendiente'::text, 'pagada'::text, 'anulada'::text])));
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_iva_tipo_check CHECK ((iva_tipo = ANY (ARRAY['exenta'::text, '5'::text, '10'::text])));
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_moneda_check CHECK ((moneda = ANY (ARRAY['PYG'::text, 'USD'::text])));
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_tipo_pago_check CHECK ((tipo_pago = ANY (ARRAY['contado'::text, 'credito'::text])));
ALTER TABLE dymaerp.cuentas_por_cobrar ADD CONSTRAINT cuentas_por_cobrar_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'parcial'::text, 'pagado'::text, 'vencido'::text, 'anulado'::text])));
ALTER TABLE dymaerp.devoluciones_venta ADD CONSTRAINT devoluciones_venta_estado_check CHECK ((estado = ANY (ARRAY['confirmada'::text, 'anulada'::text])));
ALTER TABLE dymaerp.devoluciones_venta ADD CONSTRAINT devoluciones_venta_metodo_check CHECK (((metodo_reembolso IS NULL) OR (metodo_reembolso = ANY (ARRAY['efectivo'::text, 'tarjeta'::text, 'transferencia'::text]))));
ALTER TABLE dymaerp.devoluciones_venta ADD CONSTRAINT devoluciones_venta_resolucion_check CHECK ((resolucion = ANY (ARRAY['reembolso'::text, 'cambio'::text])));
ALTER TABLE dymaerp.devoluciones_venta ADD CONSTRAINT devoluciones_venta_tipo_check CHECK ((tipo = ANY (ARRAY['total'::text, 'parcial'::text])));
ALTER TABLE dymaerp.devoluciones_venta_cambios ADD CONSTRAINT devoluciones_venta_cambios_cant_check CHECK ((cantidad > (0)::numeric));
ALTER TABLE dymaerp.devoluciones_venta_items ADD CONSTRAINT devoluciones_venta_items_cant_check CHECK ((cantidad_devuelta > (0)::numeric));
ALTER TABLE dymaerp.devoluciones_venta_items ADD CONSTRAINT devoluciones_venta_items_condicion_check CHECK ((condicion = ANY (ARRAY['buen_estado'::text, 'danado'::text])));
ALTER TABLE dymaerp.empresa_autoimpresor_config ADD CONSTRAINT empresa_autoimpresor_config_formato_impresion_default_check CHECK ((formato_impresion_default = ANY (ARRAY['pdf_a4'::text, 'pdf_media_hoja'::text, 'ticket_80mm'::text, 'ticket_58mm'::text])));
ALTER TABLE dymaerp.empresa_autoimpresor_config ADD CONSTRAINT empresa_autoimpresor_config_tipo_documento_default_check CHECK ((tipo_documento_default = ANY (ARRAY['factura'::text, 'ticket'::text, 'nota_venta'::text, 'otro'::text])));
ALTER TABLE dymaerp.empresa_facturacion_modo ADD CONSTRAINT empresa_facturacion_modo_impresion_tipo_default_check CHECK ((impresion_tipo_default = ANY (ARRAY['pdf_a4'::text, 'pdf_media_hoja'::text, 'ticket_80mm'::text, 'ticket_58mm'::text])));
ALTER TABLE dymaerp.empresa_facturacion_modo ADD CONSTRAINT empresa_facturacion_modo_modo_check CHECK ((modo = ANY (ARRAY['sin_factura_fiscal'::text, 'sifen'::text, 'autoimpresor'::text])));
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_ambiente_check CHECK ((ambiente = ANY (ARRAY['test'::text, 'produccion'::text])));
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_kude_color_primario_fill_fmt_chk CHECK (((kude_color_primario_fill IS NULL) OR (kude_color_primario_fill ~ '^#[0-9A-Fa-f]{6}$'::text)));
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_kude_color_primario_fmt_chk CHECK (((kude_color_primario IS NULL) OR (kude_color_primario ~ '^#[0-9A-Fa-f]{6}$'::text)));
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_sifen_plazo_cancelacion_horas_check CHECK (((sifen_plazo_cancelacion_horas >= 1) AND (sifen_plazo_cancelacion_horas <= 8760)));
ALTER TABLE dymaerp.factura_autoimpresor ADD CONSTRAINT factura_autoimpresor_condicion_check CHECK ((condicion = ANY (ARRAY['contado'::text, 'credito'::text])));
ALTER TABLE dymaerp.factura_correlativos ADD CONSTRAINT factura_correlativos_ultimo_numero_check CHECK ((ultimo_numero >= 0));
ALTER TABLE dymaerp.factura_electronica ADD CONSTRAINT factura_electronica_estado_sifen_check CHECK ((estado_sifen = ANY (ARRAY['borrador'::text, 'generado'::text, 'firmado'::text, 'enviado'::text, 'aprobado'::text, 'rechazado'::text, 'error_envio'::text, 'cancelado'::text])));
ALTER TABLE dymaerp.factura_electronica_evento ADD CONSTRAINT factura_electronica_evento_tipo_check CHECK ((tipo = ANY (ARRAY['generacion'::text, 'envio'::text, 'respuesta'::text, 'error'::text, 'firma'::text, 'cancelacion'::text])));
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_estado_check CHECK ((estado = ANY (ARRAY['Pagado'::text, 'Pendiente'::text, 'Vencido'::text, 'Anulado'::text, 'Corregida NC'::text])));
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_moneda_check CHECK ((moneda = ANY (ARRAY['GS'::text, 'USD'::text])));
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_tipo_check CHECK ((tipo = ANY (ARRAY['contado'::text, 'credito'::text, 'suscripcion'::text])));
ALTER TABLE dymaerp.gastos ADD CONSTRAINT gastos_tipo_check CHECK ((tipo = ANY (ARRAY['fijo'::text, 'variable'::text])));
ALTER TABLE dymaerp.inventario_ubicaciones ADD CONSTRAINT inventario_ubicaciones_tipo_check CHECK ((tipo = ANY (ARRAY['deposito'::text, 'salon'::text, 'pasillo'::text, 'gondola'::text, 'estante'::text, 'zona'::text, 'otro'::text])));
ALTER TABLE dymaerp.marketing_comentarios ADD CONSTRAINT chk_marketing_comentarios_texto_non_empty CHECK ((length(TRIM(BOTH FROM comentario)) > 0));
ALTER TABLE dymaerp.marketing_historial_estados ADD CONSTRAINT chk_marketing_historial_campo_non_empty CHECK ((length(TRIM(BOTH FROM campo)) > 0));
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT chk_marketing_piezas_titulo_non_empty CHECK ((length(TRIM(BOTH FROM titulo)) > 0));
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_estado_cliente_check CHECK ((estado_cliente = ANY (ARRAY['no_enviado'::text, 'enviado'::text, 'aprobado'::text, 'con_correcciones'::text, 'sin_respuesta'::text])));
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_estado_produccion_check CHECK ((estado_produccion = ANY (ARRAY['por_hacer'::text, 'en_produccion'::text, 'revision_interna'::text, 'correccion_interna'::text, 'listo_para_enviar'::text])));
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_estado_publicacion_check CHECK ((estado_publicacion = ANY (ARRAY['pendiente'::text, 'programado'::text, 'publicado'::text, 'cancelado'::text])));
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_prioridad_check CHECK ((prioridad = ANY (ARRAY['baja'::text, 'media'::text, 'alta'::text, 'urgente'::text])));
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'en_proceso'::text, 'en_revision'::text, 'aprobado'::text, 'publicado'::text])));
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_prioridad_check CHECK (((prioridad IS NULL) OR (prioridad = ANY (ARRAY['baja'::text, 'media'::text, 'alta'::text, 'urgente'::text]))));
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_tipo_contenido_check CHECK ((tipo_contenido = ANY (ARRAY['post'::text, 'reel'::text, 'historia'::text, 'anuncio'::text, 'otro'::text])));
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_origen_check CHECK ((origen = ANY (ARRAY['compra'::text, 'venta'::text, 'ajuste_manual'::text, 'inventario_inicial'::text, 'produccion'::text, 'devolucion_venta'::text, 'nota_remision'::text])));
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_tipo_check CHECK ((tipo = ANY (ARRAY['ENTRADA'::text, 'SALIDA'::text, 'AJUSTE'::text])));
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_estado_erp_check CHECK ((estado_erp = ANY (ARRAY['borrador'::text, 'pendiente_envio_sifen'::text, 'aprobada'::text, 'rechazada'::text, 'error'::text, 'anulada_borrador'::text])));
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_moneda_snapshot_check CHECK ((moneda_snapshot = ANY (ARRAY['GS'::text, 'USD'::text])));
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_monto_check CHECK ((monto > (0)::numeric));
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_motivo_len_check CHECK (((length(TRIM(BOTH FROM motivo)) >= 5) AND (length(motivo) <= 2000)));
ALTER TABLE dymaerp.nota_credito_electronica ADD CONSTRAINT nota_credito_electronica_estado_sifen_check CHECK ((estado_sifen = ANY (ARRAY['sin_envio'::text, 'generado'::text, 'firmado'::text, 'enviado'::text, 'en_proceso'::text, 'aprobado'::text, 'rechazado'::text, 'error_envio'::text, 'cancelado'::text])));
ALTER TABLE dymaerp.nota_credito_evento ADD CONSTRAINT nota_credito_evento_tipo_check CHECK ((tipo_evento = ANY (ARRAY['creacion'::text, 'validacion'::text, 'rechazo_negocio'::text, 'cambio_estado_erp'::text, 'preparacion_sifen'::text, 'error'::text, 'observacion_operativa'::text, 'anulacion_borrador'::text, 'xml_generado'::text, 'xml_firmado'::text, 'enviado_set'::text, 'respuesta_set'::text, 'aprobado'::text, 'rechazado'::text, 'impacto_saldo_aplicado'::text, 'error_envio'::text])));
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_destino_coherente_check CHECK ((((destino_tipo = 'deposito'::text) AND (ubicacion_destino_id IS NOT NULL)) OR ((destino_tipo = 'cliente'::text) AND ((cliente_id IS NOT NULL) OR (COALESCE(destino_nombre, ''::text) <> ''::text)))));
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_destino_tipo_check CHECK ((destino_tipo = ANY (ARRAY['deposito'::text, 'cliente'::text])));
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'aprobada'::text, 'rechazada'::text])));
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_motivo_check CHECK ((motivo = ANY (ARRAY['traslado'::text, 'venta'::text, 'devolucion'::text])));
ALTER TABLE dymaerp.ordenes_compra ADD CONSTRAINT ordenes_compra_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'recibida_parcial'::text, 'recibida_total'::text, 'cancelada'::text])));
ALTER TABLE dymaerp.ordenes_compra ADD CONSTRAINT ordenes_compra_iva_tipo_check CHECK ((iva_tipo = ANY (ARRAY['exenta'::text, '5'::text, '10'::text])));
ALTER TABLE dymaerp.ordenes_compra ADD CONSTRAINT ordenes_compra_moneda_check CHECK ((moneda = ANY (ARRAY['PYG'::text, 'USD'::text])));
ALTER TABLE dymaerp.ordenes_compra ADD CONSTRAINT ordenes_compra_tipo_pago_check CHECK ((tipo_pago = ANY (ARRAY['contado'::text, 'credito'::text])));
ALTER TABLE dymaerp.pagos ADD CONSTRAINT pagos_metodo_pago_check CHECK ((metodo_pago = ANY (ARRAY['efectivo'::text, 'transferencia'::text, 'cheque'::text, 'tarjeta'::text, 'otro'::text])));
ALTER TABLE dymaerp.pedidos_caja ADD CONSTRAINT pedidos_caja_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'en_caja'::text, 'facturado'::text, 'cancelado'::text])));
ALTER TABLE dymaerp.planes ADD CONSTRAINT planes_estado_check CHECK ((estado = ANY (ARRAY['activo'::text, 'inactivo'::text])));
ALTER TABLE dymaerp.planes ADD CONSTRAINT planes_moneda_check CHECK ((moneda = ANY (ARRAY['GS'::text, 'USD'::text])));
ALTER TABLE dymaerp.planes ADD CONSTRAINT planes_periodicidad_check CHECK ((periodicidad = ANY (ARRAY['mensual'::text, 'anual'::text, 'unico'::text])));
ALTER TABLE dymaerp.presupuestos ADD CONSTRAINT presupuestos_estado_check CHECK ((estado = ANY (ARRAY['creado'::text, 'enviado'::text, 'aprobado'::text, 'rechazado'::text, 'convertido'::text])));
ALTER TABLE dymaerp.producto_presentaciones ADD CONSTRAINT producto_presentaciones_cantidad_base_check CHECK ((cantidad_base > (0)::numeric));
ALTER TABLE dymaerp.producto_presentaciones ADD CONSTRAINT producto_presentaciones_precio_venta_check CHECK (((precio_venta IS NULL) OR (precio_venta >= (0)::numeric)));
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_discount_type_chk CHECK (((discount_type IS NULL) OR (discount_type = ANY (ARRAY['percentage'::text, 'fixed'::text]))));
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_factor_compra_receta_check CHECK ((factor_compra_receta > (0)::numeric));
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_metodo_valuacion_check CHECK ((metodo_valuacion = ANY (ARRAY['CPP'::text, 'FIFO'::text, 'LIFO'::text])));
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_modo_receta_check CHECK ((modo_receta = ANY (ARRAY['preparado_al_vender'::text, 'produccion_previa'::text])));
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_tiempo_prep_minutos_check CHECK ((tiempo_prep_minutos >= 0));
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_tipo_producto_check CHECK ((tipo_producto = ANY (ARRAY['reventa'::text, 'repuesto'::text, 'servicio'::text])));
ALTER TABLE dymaerp.proveedores ADD CONSTRAINT proveedores_condicion_pago_check CHECK (((condicion_pago IS NULL) OR (condicion_pago = ANY (ARRAY['contado'::text, 'credito'::text, 'mixto'::text]))));
ALTER TABLE dymaerp.proveedores ADD CONSTRAINT proveedores_estado_check CHECK ((estado = ANY (ARRAY['activo'::text, 'inactivo'::text])));
ALTER TABLE dymaerp.proveedores ADD CONSTRAINT proveedores_moneda_preferida_check CHECK (((moneda_preferida IS NULL) OR (moneda_preferida = ANY (ARRAY['GS'::text, 'USD'::text]))));
ALTER TABLE dymaerp.proyecto_archivos ADD CONSTRAINT chk_proyecto_archivos_nombre_non_empty CHECK ((length(TRIM(BOTH FROM nombre)) > 0));
ALTER TABLE dymaerp.proyecto_comentarios ADD CONSTRAINT chk_proyecto_comentarios_texto_non_empty CHECK ((length(TRIM(BOTH FROM comentario)) > 0));
ALTER TABLE dymaerp.proyecto_estados ADD CONSTRAINT chk_proyecto_estados_codigo_non_empty CHECK ((length(TRIM(BOTH FROM codigo)) > 0));
ALTER TABLE dymaerp.proyecto_estados ADD CONSTRAINT proyecto_estados_tipo_sla_check CHECK ((tipo_sla = ANY (ARRAY['interno'::text, 'cliente'::text, 'pausado'::text, 'final'::text])));
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT chk_proyecto_prioridades_bg_color CHECK (((bg_color IS NULL) OR (bg_color ~ '^#[0-9A-Fa-f]{6}$'::text)));
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT chk_proyecto_prioridades_border_color CHECK (((border_color IS NULL) OR (border_color ~ '^#[0-9A-Fa-f]{6}$'::text)));
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT chk_proyecto_prioridades_codigo CHECK ((codigo = ANY (ARRAY['baja'::text, 'normal'::text, 'alta'::text, 'urgente'::text])));
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT chk_proyecto_prioridades_color CHECK (((color IS NULL) OR (color ~ '^#[0-9A-Fa-f]{6}$'::text)));
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT chk_proyecto_prioridades_nombre_non_empty CHECK ((length(TRIM(BOTH FROM nombre)) > 0));
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT chk_proyecto_prioridades_text_color CHECK (((text_color IS NULL) OR (text_color ~ '^#[0-9A-Fa-f]{6}$'::text)));
ALTER TABLE dymaerp.proyecto_qa_revisiones ADD CONSTRAINT chk_qa_rev_rango CHECK (((salida_at IS NULL) OR (salida_at >= entrada_at)));
ALTER TABLE dymaerp.proyecto_qa_revisiones ADD CONSTRAINT chk_qa_rev_resultado CHECK (((resultado IS NULL) OR (resultado = ANY (ARRAY['aprobado'::text, 'cambios'::text]))));
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT chk_proyecto_tareas_titulo_non_empty CHECK ((length(TRIM(BOTH FROM titulo)) > 0));
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT proyecto_tareas_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'en_proceso'::text, 'completada'::text, 'bloqueada'::text])));
ALTER TABLE dymaerp.proyecto_tipos ADD CONSTRAINT chk_proyecto_tipos_codigo_non_empty CHECK ((length(TRIM(BOTH FROM codigo)) > 0));
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT chk_proyectos_titulo_non_empty CHECK ((length(TRIM(BOTH FROM titulo)) > 0));
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_prioridad_check CHECK ((prioridad = ANY (ARRAY['baja'::text, 'normal'::text, 'alta'::text, 'urgente'::text])));
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_cantidad_check CHECK ((cantidad > (0)::numeric));
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_merma_pct_check CHECK (((merma_pct >= (0)::numeric) AND (merma_pct < (1)::numeric)));
ALTER TABLE dymaerp.recetas ADD CONSTRAINT recetas_rendimiento_cantidad_check CHECK ((rendimiento_cantidad > (0)::numeric));
ALTER TABLE dymaerp.recibos_dinero ADD CONSTRAINT recibos_dinero_origen_check CHECK ((origen = ANY (ARRAY['venta_contado'::text, 'cobro_cxc'::text, 'manual'::text])));
ALTER TABLE dymaerp.sifen_jobs ADD CONSTRAINT sifen_jobs_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'procesando'::text, 'aprobado'::text, 'rechazado'::text, 'error'::text])));
ALTER TABLE dymaerp.sifen_jobs ADD CONSTRAINT sifen_jobs_etapa_check CHECK (((etapa IS NULL) OR (etapa = ANY (ARRAY['xml'::text, 'firmar'::text, 'enviar'::text, 'consulta_lote'::text]))));
ALTER TABLE dymaerp.sifen_jobs ADD CONSTRAINT sifen_jobs_origen_check CHECK ((origen = ANY (ARRAY['auto_venta'::text, 'reintento_manual'::text, 'manual_admin'::text])));
ALTER TABLE dymaerp.sifen_jobs ADD CONSTRAINT sifen_jobs_tipo_error_check CHECK (((tipo_error IS NULL) OR (tipo_error = ANY (ARRAY['set_rechazo'::text, 'fiscal'::text, 'firma'::text, 'config'::text, 'red'::text, 'http_5xx'::text, 'storage'::text, 'inesperado'::text, 'set_timeout'::text]))));
ALTER TABLE dymaerp.sorteo_conversaciones ADD CONSTRAINT sorteo_conversaciones_estado_check CHECK ((estado = ANY (ARRAY['new_lead'::text, 'awaiting_ticket_selection'::text, 'awaiting_customer_data'::text, 'awaiting_payment'::text, 'awaiting_receipt'::text, 'receipt_under_review'::text, 'paid_confirmed'::text, 'human_handoff'::text, 'cancelled'::text, 'closed_no_response'::text])));
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_estado_pago_check CHECK ((estado_pago = ANY (ARRAY['pendiente'::text, 'pendiente_revision'::text, 'confirmado'::text, 'rechazado'::text])));
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_moneda_check CHECK ((moneda = 'PYG'::text));
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_pago_metodo_check CHECK (((pago_metodo IS NULL) OR (pago_metodo = ANY (ARRAY['efectivo'::text, 'transferencia'::text, 'tarjeta'::text, 'otro'::text]))));
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_precio_fuente_check CHECK (((precio_fuente IS NULL) OR (precio_fuente = ANY (ARRAY['lista'::text, 'promo'::text]))));
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_venta_canal_check CHECK (((venta_canal IS NULL) OR (venta_canal = ANY (ARRAY['remote'::text, 'local'::text]))));
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_venta_origen_check CHECK (((venta_origen IS NULL) OR (venta_origen = ANY (ARRAY['whatsapp_flow'::text, 'erp_manual'::text]))));
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_delivery_mode_check CHECK ((delivery_mode = ANY (ARRAY['text_only'::text, 'text_and_image'::text, 'image_only'::text])));
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'generated'::text, 'sent'::text, 'error'::text])));
ALTER TABLE dymaerp.sorteos ADD CONSTRAINT sorteos_coupon_number_mode_check CHECK (((coupon_number_mode IS NULL) OR (coupon_number_mode = ANY (ARRAY['correlative'::text, 'random'::text]))));
ALTER TABLE dymaerp.sorteos ADD CONSTRAINT sorteos_estado_check CHECK ((estado = ANY (ARRAY['activo'::text, 'pausado'::text, 'cerrado'::text, 'finalizado'::text])));
ALTER TABLE dymaerp.sorteos ADD CONSTRAINT sorteos_ticket_delivery_mode_check CHECK ((ticket_delivery_mode = ANY (ARRAY['text_only'::text, 'text_and_image'::text, 'image_only'::text])));
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_dia_facturacion_check CHECK (((dia_facturacion >= 1) AND (dia_facturacion <= 28)));
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_dia_vencimiento_check CHECK (((dia_vencimiento >= 1) AND (dia_vencimiento <= 31)));
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_estado_check CHECK ((estado = ANY (ARRAY['activa'::text, 'pausada'::text, 'cancelada'::text])));
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_mes_facturacion_check CHECK (((mes_facturacion >= 1) AND (mes_facturacion <= 12)));
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_meses_hasta_vencimiento_check CHECK (((meses_hasta_vencimiento >= 0) AND (meses_hasta_vencimiento <= 12)));
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_moneda_check CHECK ((moneda = ANY (ARRAY['GS'::text, 'USD'::text])));
ALTER TABLE dymaerp.tipificaciones ADD CONSTRAINT tipificaciones_resultado_check CHECK ((resultado = ANY (ARRAY['Pendiente'::text, 'Resuelto'::text, 'Escalar'::text])));
ALTER TABLE dymaerp.tipificaciones ADD CONSTRAINT tipificaciones_tipo_gestion_check CHECK ((tipo_gestion = ANY (ARRAY['Consulta'::text, 'Reclamo'::text, 'Seguimiento'::text, 'Promesa de pago'::text, 'Soporte técnico'::text, 'Cambio plan'::text])));
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_area_check CHECK (((area IS NULL) OR (area = ANY (ARRAY['ventas'::text, 'soporte'::text, 'finanzas'::text, 'operaciones'::text, 'administracion'::text]))));
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_estado_check CHECK ((estado = ANY (ARRAY['activo'::text, 'inactivo'::text])));
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_porcentaje_comision_check CHECK (((porcentaje_comision IS NULL) OR ((porcentaje_comision >= (0)::numeric) AND (porcentaje_comision <= (100)::numeric))));
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_tipo_contrato_check CHECK (((tipo_contrato IS NULL) OR (tipo_contrato = ANY (ARRAY['salario'::text, 'comision'::text, 'mixto'::text, 'prestador_servicio'::text]))));
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_estado_check CHECK ((estado = ANY (ARRAY['pendiente'::text, 'completada'::text, 'anulada'::text, 'parcialmente_devuelta'::text, 'devuelta_total'::text])));
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_metodo_pago_chk CHECK ((metodo_pago = ANY (ARRAY['efectivo'::text, 'tarjeta'::text, 'transferencia'::text, 'mixto'::text])));
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_moneda_check CHECK ((moneda = ANY (ARRAY['GS'::text, 'USD'::text])));
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_tipo_venta_check CHECK ((tipo_venta = ANY (ARRAY['CONTADO'::text, 'CREDITO'::text])));
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_manual_sin_producto_check CHECK ((((es_manual = true) AND (producto_id IS NULL)) OR ((es_manual = false) AND (producto_id IS NOT NULL))));
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_tipo_iva_check CHECK ((tipo_iva = ANY (ARRAY['EXENTA'::text, '5%'::text, '10%'::text])));
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_tipo_precio_check CHECK ((tipo_precio = ANY (ARRAY['minorista'::text, 'mayorista'::text, 'distribuidor'::text, 'costo'::text])));
ALTER TABLE dymaerp.ventas_pagos_detalle ADD CONSTRAINT ventas_pagos_detalle_metodo_pago_check CHECK ((metodo_pago = ANY (ARRAY['efectivo'::text, 'transferencia'::text, 'tarjeta'::text, 'qr'::text, 'billetera'::text, 'otro'::text])));
ALTER TABLE dymaerp.ventas_pagos_detalle ADD CONSTRAINT vpd_conciliacion_estado_check CHECK ((conciliacion_estado = ANY (ARRAY['pendiente'::text, 'aprobado'::text, 'rechazado'::text])));

-- ---------------------------------------------------------------------------
-- 3) FOREIGN KEYS (286) - las que apuntan a auth.users se mantienen
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.caja_movimientos ADD CONSTRAINT caja_movimientos_caja_fk FOREIGN KEY (caja_id) REFERENCES dymaerp.cajas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.categorias_productos ADD CONSTRAINT categorias_productos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.categorias_productos ADD CONSTRAINT categorias_productos_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES dymaerp.categorias_productos(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_agents ADD CONSTRAINT chat_agents_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_campaign_events ADD CONSTRAINT chat_campaign_events_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES dymaerp.chat_campaigns(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_campaign_events ADD CONSTRAINT chat_campaign_events_recipient_id_fkey FOREIGN KEY (recipient_id) REFERENCES dymaerp.chat_campaign_recipients(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_campaign_jobs ADD CONSTRAINT chat_campaign_jobs_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES dymaerp.chat_campaigns(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_campaign_recipients ADD CONSTRAINT chat_campaign_recipients_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES dymaerp.chat_campaigns(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_campaign_templates ADD CONSTRAINT chat_campaign_templates_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES dymaerp.chat_channels(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES dymaerp.chat_channels(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_campaigns ADD CONSTRAINT chat_campaigns_template_id_fkey FOREIGN KEY (template_id) REFERENCES dymaerp.chat_campaign_templates(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_channel_quick_replies ADD CONSTRAINT chat_channel_quick_replies_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES dymaerp.chat_channels(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_channels ADD CONSTRAINT chat_channels_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES dymaerp.chat_channels(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_flow_session_id_fkey FOREIGN KEY (flow_session_id) REFERENCES dymaerp.chat_flow_sessions(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_comprobante_validaciones ADD CONSTRAINT chat_comprobante_validaciones_sorteo_entrada_id_fkey FOREIGN KEY (sorteo_entrada_id) REFERENCES dymaerp.sorteo_entradas(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_contacts ADD CONSTRAINT chat_contacts_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_contacts ADD CONSTRAINT chat_contacts_crm_prospecto_id_fkey FOREIGN KEY (crm_prospecto_id) REFERENCES dymaerp.crm_prospectos(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_contacts ADD CONSTRAINT chat_contacts_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_conversation_closures ADD CONSTRAINT chat_conversation_closures_closure_state_id_fkey FOREIGN KEY (closure_state_id) REFERENCES dymaerp.chat_queue_closure_states(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_conversation_closures ADD CONSTRAINT chat_conversation_closures_closure_substate_id_fkey FOREIGN KEY (closure_substate_id) REFERENCES dymaerp.chat_queue_closure_substates(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_conversation_closures ADD CONSTRAINT chat_conversation_closures_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_conversation_closures ADD CONSTRAINT chat_conversation_closures_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_active_flow_session_id_fkey FOREIGN KEY (active_flow_session_id) REFERENCES dymaerp.chat_flow_sessions(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_assigned_agent_id_fkey FOREIGN KEY (assigned_agent_id) REFERENCES dymaerp.chat_agents(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES dymaerp.chat_channels(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_contact_id_fkey FOREIGN KEY (contact_id) REFERENCES dymaerp.chat_contacts(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_first_revendedor_id_fkey FOREIGN KEY (first_revendedor_id) REFERENCES dymaerp.sorteo_revendedores(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_conversations ADD CONSTRAINT chat_conversations_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_empresa_operator_roles ADD CONSTRAINT chat_empresa_operator_roles_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_data ADD CONSTRAINT chat_flow_data_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_data ADD CONSTRAINT chat_flow_data_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_data ADD CONSTRAINT chat_flow_data_flow_session_id_fkey FOREIGN KEY (flow_session_id) REFERENCES dymaerp.chat_flow_sessions(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_events ADD CONSTRAINT chat_flow_events_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_events ADD CONSTRAINT chat_flow_events_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_events ADD CONSTRAINT chat_flow_events_flow_session_id_fkey FOREIGN KEY (flow_session_id) REFERENCES dymaerp.chat_flow_sessions(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_flow_events ADD CONSTRAINT chat_flow_events_selected_option_id_fkey FOREIGN KEY (selected_option_id) REFERENCES dymaerp.chat_flow_options(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_flow_node_blocks ADD CONSTRAINT chat_flow_node_blocks_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_node_blocks ADD CONSTRAINT chat_flow_node_blocks_node_id_fkey FOREIGN KEY (node_id) REFERENCES dymaerp.chat_flow_nodes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_nodes ADD CONSTRAINT chat_flow_nodes_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_options ADD CONSTRAINT chat_flow_options_node_id_fkey FOREIGN KEY (node_id) REFERENCES dymaerp.chat_flow_nodes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_recontact_rules ADD CONSTRAINT cfr_rules_flow_fk FOREIGN KEY (empresa_id, flow_code) REFERENCES dymaerp.chat_flows(empresa_id, flow_code) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_recontact_runs ADD CONSTRAINT chat_flow_recontact_runs_rule_id_fkey FOREIGN KEY (rule_id) REFERENCES dymaerp.chat_flow_recontact_rules(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_sessions ADD CONSTRAINT chat_flow_sessions_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_sessions ADD CONSTRAINT chat_flow_sessions_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flow_sessions ADD CONSTRAINT chat_flow_sessions_revendedor_id_fkey FOREIGN KEY (revendedor_id) REFERENCES dymaerp.sorteo_revendedores(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_flows ADD CONSTRAINT chat_flows_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_flows ADD CONSTRAINT chat_flows_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_messages ADD CONSTRAINT chat_messages_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_messages ADD CONSTRAINT chat_messages_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_channels ADD CONSTRAINT chat_queue_channels_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES dymaerp.chat_channels(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_channels ADD CONSTRAINT chat_queue_channels_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_channels ADD CONSTRAINT chat_queue_channels_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_closure_states ADD CONSTRAINT chat_queue_closure_states_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_closure_substates ADD CONSTRAINT chat_queue_closure_substates_closure_state_id_fkey FOREIGN KEY (closure_state_id) REFERENCES dymaerp.chat_queue_closure_states(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_supervisors ADD CONSTRAINT chat_queue_supervisors_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queue_supervisors ADD CONSTRAINT chat_queue_supervisors_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_queues ADD CONSTRAINT chat_queues_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_routing_events ADD CONSTRAINT chat_routing_events_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_routing_events ADD CONSTRAINT chat_routing_events_queue_id_fkey FOREIGN KEY (queue_id) REFERENCES dymaerp.chat_queues(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.chat_supervisor_agents ADD CONSTRAINT chat_supervisor_agents_agent_usuario_id_fkey FOREIGN KEY (agent_usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_supervisor_agents ADD CONSTRAINT chat_supervisor_agents_supervisor_usuario_id_fkey FOREIGN KEY (supervisor_usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_usuario_omnicanal ADD CONSTRAINT chat_usuario_omnicanal_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.chat_usuario_omnicanal ADD CONSTRAINT chat_usuario_omnicanal_work_schedule_id_fkey FOREIGN KEY (work_schedule_id) REFERENCES dymaerp.chat_omnicanal_work_schedules(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.cliente_historial ADD CONSTRAINT cliente_historial_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_historial ADD CONSTRAINT cliente_historial_creado_por_auth_user_id_fkey FOREIGN KEY (creado_por_auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.cliente_historial ADD CONSTRAINT cliente_historial_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_obligaciones_tributarias ADD CONSTRAINT cliente_obligaciones_tributarias_cliente_perfil_id_fkey FOREIGN KEY (cliente_perfil_id) REFERENCES dymaerp.cliente_perfil_tributario(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_obligaciones_tributarias ADD CONSTRAINT cliente_obligaciones_tributarias_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_obligaciones_tributarias ADD CONSTRAINT cliente_obligaciones_tributarias_obligacion_catalogo_id_fkey FOREIGN KEY (obligacion_catalogo_id) REFERENCES dymaerp.obligaciones_tributarias_catalogo(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_perfil_tributario ADD CONSTRAINT cliente_perfil_tributario_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_perfil_tributario ADD CONSTRAINT cliente_perfil_tributario_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.cliente_tipos_servicio_catalogo ADD CONSTRAINT cliente_tipos_servicio_catalogo_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_baja_operativa_by_user_id_fkey FOREIGN KEY (baja_operativa_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_deleted_by_user_id_fkey FOREIGN KEY (deleted_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_plan_comercial_id_fkey FOREIGN KEY (plan_comercial_id) REFERENCES dymaerp.planes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_project_manager_id_fkey FOREIGN KEY (project_manager_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.clientes ADD CONSTRAINT clientes_vendedor_usuario_id_fkey FOREIGN KEY (vendedor_usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.cobros_clientes ADD CONSTRAINT cobros_clientes_cuenta_por_cobrar_id_fkey FOREIGN KEY (cuenta_por_cobrar_id) REFERENCES dymaerp.cuentas_por_cobrar(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_ajustes ADD CONSTRAINT comision_ajustes_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.comision_ajustes ADD CONSTRAINT comision_ajustes_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_ajustes ADD CONSTRAINT comision_ajustes_linea_id_fkey FOREIGN KEY (linea_id) REFERENCES dymaerp.comision_lineas(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.comision_ajustes ADD CONSTRAINT comision_ajustes_periodo_id_fkey FOREIGN KEY (periodo_id) REFERENCES dymaerp.comision_periodos(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.comision_equipo_miembros ADD CONSTRAINT comision_equipo_miembros_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_equipo_miembros ADD CONSTRAINT comision_equipo_miembros_equipo_id_fkey FOREIGN KEY (equipo_id) REFERENCES dymaerp.comision_equipos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_equipo_miembros ADD CONSTRAINT comision_equipo_miembros_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_equipos ADD CONSTRAINT comision_equipos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_equipos ADD CONSTRAINT comision_equipos_supervisor_usuario_id_fkey FOREIGN KEY (supervisor_usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_escalas ADD CONSTRAINT comision_escalas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_escalas ADD CONSTRAINT comision_escalas_politica_id_fkey FOREIGN KEY (politica_id) REFERENCES dymaerp.comision_politicas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_lineas ADD CONSTRAINT comision_lineas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_lineas ADD CONSTRAINT comision_lineas_periodo_id_fkey FOREIGN KEY (periodo_id) REFERENCES dymaerp.comision_periodos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_lineas ADD CONSTRAINT comision_lineas_usuario_vendedor_id_fkey FOREIGN KEY (usuario_vendedor_id) REFERENCES dymaerp.usuarios(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.comision_periodos ADD CONSTRAINT comision_periodos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_periodos ADD CONSTRAINT comision_periodos_politica_id_fkey FOREIGN KEY (politica_id) REFERENCES dymaerp.comision_politicas(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.comision_politica_versiones ADD CONSTRAINT comision_politica_versiones_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.comision_politica_versiones ADD CONSTRAINT comision_politica_versiones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_politica_versiones ADD CONSTRAINT comision_politica_versiones_politica_id_fkey FOREIGN KEY (politica_id) REFERENCES dymaerp.comision_politicas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT comision_politicas_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT comision_politicas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.comision_politicas ADD CONSTRAINT comision_politicas_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_orden_compra_item_id_fkey FOREIGN KEY (orden_compra_item_id) REFERENCES dymaerp.ordenes_compra(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.compras ADD CONSTRAINT compras_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES dymaerp.proveedores(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.crm_etapas ADD CONSTRAINT crm_etapas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.crm_notas ADD CONSTRAINT crm_notas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.crm_notas ADD CONSTRAINT crm_notas_prospecto_id_fkey FOREIGN KEY (prospecto_id) REFERENCES dymaerp.crm_prospectos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.crm_prospectos ADD CONSTRAINT crm_prospectos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.devoluciones_venta ADD CONSTRAINT devoluciones_venta_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES dymaerp.ventas(id);
ALTER TABLE dymaerp.devoluciones_venta_cambios ADD CONSTRAINT devoluciones_venta_cambios_devolucion_id_fkey FOREIGN KEY (devolucion_id) REFERENCES dymaerp.devoluciones_venta(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.devoluciones_venta_items ADD CONSTRAINT devoluciones_venta_items_devolucion_id_fkey FOREIGN KEY (devolucion_id) REFERENCES dymaerp.devoluciones_venta(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.devoluciones_venta_items ADD CONSTRAINT devoluciones_venta_items_venta_item_id_fkey FOREIGN KEY (venta_item_id) REFERENCES dymaerp.ventas_items(id);
ALTER TABLE dymaerp.empresa_autoimpresor_config ADD CONSTRAINT empresa_autoimpresor_config_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.empresa_dashboard_views ADD CONSTRAINT empresa_dashboard_views_dashboard_view_id_fkey FOREIGN KEY (dashboard_view_id) REFERENCES dymaerp.dashboard_views(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.empresa_dashboard_views ADD CONSTRAINT empresa_dashboard_views_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.empresa_facturacion_modo ADD CONSTRAINT empresa_facturacion_modo_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.empresa_modulos ADD CONSTRAINT empresa_modulos_modulo_id_fkey FOREIGN KEY (modulo_id) REFERENCES dymaerp.modulos(id);
ALTER TABLE dymaerp.empresa_sifen_config ADD CONSTRAINT empresa_sifen_config_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_autoimpresor ADD CONSTRAINT factura_autoimpresor_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES dymaerp.ventas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_electronica ADD CONSTRAINT factura_electronica_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_electronica ADD CONSTRAINT factura_electronica_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_electronica_evento ADD CONSTRAINT factura_electronica_evento_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_electronica_evento ADD CONSTRAINT factura_electronica_evento_factura_electronica_id_fkey FOREIGN KEY (factura_electronica_id) REFERENCES dymaerp.factura_electronica(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_items ADD CONSTRAINT factura_items_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.factura_items ADD CONSTRAINT factura_items_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.facturas ADD CONSTRAINT facturas_suscripcion_id_fkey FOREIGN KEY (suscripcion_id) REFERENCES dymaerp.suscripciones(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.gastos ADD CONSTRAINT gastos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.imports_audit ADD CONSTRAINT imports_audit_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.inventario_stock_ubicacion ADD CONSTRAINT inventario_stock_ubicacion_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.inventario_stock_ubicacion ADD CONSTRAINT inventario_stock_ubicacion_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.inventario_stock_ubicacion ADD CONSTRAINT inventario_stock_ubicacion_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES dymaerp.inventario_ubicaciones(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.inventario_ubicaciones ADD CONSTRAINT inventario_ubicaciones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.inventario_ubicaciones ADD CONSTRAINT inventario_ubicaciones_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES dymaerp.inventario_ubicaciones(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_calendarios ADD CONSTRAINT marketing_calendarios_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_calendarios ADD CONSTRAINT marketing_calendarios_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_calendarios ADD CONSTRAINT marketing_calendarios_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_calendarios ADD CONSTRAINT marketing_calendarios_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_comentarios ADD CONSTRAINT marketing_comentarios_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_comentarios ADD CONSTRAINT marketing_comentarios_pieza_id_fkey FOREIGN KEY (pieza_id) REFERENCES dymaerp.marketing_piezas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_comentarios ADD CONSTRAINT marketing_comentarios_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_historial_estados ADD CONSTRAINT marketing_historial_estados_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_historial_estados ADD CONSTRAINT marketing_historial_estados_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_historial_estados ADD CONSTRAINT marketing_historial_estados_pieza_id_fkey FOREIGN KEY (pieza_id) REFERENCES dymaerp.marketing_piezas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_calendario_id_fkey FOREIGN KEY (calendario_id) REFERENCES dymaerp.marketing_calendarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_responsable_id_fkey FOREIGN KEY (responsable_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_piezas ADD CONSTRAINT marketing_piezas_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES dymaerp.planes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_responsable_user_id_fkey FOREIGN KEY (responsable_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.marketing_tasks ADD CONSTRAINT marketing_tasks_suscripcion_id_fkey FOREIGN KEY (suscripcion_id) REFERENCES dymaerp.suscripciones(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES dymaerp.inventario_ubicaciones(id);
ALTER TABLE dymaerp.movimientos_inventario ADD CONSTRAINT movimientos_inventario_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES dymaerp.ventas(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_factura_electronica_origen_id_fkey FOREIGN KEY (factura_electronica_origen_id) REFERENCES dymaerp.factura_electronica(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.nota_credito ADD CONSTRAINT nota_credito_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.nota_credito_electronica ADD CONSTRAINT nota_credito_electronica_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.nota_credito_electronica ADD CONSTRAINT nota_credito_electronica_nota_credito_id_fkey FOREIGN KEY (nota_credito_id) REFERENCES dymaerp.nota_credito(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.nota_credito_evento ADD CONSTRAINT nota_credito_evento_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.nota_credito_evento ADD CONSTRAINT nota_credito_evento_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.nota_credito_evento ADD CONSTRAINT nota_credito_evento_nota_credito_id_fkey FOREIGN KEY (nota_credito_id) REFERENCES dymaerp.nota_credito(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id);
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_ubicacion_destino_id_fkey FOREIGN KEY (ubicacion_destino_id) REFERENCES dymaerp.inventario_ubicaciones(id);
ALTER TABLE dymaerp.notas_remision ADD CONSTRAINT notas_remision_ubicacion_origen_id_fkey FOREIGN KEY (ubicacion_origen_id) REFERENCES dymaerp.inventario_ubicaciones(id);
ALTER TABLE dymaerp.notas_remision_items ADD CONSTRAINT notas_remision_items_nota_remision_id_fkey FOREIGN KEY (nota_remision_id) REFERENCES dymaerp.notas_remision(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.notas_remision_items ADD CONSTRAINT notas_remision_items_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id);
ALTER TABLE dymaerp.omnichannel_routes ADD CONSTRAINT omnichannel_routes_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.pagos ADD CONSTRAINT pagos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.pagos ADD CONSTRAINT pagos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.pagos ADD CONSTRAINT pagos_factura_id_fkey FOREIGN KEY (factura_id) REFERENCES dymaerp.facturas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.pagos ADD CONSTRAINT pagos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.planes ADD CONSTRAINT planes_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.presupuesto_items ADD CONSTRAINT presupuesto_items_presupuesto_id_fkey FOREIGN KEY (presupuesto_id) REFERENCES dymaerp.presupuestos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.produccion_items ADD CONSTRAINT produccion_items_produccion_id_fkey FOREIGN KEY (produccion_id) REFERENCES dymaerp.producciones(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.producto_categorias ADD CONSTRAINT producto_categorias_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES dymaerp.categorias_productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.producto_categorias ADD CONSTRAINT producto_categorias_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.producto_categorias ADD CONSTRAINT producto_categorias_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.producto_presentaciones ADD CONSTRAINT producto_presentaciones_producto_fk FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_categoria_principal_id_fkey FOREIGN KEY (categoria_principal_id) REFERENCES dymaerp.categorias_productos(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_proveedor_principal_id_fkey FOREIGN KEY (proveedor_principal_id) REFERENCES dymaerp.proveedores(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.productos ADD CONSTRAINT productos_ubicacion_principal_id_fkey FOREIGN KEY (ubicacion_principal_id) REFERENCES dymaerp.inventario_ubicaciones(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.productos_stock_ubicacion ADD CONSTRAINT productos_stock_ubicacion_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.productos_stock_ubicacion ADD CONSTRAINT productos_stock_ubicacion_ubicacion_id_fkey FOREIGN KEY (ubicacion_id) REFERENCES dymaerp.inventario_ubicaciones(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_categoria_rel ADD CONSTRAINT proveedor_categoria_rel_categoria_id_fkey FOREIGN KEY (categoria_id) REFERENCES dymaerp.proveedor_categorias(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_categoria_rel ADD CONSTRAINT proveedor_categoria_rel_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_categoria_rel ADD CONSTRAINT proveedor_categoria_rel_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES dymaerp.proveedores(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_categorias ADD CONSTRAINT proveedor_categorias_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_productos ADD CONSTRAINT proveedor_productos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_productos ADD CONSTRAINT proveedor_productos_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedor_productos ADD CONSTRAINT proveedor_productos_proveedor_id_fkey FOREIGN KEY (proveedor_id) REFERENCES dymaerp.proveedores(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proveedores ADD CONSTRAINT proveedores_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_archivos ADD CONSTRAINT proyecto_archivos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_archivos ADD CONSTRAINT proyecto_archivos_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES dymaerp.proyectos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_archivos ADD CONSTRAINT proyecto_archivos_uploaded_by_fkey FOREIGN KEY (uploaded_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyecto_comentarios ADD CONSTRAINT proyecto_comentarios_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_comentarios ADD CONSTRAINT proyecto_comentarios_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES dymaerp.proyectos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_comentarios ADD CONSTRAINT proyecto_comentarios_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_estado_historial ADD CONSTRAINT proyecto_estado_historial_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyecto_estado_historial ADD CONSTRAINT proyecto_estado_historial_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_estado_historial ADD CONSTRAINT proyecto_estado_historial_estado_anterior_id_fkey FOREIGN KEY (estado_anterior_id) REFERENCES dymaerp.proyecto_estados(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyecto_estado_historial ADD CONSTRAINT proyecto_estado_historial_estado_nuevo_id_fkey FOREIGN KEY (estado_nuevo_id) REFERENCES dymaerp.proyecto_estados(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.proyecto_estado_historial ADD CONSTRAINT proyecto_estado_historial_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES dymaerp.proyectos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_estados ADD CONSTRAINT proyecto_estados_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_prioridades_config ADD CONSTRAINT proyecto_prioridades_config_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_qa_revisiones ADD CONSTRAINT proyecto_qa_revisiones_estado_salida_id_fkey FOREIGN KEY (estado_salida_id) REFERENCES dymaerp.proyecto_estados(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyecto_qa_revisiones ADD CONSTRAINT proyecto_qa_revisiones_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES dymaerp.proyectos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT proyecto_tareas_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT proyecto_tareas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT proyecto_tareas_proyecto_id_fkey FOREIGN KEY (proyecto_id) REFERENCES dymaerp.proyectos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyecto_tareas ADD CONSTRAINT proyecto_tareas_responsable_id_fkey FOREIGN KEY (responsable_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyecto_tipos ADD CONSTRAINT proyecto_tipos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_created_by_fkey FOREIGN KEY (created_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_estado_id_fkey FOREIGN KEY (estado_id) REFERENCES dymaerp.proyecto_estados(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_responsable_comercial_id_fkey FOREIGN KEY (responsable_comercial_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_responsable_tecnico_id_fkey FOREIGN KEY (responsable_tecnico_id) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_tipo_id_fkey FOREIGN KEY (tipo_id) REFERENCES dymaerp.proyecto_tipos(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.proyectos ADD CONSTRAINT proyectos_updated_by_fkey FOREIGN KEY (updated_by) REFERENCES dymaerp.usuarios(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_insumo_producto_id_fkey FOREIGN KEY (insumo_producto_id) REFERENCES dymaerp.productos(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.receta_items ADD CONSTRAINT receta_items_receta_id_fkey FOREIGN KEY (receta_id) REFERENCES dymaerp.recetas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.recetas ADD CONSTRAINT recetas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.recetas ADD CONSTRAINT recetas_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sifen_jobs ADD CONSTRAINT sifen_jobs_factura_electronica_id_fkey FOREIGN KEY (factura_electronica_id) REFERENCES dymaerp.factura_electronica(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_conversaciones ADD CONSTRAINT sorteo_conversaciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_conversaciones ADD CONSTRAINT sorteo_conversaciones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_conversaciones ADD CONSTRAINT sorteo_conversaciones_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_cupones ADD CONSTRAINT sorteo_cupones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_cupones ADD CONSTRAINT sorteo_cupones_entrada_id_fkey FOREIGN KEY (entrada_id) REFERENCES dymaerp.sorteo_entradas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_cupones ADD CONSTRAINT sorteo_cupones_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_chat_conversation_id_fkey FOREIGN KEY (chat_conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_comprobante_validacion_id_fkey FOREIGN KEY (comprobante_validacion_id) REFERENCES dymaerp.chat_comprobante_validaciones(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_conversacion_id_fkey FOREIGN KEY (conversacion_id) REFERENCES dymaerp.sorteo_conversaciones(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_revendedor_id_fkey FOREIGN KEY (revendedor_id) REFERENCES dymaerp.sorteo_revendedores(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_entradas ADD CONSTRAINT sorteo_entradas_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_revendedor_clicks ADD CONSTRAINT sorteo_revendedor_clicks_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_revendedor_clicks ADD CONSTRAINT sorteo_revendedor_clicks_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_revendedor_clicks ADD CONSTRAINT sorteo_revendedor_clicks_flow_session_id_fkey FOREIGN KEY (flow_session_id) REFERENCES dymaerp.chat_flow_sessions(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_revendedor_clicks ADD CONSTRAINT sorteo_revendedor_clicks_revendedor_id_fkey FOREIGN KEY (revendedor_id) REFERENCES dymaerp.sorteo_revendedores(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_revendedor_clicks ADD CONSTRAINT sorteo_revendedor_clicks_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_revendedores ADD CONSTRAINT sorteo_revendedores_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_revendedores ADD CONSTRAINT sorteo_revendedores_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_conversation_id_fkey FOREIGN KEY (conversation_id) REFERENCES dymaerp.chat_conversations(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_entrada_id_fkey FOREIGN KEY (entrada_id) REFERENCES dymaerp.sorteo_entradas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteo_ticket_deliveries ADD CONSTRAINT sorteo_ticket_deliveries_sorteo_id_fkey FOREIGN KEY (sorteo_id) REFERENCES dymaerp.sorteos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.sorteos ADD CONSTRAINT sorteos_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.suscripciones ADD CONSTRAINT suscripciones_plan_id_fkey FOREIGN KEY (plan_id) REFERENCES dymaerp.planes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.tipificaciones ADD CONSTRAINT tipificaciones_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.tipificaciones ADD CONSTRAINT tipificaciones_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.usuario_dashboard_views ADD CONSTRAINT usuario_dashboard_views_dashboard_view_id_fkey FOREIGN KEY (dashboard_view_id) REFERENCES dymaerp.dashboard_views(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.usuario_dashboard_views ADD CONSTRAINT usuario_dashboard_views_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.usuario_modulos ADD CONSTRAINT usuario_modulos_modulo_id_fkey FOREIGN KEY (modulo_id) REFERENCES dymaerp.modulos(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.usuario_modulos ADD CONSTRAINT usuario_modulos_usuario_id_fkey FOREIGN KEY (usuario_id) REFERENCES dymaerp.usuarios(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.usuarios ADD CONSTRAINT usuarios_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_cliente_id_fkey FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id) ON DELETE SET NULL;
ALTER TABLE dymaerp.ventas ADD CONSTRAINT ventas_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_empresa_id_fkey FOREIGN KEY (empresa_id) REFERENCES dymaerp.empresas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_producto_id_fkey FOREIGN KEY (producto_id) REFERENCES dymaerp.productos(id) ON DELETE RESTRICT;
ALTER TABLE dymaerp.ventas_items ADD CONSTRAINT ventas_items_venta_id_fkey FOREIGN KEY (venta_id) REFERENCES dymaerp.ventas(id) ON DELETE CASCADE;
ALTER TABLE dymaerp.ventas_pagos_detalle ADD CONSTRAINT ventas_pagos_detalle_entidad_bancaria_id_fkey FOREIGN KEY (entidad_bancaria_id) REFERENCES dymaerp.entidades_bancarias(id) ON DELETE SET NULL;

-- ---------------------------------------------------------------------------
-- 4) INDICES (352)
-- ---------------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS caja_movimientos_caja_idx ON dymaerp.caja_movimientos USING btree (caja_id, created_at);
CREATE INDEX IF NOT EXISTS caja_movimientos_devolucion_idx ON dymaerp.caja_movimientos USING btree (empresa_id, devolucion_id);
CREATE INDEX IF NOT EXISTS caja_movimientos_empresa_idx ON dymaerp.caja_movimientos USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS caja_movimientos_tipo_estado_fecha_idx ON dymaerp.caja_movimientos USING btree (empresa_id, tipo, ((anulado_at IS NULL)), created_at DESC);
CREATE INDEX IF NOT EXISTS idx_caja_movimientos_venta_id ON dymaerp.caja_movimientos USING btree (venta_id) WHERE (venta_id IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS cajas_activa_por_numero ON dymaerp.cajas USING btree (empresa_id, numero_caja) WHERE (estado = ANY (ARRAY['abierta'::text, 'en_cierre'::text]));
CREATE INDEX IF NOT EXISTS cajas_empresa_estado_idx ON dymaerp.cajas USING btree (empresa_id, estado);
CREATE INDEX IF NOT EXISTS cajas_empresa_fecha_idx ON dymaerp.cajas USING btree (empresa_id, fecha_apertura DESC);
CREATE INDEX IF NOT EXISTS idx_categorias_productos_activo ON dymaerp.categorias_productos USING btree (activo);
CREATE INDEX IF NOT EXISTS idx_categorias_productos_empresa ON dymaerp.categorias_productos USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_categorias_productos_nombre ON dymaerp.categorias_productos USING btree (nombre);
CREATE INDEX IF NOT EXISTS idx_categorias_productos_parent ON dymaerp.categorias_productos USING btree (parent_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_categorias_productos_empresa_nombre ON dymaerp.categorias_productos USING btree (empresa_id, lower(TRIM(BOTH FROM nombre)));
CREATE INDEX IF NOT EXISTS idx_chat_agents_empresa ON dymaerp.chat_agents USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_agents_online ON dymaerp.chat_agents USING btree (queue_id, is_online) WHERE (is_online = true);
CREATE INDEX IF NOT EXISTS idx_chat_agents_queue ON dymaerp.chat_agents USING btree (queue_id);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_events_e_c_cr ON dymaerp.chat_campaign_events USING btree (empresa_id, campaign_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_events_rec ON dymaerp.chat_campaign_events USING btree (recipient_id);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_jobs_c ON dymaerp.chat_campaign_jobs USING btree (campaign_id);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_jobs_e_st ON dymaerp.chat_campaign_jobs USING btree (empresa_id, status, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_recipients_conv ON dymaerp.chat_campaign_recipients USING btree (conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_recipients_e_c_st ON dymaerp.chat_campaign_recipients USING btree (empresa_id, campaign_id, status);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_recipients_wamid ON dymaerp.chat_campaign_recipients USING btree (provider_message_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_campaign_recipients_phone ON dymaerp.chat_campaign_recipients USING btree (campaign_id, phone_e164);
CREATE INDEX IF NOT EXISTS idx_chat_campaign_templates_ch_st ON dymaerp.chat_campaign_templates USING btree (empresa_id, channel_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_campaign_templates_natural ON dymaerp.chat_campaign_templates USING btree (empresa_id, channel_id, provider, name, language);
CREATE INDEX IF NOT EXISTS idx_chat_campaigns_e_ch ON dymaerp.chat_campaigns USING btree (empresa_id, channel_id);
CREATE INDEX IF NOT EXISTS idx_chat_campaigns_e_q ON dymaerp.chat_campaigns USING btree (empresa_id, queue_id);
CREATE INDEX IF NOT EXISTS idx_chat_campaigns_e_st_cr ON dymaerp.chat_campaigns USING btree (empresa_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_channel_quick_replies_ch ON dymaerp.chat_channel_quick_replies USING btree (channel_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_chat_channel_quick_replies_e ON dymaerp.chat_channel_quick_replies USING btree (empresa_id);
CREATE UNIQUE INDEX IF NOT EXISTS chat_channels_meta_phone_number_id_uidx ON dymaerp.chat_channels USING btree (meta_phone_number_id) WHERE ((meta_phone_number_id IS NOT NULL) AND (btrim(meta_phone_number_id) <> ''::text));
CREATE INDEX IF NOT EXISTS idx_chat_channels_empresa ON dymaerp.chat_channels USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_channels_empresa_activo ON dymaerp.chat_channels USING btree (empresa_id, activo) WHERE (activo = true);
CREATE INDEX IF NOT EXISTS idx_chat_comp_val_conversation ON dymaerp.chat_comprobante_validaciones USING btree (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_comp_val_empresa_hash ON dymaerp.chat_comprobante_validaciones USING btree (empresa_id, comprobante_hash);
CREATE INDEX IF NOT EXISTS idx_chat_comp_val_empresa_ocr_fp ON dymaerp.chat_comprobante_validaciones USING btree (empresa_id, ocr_fingerprint) WHERE ((ocr_fingerprint IS NOT NULL) AND (length(TRIM(BOTH FROM ocr_fingerprint)) > 0));
CREATE INDEX IF NOT EXISTS idx_chat_comp_val_entrada ON dymaerp.chat_comprobante_validaciones USING btree (sorteo_entrada_id) WHERE (sorteo_entrada_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_comp_val_flow_session ON dymaerp.chat_comprobante_validaciones USING btree (flow_session_id);
CREATE INDEX IF NOT EXISTS idx_chat_contacts_cliente ON dymaerp.chat_contacts USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_chat_contacts_empresa ON dymaerp.chat_contacts USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_contacts_empresa_name_lower ON dymaerp.chat_contacts USING btree (empresa_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_chat_contacts_empresa_phone_normalized ON dymaerp.chat_contacts USING btree (empresa_id, phone_normalized);
CREATE INDEX IF NOT EXISTS idx_chat_contacts_prospecto ON dymaerp.chat_contacts USING btree (crm_prospecto_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversation_closures_agent ON dymaerp.chat_conversation_closures USING btree (empresa_id, closed_by_usuario_id, closed_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_conversation_closures_conv ON dymaerp.chat_conversation_closures USING btree (conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversation_closures_empresa_closed ON dymaerp.chat_conversation_closures USING btree (empresa_id, closed_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_conversation_closures_labels ON dymaerp.chat_conversation_closures USING btree (empresa_id, closure_state_label, closure_substate_label);
CREATE INDEX IF NOT EXISTS idx_chat_conversation_closures_queue ON dymaerp.chat_conversation_closures USING btree (empresa_id, queue_id, closed_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_conv_emp_unassigned_recent ON dymaerp.chat_conversations USING btree (empresa_id, last_message_at DESC NULLS LAST) WHERE ((assigned_agent_id IS NULL) AND (status = ANY (ARRAY['open'::text, 'pending'::text])));
CREATE INDEX IF NOT EXISTS idx_chat_conv_empresa_last ON dymaerp.chat_conversations USING btree (empresa_id, last_message_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_active_flow_session ON dymaerp.chat_conversations USING btree (active_flow_session_id);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_assigned_agent ON dymaerp.chat_conversations USING btree (assigned_agent_id) WHERE (assigned_agent_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_first_revendedor ON dymaerp.chat_conversations USING btree (first_revendedor_id) WHERE (first_revendedor_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_conversations_queue ON dymaerp.chat_conversations USING btree (queue_id) WHERE (queue_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_empresa_operator_roles_empresa ON dymaerp.chat_empresa_operator_roles USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_flow_data_empresa_conversation ON dymaerp.chat_flow_data USING btree (empresa_id, conversation_id);
CREATE INDEX IF NOT EXISTS idx_chat_flow_data_flow_session ON dymaerp.chat_flow_data USING btree (flow_session_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_flow_data_conversation_field ON dymaerp.chat_flow_data USING btree (conversation_id, field_name);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_flow_data_session_field ON dymaerp.chat_flow_data USING btree (flow_session_id, field_name);
CREATE INDEX IF NOT EXISTS idx_chat_flow_events_conv_created_desc ON dymaerp.chat_flow_events USING btree (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_flow_events_session_created ON dymaerp.chat_flow_events USING btree (flow_session_id, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_flow_node_blocks_empresa ON dymaerp.chat_flow_node_blocks USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_flow_node_blocks_node_order ON dymaerp.chat_flow_node_blocks USING btree (node_id, sort_order, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_flow_nodes_empresa_flow ON dymaerp.chat_flow_nodes USING btree (empresa_id, flow_code);
CREATE INDEX IF NOT EXISTS idx_chat_flow_nodes_empresa_flow_sort ON dymaerp.chat_flow_nodes USING btree (empresa_id, flow_code, sort_order);
CREATE INDEX IF NOT EXISTS idx_chat_flow_options_node_sort ON dymaerp.chat_flow_options USING btree (node_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_cfr_rules_empresa_flow ON dymaerp.chat_flow_recontact_rules USING btree (empresa_id, flow_code);
CREATE INDEX IF NOT EXISTS idx_cfr_rules_flow_prio ON dymaerp.chat_flow_recontact_rules USING btree (flow_code, prioridad);
CREATE INDEX IF NOT EXISTS idx_cfr_runs_empresa_created ON dymaerp.chat_flow_recontact_runs USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cfr_runs_rule_created ON dymaerp.chat_flow_recontact_runs USING btree (rule_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_flow_sessions_conversation ON dymaerp.chat_flow_sessions USING btree (conversation_id, flow_code, status);
CREATE INDEX IF NOT EXISTS idx_chat_flow_sessions_empresa ON dymaerp.chat_flow_sessions USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_flow_sessions_revendedor ON dymaerp.chat_flow_sessions USING btree (revendedor_id) WHERE (revendedor_id IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_flow_sessions_one_active_per_conversation ON dymaerp.chat_flow_sessions USING btree (conversation_id) WHERE (status = 'active'::text);
CREATE INDEX IF NOT EXISTS idx_chat_flows_empresa ON dymaerp.chat_flows USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_flows_sorteo ON dymaerp.chat_flows USING btree (sorteo_id) WHERE (sorteo_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_messages_empresa_created_at ON dymaerp.chat_messages USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_messages_sender_type ON dymaerp.chat_messages USING btree (sender_type);
CREATE INDEX IF NOT EXISTS idx_chat_msg_conv ON dymaerp.chat_messages USING btree (conversation_id, created_at);
CREATE INDEX IF NOT EXISTS idx_chat_msg_empresa ON dymaerp.chat_messages USING btree (empresa_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_chat_msg_wa_id ON dymaerp.chat_messages USING btree (wa_message_id) WHERE (wa_message_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_chat_omn_sched_activo ON dymaerp.chat_omnicanal_work_schedules USING btree (empresa_id, is_active);
CREATE INDEX IF NOT EXISTS idx_chat_omn_sched_empresa ON dymaerp.chat_omnicanal_work_schedules USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_queue_channels_channel ON dymaerp.chat_queue_channels USING btree (channel_id);
CREATE INDEX IF NOT EXISTS idx_chat_queue_channels_empresa ON dymaerp.chat_queue_channels USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_queue_channels_queue ON dymaerp.chat_queue_channels USING btree (queue_id);
CREATE INDEX IF NOT EXISTS idx_chat_closure_states_empresa ON dymaerp.chat_queue_closure_states USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_closure_states_queue ON dymaerp.chat_queue_closure_states USING btree (queue_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_chat_closure_substates_state ON dymaerp.chat_queue_closure_substates USING btree (closure_state_id, sort_order);
CREATE INDEX IF NOT EXISTS idx_chat_queue_supervisors_empresa_usuario ON dymaerp.chat_queue_supervisors USING btree (empresa_id, usuario_id);
CREATE INDEX IF NOT EXISTS idx_chat_queues_empresa_active ON dymaerp.chat_queues USING btree (empresa_id, is_active) WHERE (is_active = true);
CREATE INDEX IF NOT EXISTS idx_cre_conv ON dymaerp.chat_routing_events USING btree (conversation_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cre_emp ON dymaerp.chat_routing_events USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_chat_supervisor_agents_supervisor ON dymaerp.chat_supervisor_agents USING btree (empresa_id, supervisor_usuario_id);
CREATE INDEX IF NOT EXISTS idx_chat_usuario_omnicanal_empresa ON dymaerp.chat_usuario_omnicanal USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_chat_usuario_omnicanal_usuario ON dymaerp.chat_usuario_omnicanal USING btree (usuario_id);
CREATE INDEX IF NOT EXISTS idx_cliente_historial_cliente_at ON dymaerp.cliente_historial USING btree (cliente_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cliente_historial_empresa_at ON dymaerp.cliente_historial USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cliente_obligaciones_empresa ON dymaerp.cliente_obligaciones_tributarias USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_cliente_obligaciones_perfil ON dymaerp.cliente_obligaciones_tributarias USING btree (cliente_perfil_id);
CREATE INDEX IF NOT EXISTS idx_cliente_perfil_tributario_cliente ON dymaerp.cliente_perfil_tributario USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_cliente_perfil_tributario_empresa ON dymaerp.cliente_perfil_tributario USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS ixctsc_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.cliente_tipos_servicio_catalogo USING btree (empresa_id, activo, orden);
CREATE INDEX IF NOT EXISTS clientes_project_manager_id_idx ON dymaerp.clientes USING btree (project_manager_id) WHERE (project_manager_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_clientes_baja_operativa_at ON dymaerp.clientes USING btree (baja_operativa_at) WHERE (baja_operativa_at IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_clientes_created_by ON dymaerp.clientes USING btree (created_by_user_id);
CREATE INDEX IF NOT EXISTS idx_clientes_deleted_at ON dymaerp.clientes USING btree (deleted_at) WHERE (deleted_at IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_clientes_tipo_servicio ON dymaerp.clientes USING btree (tipo_servicio_cliente) WHERE (tipo_servicio_cliente IS NOT NULL);
CREATE INDEX IF NOT EXISTS ix_cli_vend_93405e10933cb8b99a0af6286dc9466b ON dymaerp.clientes USING btree (empresa_id, vendedor_usuario_id);
CREATE INDEX IF NOT EXISTS ix_cli_vend_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.clientes USING btree (empresa_id, vendedor_usuario_id);
CREATE INDEX IF NOT EXISTS idx_cobros_cliente ON dymaerp.cobros_clientes USING btree (empresa_id, cliente_id);
CREATE INDEX IF NOT EXISTS idx_cobros_cuenta ON dymaerp.cobros_clientes USING btree (cuenta_por_cobrar_id);
CREATE INDEX IF NOT EXISTS idx_cobros_empresa_fecha ON dymaerp.cobros_clientes USING btree (empresa_id, fecha_pago DESC);
CREATE INDEX IF NOT EXISTS ix_cob_cliente_fecha ON dymaerp.cobros_clientes USING btree (empresa_id, cliente_id, fecha_pago DESC);
CREATE INDEX IF NOT EXISTS ix_cob_cxc ON dymaerp.cobros_clientes USING btree (empresa_id, cuenta_por_cobrar_id);
CREATE INDEX IF NOT EXISTS ix_cob_empresa ON dymaerp.cobros_clientes USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS ix_cob_fecha ON dymaerp.cobros_clientes USING btree (empresa_id, fecha_pago DESC);
CREATE INDEX IF NOT EXISTS ix_caj_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_ajustes USING btree (empresa_id, periodo_id);
CREATE INDEX IF NOT EXISTS ix_ceqm_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_equipo_miembros USING btree (empresa_id, equipo_id);
CREATE INDEX IF NOT EXISTS ix_ceq_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_equipos USING btree (empresa_id, activo);
CREATE INDEX IF NOT EXISTS ix_ce_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_escalas USING btree (empresa_id, politica_id, orden);
CREATE INDEX IF NOT EXISTS ix_clin_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_lineas USING btree (empresa_id, periodo_id, usuario_vendedor_id);
CREATE INDEX IF NOT EXISTS ix_cper_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_periodos USING btree (empresa_id, fecha_inicio, fecha_fin);
CREATE INDEX IF NOT EXISTS ix_cpv_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_politica_versiones USING btree (empresa_id, politica_id);
CREATE INDEX IF NOT EXISTS ix_cp_act_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.comision_politicas USING btree (empresa_id, activo);
CREATE INDEX IF NOT EXISTS idx_compras_created_by ON dymaerp.compras USING btree (created_by);
CREATE INDEX IF NOT EXISTS idx_compras_empresa ON dymaerp.compras USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_compras_empresa_fecha ON dymaerp.compras USING btree (empresa_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_compras_empresa_numero ON dymaerp.compras USING btree (empresa_id, numero_control);
CREATE INDEX IF NOT EXISTS idx_compras_fecha ON dymaerp.compras USING btree (fecha);
CREATE INDEX IF NOT EXISTS idx_compras_orden_compra ON dymaerp.compras USING btree (empresa_id, orden_compra_numero);
CREATE INDEX IF NOT EXISTS idx_compras_orden_compra_item ON dymaerp.compras USING btree (orden_compra_item_id);
CREATE INDEX IF NOT EXISTS idx_compras_producto ON dymaerp.compras USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_compras_proveedor ON dymaerp.compras USING btree (proveedor_id);
CREATE INDEX IF NOT EXISTS idx_crm_etapas_empresa ON dymaerp.crm_etapas USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_crm_etapas_empresa_orden ON dymaerp.crm_etapas USING btree (empresa_id, orden);
CREATE INDEX IF NOT EXISTS idx_crm_notas_empresa ON dymaerp.crm_notas USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_crm_notas_prospecto ON dymaerp.crm_notas USING btree (prospecto_id);
CREATE INDEX IF NOT EXISTS idx_crm_prospectos_empresa ON dymaerp.crm_prospectos USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_crm_prospectos_empresa_origen ON dymaerp.crm_prospectos USING btree (empresa_id, origen_creacion);
CREATE INDEX IF NOT EXISTS idx_crm_prospectos_etapa ON dymaerp.crm_prospectos USING btree (etapa);
CREATE INDEX IF NOT EXISTS idx_cxc_cliente ON dymaerp.cuentas_por_cobrar USING btree (empresa_id, cliente_id);
CREATE INDEX IF NOT EXISTS idx_cxc_empresa_estado ON dymaerp.cuentas_por_cobrar USING btree (empresa_id, estado);
CREATE INDEX IF NOT EXISTS idx_cxc_vencimiento ON dymaerp.cuentas_por_cobrar USING btree (empresa_id, fecha_vencimiento);
CREATE INDEX IF NOT EXISTS ix_cxc_cliente ON dymaerp.cuentas_por_cobrar USING btree (empresa_id, cliente_id);
CREATE INDEX IF NOT EXISTS ix_cxc_empresa ON dymaerp.cuentas_por_cobrar USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS ix_cxc_estado_venc ON dymaerp.cuentas_por_cobrar USING btree (empresa_id, estado, fecha_vencimiento);
CREATE INDEX IF NOT EXISTS ix_cxc_venta ON dymaerp.cuentas_por_cobrar USING btree (empresa_id, venta_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_cxc_venta ON dymaerp.cuentas_por_cobrar USING btree (venta_id);
CREATE INDEX IF NOT EXISTS idx_dashboard_views_activo ON dymaerp.dashboard_views USING btree (activo);
CREATE INDEX IF NOT EXISTS devoluciones_venta_fecha_idx ON dymaerp.devoluciones_venta USING btree (empresa_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS devoluciones_venta_idem_uidx ON dymaerp.devoluciones_venta USING btree (empresa_id, idempotency_key) WHERE (idempotency_key IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS devoluciones_venta_numero_uidx ON dymaerp.devoluciones_venta USING btree (empresa_id, numero_devolucion);
CREATE INDEX IF NOT EXISTS devoluciones_venta_venta_idx ON dymaerp.devoluciones_venta USING btree (empresa_id, venta_id);
CREATE INDEX IF NOT EXISTS devoluciones_venta_cambios_dev_idx ON dymaerp.devoluciones_venta_cambios USING btree (empresa_id, devolucion_id);
CREATE INDEX IF NOT EXISTS devoluciones_venta_items_dev_idx ON dymaerp.devoluciones_venta_items USING btree (empresa_id, devolucion_id);
CREATE INDEX IF NOT EXISTS devoluciones_venta_items_vitem_idx ON dymaerp.devoluciones_venta_items USING btree (empresa_id, venta_item_id);
CREATE INDEX IF NOT EXISTS idx_edv_empresa ON dymaerp.empresa_dashboard_views USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_edv_view ON dymaerp.empresa_dashboard_views USING btree (dashboard_view_id);
CREATE UNIQUE INDEX IF NOT EXISTS empresas_data_schema_unique ON dymaerp.empresas USING btree (data_schema) WHERE (data_schema IS NOT NULL);
CREATE INDEX IF NOT EXISTS ix_entidades_bancarias_empresa_activo ON dymaerp.entidades_bancarias USING btree (empresa_id, activo);
CREATE UNIQUE INDEX IF NOT EXISTS uq_entidades_bancarias_codigo ON dymaerp.entidades_bancarias USING btree (empresa_id, lower(codigo)) WHERE ((codigo IS NOT NULL) AND (codigo <> ''::text));
CREATE UNIQUE INDEX IF NOT EXISTS uq_entidades_bancarias_empresa_nombre ON dymaerp.entidades_bancarias USING btree (empresa_id, lower(nombre));
CREATE UNIQUE INDEX IF NOT EXISTS factura_autoimpresor_numero_uq ON dymaerp.factura_autoimpresor USING btree (empresa_id, timbrado_numero, establecimiento_codigo, punto_expedicion_codigo, numero_secuencia);
CREATE UNIQUE INDEX IF NOT EXISTS factura_autoimpresor_venta_uq ON dymaerp.factura_autoimpresor USING btree (empresa_id, venta_id);
CREATE INDEX IF NOT EXISTS idx_factura_electronica_empresa ON dymaerp.factura_electronica USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_factura_electronica_empresa_estado ON dymaerp.factura_electronica USING btree (empresa_id, estado_sifen);
CREATE INDEX IF NOT EXISTS idx_factura_electronica_factura ON dymaerp.factura_electronica USING btree (factura_id);
CREATE INDEX IF NOT EXISTS idx_factura_electronica_evento_de ON dymaerp.factura_electronica_evento USING btree (factura_electronica_id);
CREATE INDEX IF NOT EXISTS idx_factura_electronica_evento_empresa ON dymaerp.factura_electronica_evento USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_factura_electronica_evento_empresa_created ON dymaerp.factura_electronica_evento USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_factura_items_empresa ON dymaerp.factura_items USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_factura_items_factura ON dymaerp.factura_items USING btree (factura_id);
CREATE INDEX IF NOT EXISTS idx_facturas_cliente ON dymaerp.facturas USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_facturas_empresa ON dymaerp.facturas USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_facturas_fecha ON dymaerp.facturas USING btree (fecha);
CREATE INDEX IF NOT EXISTS idx_facturas_suscripcion ON dymaerp.facturas USING btree (suscripcion_id);
CREATE INDEX IF NOT EXISTS gastos_empresa_fecha_idx ON dymaerp.gastos USING btree (empresa_id, fecha);
CREATE INDEX IF NOT EXISTS idx_imports_audit_empresa_fecha ON dymaerp.imports_audit USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_imports_audit_entidad ON dymaerp.imports_audit USING btree (entidad);
CREATE INDEX IF NOT EXISTS idx_stock_ubic_producto ON dymaerp.inventario_stock_ubicacion USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_stock_ubic_ubicacion ON dymaerp.inventario_stock_ubicacion USING btree (ubicacion_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_stock_ubicacion_principal_unica ON dymaerp.inventario_stock_ubicacion USING btree (empresa_id, producto_id) WHERE (es_principal = true);
CREATE UNIQUE INDEX IF NOT EXISTS uq_stock_ubicacion_triple ON dymaerp.inventario_stock_ubicacion USING btree (empresa_id, producto_id, ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_ubicaciones_empresa ON dymaerp.inventario_ubicaciones USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_ubicaciones_parent ON dymaerp.inventario_ubicaciones USING btree (parent_id);
CREATE INDEX IF NOT EXISTS idx_ubicaciones_tipo ON dymaerp.inventario_ubicaciones USING btree (tipo);
CREATE UNIQUE INDEX IF NOT EXISTS uq_ubicaciones_empresa_codigo ON dymaerp.inventario_ubicaciones USING btree (empresa_id, lower(TRIM(BOTH FROM codigo))) WHERE ((codigo IS NOT NULL) AND (TRIM(BOTH FROM codigo) <> ''::text));
CREATE INDEX IF NOT EXISTS ix_mk_cal_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_calendarios USING btree (empresa_id, cliente_id, mes);
CREATE INDEX IF NOT EXISTS ix_mk_com_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_comentarios USING btree (empresa_id, pieza_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_mk_hist_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_historial_estados USING btree (empresa_id, pieza_id, changed_at DESC);
CREATE INDEX IF NOT EXISTS ix_mk_pz_cli_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_piezas USING btree (empresa_id, cliente_id);
CREATE INDEX IF NOT EXISTS ix_mk_pz_lim_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_piezas USING btree (empresa_id, fecha_limite);
CREATE INDEX IF NOT EXISTS ix_mk_pz_prod_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_piezas USING btree (empresa_id, estado_produccion);
CREATE INDEX IF NOT EXISTS ix_mk_pz_resp_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.marketing_piezas USING btree (empresa_id, responsable_id);
CREATE INDEX IF NOT EXISTS idx_marketing_tasks_cliente ON dymaerp.marketing_tasks USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_marketing_tasks_empresa ON dymaerp.marketing_tasks USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_marketing_tasks_estado ON dymaerp.marketing_tasks USING btree (estado);
CREATE INDEX IF NOT EXISTS idx_marketing_tasks_fecha ON dymaerp.marketing_tasks USING btree (fecha_entrega);
CREATE INDEX IF NOT EXISTS idx_marketing_tasks_plan ON dymaerp.marketing_tasks USING btree (plan_id);
CREATE INDEX IF NOT EXISTS idx_marketing_tasks_suscripcion ON dymaerp.marketing_tasks USING btree (suscripcion_id);
CREATE INDEX IF NOT EXISTS idx_mov_produccion_id ON dymaerp.movimientos_inventario USING btree (produccion_id);
CREATE INDEX IF NOT EXISTS idx_mov_ubicacion ON dymaerp.movimientos_inventario USING btree (ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_movimientos_empresa ON dymaerp.movimientos_inventario USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_movimientos_fecha ON dymaerp.movimientos_inventario USING btree (fecha);
CREATE INDEX IF NOT EXISTS idx_movimientos_inventario_created_by ON dymaerp.movimientos_inventario USING btree (created_by);
CREATE INDEX IF NOT EXISTS idx_movimientos_producto ON dymaerp.movimientos_inventario USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_movimientos_venta ON dymaerp.movimientos_inventario USING btree (venta_id);
CREATE INDEX IF NOT EXISTS movimientos_inventario_devolucion_idx ON dymaerp.movimientos_inventario USING btree (empresa_id, devolucion_id);
CREATE INDEX IF NOT EXISTS idx_nota_credito_empresa ON dymaerp.nota_credito USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_nota_credito_empresa_created ON dymaerp.nota_credito USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_nota_credito_factura ON dymaerp.nota_credito USING btree (factura_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_nota_credito_factura_estado_activo ON dymaerp.nota_credito USING btree (factura_id) WHERE (estado_erp = ANY (ARRAY['borrador'::text, 'pendiente_envio_sifen'::text, 'aprobada'::text]));
CREATE INDEX IF NOT EXISTS idx_nota_credito_electronica_empresa ON dymaerp.nota_credito_electronica USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_nota_credito_evento_empresa ON dymaerp.nota_credito_evento USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_nota_credito_evento_nc ON dymaerp.nota_credito_evento USING btree (nota_credito_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_nr_destino ON dymaerp.notas_remision USING btree (ubicacion_destino_id, estado);
CREATE INDEX IF NOT EXISTS idx_nr_empresa ON dymaerp.notas_remision USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_nr_estado ON dymaerp.notas_remision USING btree (empresa_id, estado);
CREATE INDEX IF NOT EXISTS idx_nri_nr ON dymaerp.notas_remision_items USING btree (nota_remision_id);
CREATE INDEX IF NOT EXISTS idx_nri_producto ON dymaerp.notas_remision_items USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_notificaciones_empresa ON dymaerp.notificaciones USING btree (empresa_id, leida, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_notificaciones_activa ON dymaerp.notificaciones USING btree (empresa_id, producto_id, tipo) WHERE ((leida = false) AND (producto_id IS NOT NULL));
CREATE INDEX IF NOT EXISTS idx_omnichannel_routes_empresa ON dymaerp.omnichannel_routes USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_ordenes_compra_empresa ON dymaerp.ordenes_compra USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_ordenes_compra_estado ON dymaerp.ordenes_compra USING btree (empresa_id, estado);
CREATE INDEX IF NOT EXISTS idx_ordenes_compra_fecha ON dymaerp.ordenes_compra USING btree (fecha);
CREATE INDEX IF NOT EXISTS idx_ordenes_compra_numero ON dymaerp.ordenes_compra USING btree (empresa_id, numero_oc);
CREATE INDEX IF NOT EXISTS idx_ordenes_compra_proveedor ON dymaerp.ordenes_compra USING btree (proveedor_id);
CREATE INDEX IF NOT EXISTS idx_pagos_cliente ON dymaerp.pagos USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_pagos_empresa ON dymaerp.pagos USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_pagos_factura ON dymaerp.pagos USING btree (factura_id);
CREATE INDEX IF NOT EXISTS idx_pagos_fecha ON dymaerp.pagos USING btree (fecha_pago);
CREATE INDEX IF NOT EXISTS idx_pagos_usuario ON dymaerp.pagos USING btree (usuario_id);
CREATE INDEX IF NOT EXISTS pedidos_caja_armado_por_idx ON dymaerp.pedidos_caja USING btree (empresa_id, armado_por_id, created_at DESC);
CREATE INDEX IF NOT EXISTS pedidos_caja_empresa_estado_idx ON dymaerp.pedidos_caja USING btree (empresa_id, estado, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS pedidos_caja_numero_uniq ON dymaerp.pedidos_caja USING btree (empresa_id, numero) WHERE (numero IS NOT NULL);
CREATE INDEX IF NOT EXISTS pedidos_caja_venta_idx ON dymaerp.pedidos_caja USING btree (empresa_id, venta_id);
CREATE INDEX IF NOT EXISTS idx_planes_empresa ON dymaerp.planes USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_presupuesto_items_presupuesto ON dymaerp.presupuesto_items USING btree (presupuesto_id);
CREATE INDEX IF NOT EXISTS idx_presupuestos_empresa_fecha ON dymaerp.presupuestos USING btree (empresa_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_presupuestos_estado ON dymaerp.presupuestos USING btree (empresa_id, estado);
CREATE INDEX IF NOT EXISTS idx_produccion_items_produccion ON dymaerp.produccion_items USING btree (produccion_id);
CREATE INDEX IF NOT EXISTS idx_producciones_empresa_fecha ON dymaerp.producciones USING btree (empresa_id, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_producto_categorias_categoria ON dymaerp.producto_categorias USING btree (categoria_id);
CREATE INDEX IF NOT EXISTS idx_producto_categorias_producto ON dymaerp.producto_categorias USING btree (producto_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_producto_categoria_principal_unica ON dymaerp.producto_categorias USING btree (empresa_id, producto_id) WHERE (es_principal = true);
CREATE UNIQUE INDEX IF NOT EXISTS uq_producto_categorias_triple ON dymaerp.producto_categorias USING btree (empresa_id, producto_id, categoria_id);
CREATE UNIQUE INDEX IF NOT EXISTS producto_presentaciones_default_uniq ON dymaerp.producto_presentaciones USING btree (producto_id) WHERE ((es_default = true) AND (activo = true));
CREATE INDEX IF NOT EXISTS producto_presentaciones_empresa_idx ON dymaerp.producto_presentaciones USING btree (empresa_id);
CREATE UNIQUE INDEX IF NOT EXISTS producto_presentaciones_nombre_uniq ON dymaerp.producto_presentaciones USING btree (producto_id, lower(nombre));
CREATE INDEX IF NOT EXISTS producto_presentaciones_producto_idx ON dymaerp.producto_presentaciones USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_productos_destacado ON dymaerp.productos USING btree (empresa_id, destacado) WHERE (destacado = true);
CREATE INDEX IF NOT EXISTS idx_productos_empresa ON dymaerp.productos USING btree (empresa_id);
CREATE UNIQUE INDEX IF NOT EXISTS idx_productos_empresa_sku ON dymaerp.productos USING btree (empresa_id, sku);
CREATE INDEX IF NOT EXISTS idx_productos_es_insumo ON dymaerp.productos USING btree (empresa_id) WHERE (es_insumo = true);
CREATE INDEX IF NOT EXISTS idx_productos_es_vendible ON dymaerp.productos USING btree (empresa_id) WHERE (es_vendible = true);
CREATE INDEX IF NOT EXISTS idx_productos_tipo_producto ON dymaerp.productos USING btree (empresa_id, tipo_producto);
CREATE INDEX IF NOT EXISTS productos_discount_active_idx ON dymaerp.productos USING btree (empresa_id, discount_ends_at) WHERE ((discount_type IS NOT NULL) AND (discount_value > (0)::numeric));
CREATE INDEX IF NOT EXISTS productos_oferta_semana_destacada_idx ON dymaerp.productos USING btree (empresa_id) WHERE (oferta_semana_destacada = true);
CREATE UNIQUE INDEX IF NOT EXISTS uq_productos_codigo_barras ON dymaerp.productos USING btree (empresa_id, codigo_barras) WHERE (codigo_barras IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_psu_empresa_ubi ON dymaerp.productos_stock_ubicacion USING btree (empresa_id, ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_psu_producto ON dymaerp.productos_stock_ubicacion USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_psu_ubicacion ON dymaerp.productos_stock_ubicacion USING btree (ubicacion_id);
CREATE INDEX IF NOT EXISTS idx_prov_cat_rel_categoria ON dymaerp.proveedor_categoria_rel USING btree (categoria_id);
CREATE INDEX IF NOT EXISTS idx_prov_cat_rel_empresa ON dymaerp.proveedor_categoria_rel USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_prov_cat_rel_proveedor ON dymaerp.proveedor_categoria_rel USING btree (proveedor_id);
CREATE INDEX IF NOT EXISTS idx_proveedor_categorias_empresa ON dymaerp.proveedor_categorias USING btree (empresa_id);
CREATE UNIQUE INDEX IF NOT EXISTS proveedor_categorias_empresa_nombre_lower ON dymaerp.proveedor_categorias USING btree (empresa_id, lower(TRIM(BOTH FROM nombre)));
CREATE INDEX IF NOT EXISTS idx_proveedor_productos_empresa ON dymaerp.proveedor_productos USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_proveedor_productos_producto ON dymaerp.proveedor_productos USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_proveedor_productos_proveedor ON dymaerp.proveedor_productos USING btree (proveedor_id);
CREATE UNIQUE INDEX IF NOT EXISTS proveedor_productos_un_principal ON dymaerp.proveedor_productos USING btree (empresa_id, producto_id) WHERE es_principal;
CREATE INDEX IF NOT EXISTS idx_proveedores_empresa ON dymaerp.proveedores USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS ix_paf_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_archivos USING btree (empresa_id, proyecto_id);
CREATE INDEX IF NOT EXISTS ix_pc_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_comentarios USING btree (empresa_id, proyecto_id, created_at DESC);
CREATE INDEX IF NOT EXISTS ix_peh_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_estado_historial USING btree (empresa_id, proyecto_id, entered_at);
CREATE INDEX IF NOT EXISTS ix_pe_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_estados USING btree (empresa_id, activo, sort_order);
CREATE INDEX IF NOT EXISTS ix_ppc_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_prioridades_config USING btree (empresa_id, activo, sort_order);
CREATE INDEX IF NOT EXISTS idx_qa_rev_responsable ON dymaerp.proyecto_qa_revisiones USING btree (empresa_id, qa_responsable_id, salida_at);
CREATE UNIQUE INDEX IF NOT EXISTS uq_qa_rev_abierta ON dymaerp.proyecto_qa_revisiones USING btree (proyecto_id) WHERE (salida_at IS NULL);
CREATE INDEX IF NOT EXISTS ix_ptar_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_tareas USING btree (empresa_id, proyecto_id);
CREATE INDEX IF NOT EXISTS ix_pt_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyecto_tipos USING btree (empresa_id, activo);
CREATE INDEX IF NOT EXISTS ix_pr_cli_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyectos USING btree (empresa_id, cliente_id);
CREATE INDEX IF NOT EXISTS ix_pr_est_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyectos USING btree (empresa_id, estado_id, archivado);
CREATE INDEX IF NOT EXISTS ix_pr_fp_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyectos USING btree (empresa_id, fecha_prometida);
CREATE INDEX IF NOT EXISTS ix_pr_rc_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyectos USING btree (empresa_id, responsable_comercial_id);
CREATE INDEX IF NOT EXISTS ix_pr_rt_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyectos USING btree (empresa_id, responsable_tecnico_id);
CREATE INDEX IF NOT EXISTS ix_pr_tip_c9ff055d5178c1e5686eb62017e3c4ff ON dymaerp.proyectos USING btree (empresa_id, tipo_id);
CREATE INDEX IF NOT EXISTS idx_receta_items_empresa ON dymaerp.receta_items USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_receta_items_insumo ON dymaerp.receta_items USING btree (insumo_producto_id);
CREATE INDEX IF NOT EXISTS idx_receta_items_receta ON dymaerp.receta_items USING btree (receta_id);
CREATE INDEX IF NOT EXISTS idx_recetas_empresa ON dymaerp.recetas USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_recetas_producto ON dymaerp.recetas USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_recibos_empresa_fecha ON dymaerp.recibos_dinero USING btree (empresa_id, fecha DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_recibos_cobro ON dymaerp.recibos_dinero USING btree (cobro_cliente_id) WHERE (cobro_cliente_id IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS uq_recibos_empresa_numero ON dymaerp.recibos_dinero USING btree (empresa_id, numero_recibo);
CREATE UNIQUE INDEX IF NOT EXISTS uq_recibos_venta_contado ON dymaerp.recibos_dinero USING btree (venta_id) WHERE ((origen = 'venta_contado'::text) AND (venta_id IS NOT NULL));
CREATE INDEX IF NOT EXISTS idx_sifen_jobs_empresa_created ON dymaerp.sifen_jobs USING btree (empresa_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sifen_jobs_fe_created ON dymaerp.sifen_jobs USING btree (factura_electronica_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sifen_jobs_pendientes ON dymaerp.sifen_jobs USING btree (proximo_reintento_at NULLS FIRST, created_at) WHERE (estado = 'pendiente'::text);
CREATE INDEX IF NOT EXISTS idx_sifen_jobs_procesando ON dymaerp.sifen_jobs USING btree (procesando_desde) WHERE (estado = 'procesando'::text);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sifen_jobs_fe_activo ON dymaerp.sifen_jobs USING btree (factura_electronica_id) WHERE (estado = ANY (ARRAY['pendiente'::text, 'procesando'::text]));
CREATE INDEX IF NOT EXISTS idx_sorteo_conv_empresa ON dymaerp.sorteo_conversaciones USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_conv_estado ON dymaerp.sorteo_conversaciones USING btree (estado);
CREATE INDEX IF NOT EXISTS idx_sorteo_conv_sorteo ON dymaerp.sorteo_conversaciones USING btree (sorteo_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_conv_wa ON dymaerp.sorteo_conversaciones USING btree (whatsapp_numero);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_conv_activa ON dymaerp.sorteo_conversaciones USING btree (sorteo_id, whatsapp_numero) WHERE (activa = true);
CREATE INDEX IF NOT EXISTS idx_sorteo_cup_empresa ON dymaerp.sorteo_cupones USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_cup_entrada ON dymaerp.sorteo_cupones USING btree (entrada_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_cup_sorteo ON dymaerp.sorteo_cupones USING btree (sorteo_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_cupones_sorteo_coupon_value ON dymaerp.sorteo_cupones USING btree (sorteo_id, coupon_number_value) WHERE (coupon_number_value IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sorteo_ent_cliente ON dymaerp.sorteo_entradas USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_ent_comp_val ON dymaerp.sorteo_entradas USING btree (comprobante_validacion_id) WHERE (comprobante_validacion_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sorteo_ent_conv ON dymaerp.sorteo_entradas USING btree (conversacion_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_ent_empresa ON dymaerp.sorteo_entradas USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_ent_sorteo ON dymaerp.sorteo_entradas USING btree (sorteo_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_entradas_chat_conversation ON dymaerp.sorteo_entradas USING btree (chat_conversation_id) WHERE (chat_conversation_id IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sorteo_entradas_revendedor ON dymaerp.sorteo_entradas USING btree (revendedor_id) WHERE (revendedor_id IS NOT NULL);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_entradas_idempotency_key ON dymaerp.sorteo_entradas USING btree (idempotency_key) WHERE (idempotency_key IS NOT NULL);
CREATE INDEX IF NOT EXISTS idx_sorteo_rev_clicks_revendedor ON dymaerp.sorteo_revendedor_clicks USING btree (revendedor_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_sorteo_rev_clicks_sorteo ON dymaerp.sorteo_revendedor_clicks USING btree (sorteo_id, created_at DESC);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_rev_clicks_token ON dymaerp.sorteo_revendedor_clicks USING btree (attribution_token);
CREATE INDEX IF NOT EXISTS idx_sorteo_revendedores_empresa ON dymaerp.sorteo_revendedores USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_revendedores_sorteo ON dymaerp.sorteo_revendedores USING btree (sorteo_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_revendedores_sorteo_codigo_lower ON dymaerp.sorteo_revendedores USING btree (sorteo_id, lower(TRIM(BOTH FROM codigo_referido)));
CREATE INDEX IF NOT EXISTS idx_sorteo_ticket_empresa_sorteo ON dymaerp.sorteo_ticket_deliveries USING btree (empresa_id, sorteo_id);
CREATE INDEX IF NOT EXISTS idx_sorteo_ticket_status ON dymaerp.sorteo_ticket_deliveries USING btree (empresa_id, status);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_ticket_entrada_current ON dymaerp.sorteo_ticket_deliveries USING btree (entrada_id) WHERE is_current;
CREATE UNIQUE INDEX IF NOT EXISTS uq_sorteo_ticket_entrada_revision ON dymaerp.sorteo_ticket_deliveries USING btree (entrada_id, template_revision);
CREATE INDEX IF NOT EXISTS idx_sorteos_empresa ON dymaerp.sorteos USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_suscripciones_cliente ON dymaerp.suscripciones USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_suscripciones_empresa ON dymaerp.suscripciones USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_suscripciones_plan ON dymaerp.suscripciones USING btree (plan_id);
CREATE INDEX IF NOT EXISTS idx_tipificaciones_cliente ON dymaerp.tipificaciones USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_tipificaciones_empresa ON dymaerp.tipificaciones USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_udv_usuario ON dymaerp.usuario_dashboard_views USING btree (usuario_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_udv_one_default_per_user ON dymaerp.usuario_dashboard_views USING btree (usuario_id) WHERE (es_default IS TRUE);
CREATE INDEX IF NOT EXISTS idx_usuario_modulos_usuario ON dymaerp.usuario_modulos USING btree (usuario_id);
CREATE INDEX IF NOT EXISTS idx_usuarios_auth_user_id ON dymaerp.usuarios USING btree (auth_user_id);
CREATE INDEX IF NOT EXISTS idx_ventas_cliente ON dymaerp.ventas USING btree (cliente_id);
CREATE INDEX IF NOT EXISTS idx_ventas_empresa ON dymaerp.ventas USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_ventas_estado ON dymaerp.ventas USING btree (estado);
CREATE INDEX IF NOT EXISTS idx_ventas_fecha ON dymaerp.ventas USING btree (fecha);
CREATE INDEX IF NOT EXISTS ventas_caja_idx ON dymaerp.ventas USING btree (empresa_id, caja_id);
CREATE INDEX IF NOT EXISTS ventas_factura_id_idx ON dymaerp.ventas USING btree (factura_id);
CREATE INDEX IF NOT EXISTS idx_ventas_items_empresa ON dymaerp.ventas_items USING btree (empresa_id);
CREATE INDEX IF NOT EXISTS idx_ventas_items_producto ON dymaerp.ventas_items USING btree (producto_id);
CREATE INDEX IF NOT EXISTS idx_ventas_items_venta ON dymaerp.ventas_items USING btree (venta_id);
CREATE INDEX IF NOT EXISTS ix_ventas_pagos_detalle_empresa_fecha ON dymaerp.ventas_pagos_detalle USING btree (empresa_id, fecha_pago);
CREATE INDEX IF NOT EXISTS ix_ventas_pagos_detalle_venta ON dymaerp.ventas_pagos_detalle USING btree (venta_id);

-- ---------------------------------------------------------------------------
-- 6) TRIGGERS (62)
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS cajas_touch ON dymaerp.cajas;
CREATE TRIGGER cajas_touch BEFORE UPDATE ON dymaerp.cajas FOR EACH ROW EXECUTE FUNCTION dymaerp.touch_cajas_updated_at();
DROP TRIGGER IF EXISTS tr_chat_agents_updated ON dymaerp.chat_agents;
CREATE TRIGGER tr_chat_agents_updated BEFORE UPDATE ON dymaerp.chat_agents FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_campaign_jobs_updated ON dymaerp.chat_campaign_jobs;
CREATE TRIGGER tr_chat_campaign_jobs_updated BEFORE UPDATE ON dymaerp.chat_campaign_jobs FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_campaign_recipients_updated ON dymaerp.chat_campaign_recipients;
CREATE TRIGGER tr_chat_campaign_recipients_updated BEFORE UPDATE ON dymaerp.chat_campaign_recipients FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_campaign_templates_updated ON dymaerp.chat_campaign_templates;
CREATE TRIGGER tr_chat_campaign_templates_updated BEFORE UPDATE ON dymaerp.chat_campaign_templates FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_campaigns_updated ON dymaerp.chat_campaigns;
CREATE TRIGGER tr_chat_campaigns_updated BEFORE UPDATE ON dymaerp.chat_campaigns FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_channel_quick_replies_updated ON dymaerp.chat_channel_quick_replies;
CREATE TRIGGER tr_chat_channel_quick_replies_updated BEFORE UPDATE ON dymaerp.chat_channel_quick_replies FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_channels_updated ON dymaerp.chat_channels;
CREATE TRIGGER tr_chat_channels_updated BEFORE UPDATE ON dymaerp.chat_channels FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_comp_val_updated ON dymaerp.chat_comprobante_validaciones;
CREATE TRIGGER tr_chat_comp_val_updated BEFORE UPDATE ON dymaerp.chat_comprobante_validaciones FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_contacts_phone_normalized ON dymaerp.chat_contacts;
CREATE TRIGGER tr_chat_contacts_phone_normalized BEFORE INSERT OR UPDATE OF phone_number ON dymaerp.chat_contacts FOR EACH ROW EXECUTE FUNCTION dymaerp.set_chat_contact_phone_normalized();
DROP TRIGGER IF EXISTS tr_chat_contacts_updated ON dymaerp.chat_contacts;
CREATE TRIGGER tr_chat_contacts_updated BEFORE UPDATE ON dymaerp.chat_contacts FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_conversations_updated ON dymaerp.chat_conversations;
CREATE TRIGGER tr_chat_conversations_updated BEFORE UPDATE ON dymaerp.chat_conversations FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_empresa_operator_roles_updated ON dymaerp.chat_empresa_operator_roles;
CREATE TRIGGER tr_chat_empresa_operator_roles_updated BEFORE UPDATE ON dymaerp.chat_empresa_operator_roles FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_cfr_rules_updated ON dymaerp.chat_flow_recontact_rules;
CREATE TRIGGER tr_cfr_rules_updated BEFORE UPDATE ON dymaerp.chat_flow_recontact_rules FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_flows_updated ON dymaerp.chat_flows;
CREATE TRIGGER tr_chat_flows_updated BEFORE UPDATE ON dymaerp.chat_flows FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_omn_sched_updated ON dymaerp.chat_omnicanal_work_schedules;
CREATE TRIGGER tr_chat_omn_sched_updated BEFORE UPDATE ON dymaerp.chat_omnicanal_work_schedules FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_queues_updated ON dymaerp.chat_queues;
CREATE TRIGGER tr_chat_queues_updated BEFORE UPDATE ON dymaerp.chat_queues FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_chat_usuario_omnicanal_updated ON dymaerp.chat_usuario_omnicanal;
CREATE TRIGGER tr_chat_usuario_omnicanal_updated BEFORE UPDATE ON dymaerp.chat_usuario_omnicanal FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS cliente_perfil_tributario_updated_at ON dymaerp.cliente_perfil_tributario;
CREATE TRIGGER cliente_perfil_tributario_updated_at BEFORE UPDATE ON dymaerp.cliente_perfil_tributario FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS cliente_tipos_servicio_catalogo_updated_at ON dymaerp.cliente_tipos_servicio_catalogo;
CREATE TRIGGER cliente_tipos_servicio_catalogo_updated_at BEFORE UPDATE ON dymaerp.cliente_tipos_servicio_catalogo FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS trg_clientes_tipo_servicio_catalogo ON dymaerp.clientes;
CREATE TRIGGER trg_clientes_tipo_servicio_catalogo BEFORE INSERT OR UPDATE OF tipo_servicio_cliente ON dymaerp.clientes FOR EACH ROW EXECUTE FUNCTION dymaerp.trg_clientes_tipo_servicio_requiere_catalogo();
DROP TRIGGER IF EXISTS tr_comision_equipos_updated ON dymaerp.comision_equipos;
CREATE TRIGGER tr_comision_equipos_updated BEFORE UPDATE ON dymaerp.comision_equipos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_comision_escalas_updated ON dymaerp.comision_escalas;
CREATE TRIGGER tr_comision_escalas_updated BEFORE UPDATE ON dymaerp.comision_escalas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_comision_periodos_updated ON dymaerp.comision_periodos;
CREATE TRIGGER tr_comision_periodos_updated BEFORE UPDATE ON dymaerp.comision_periodos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_comision_politicas_updated ON dymaerp.comision_politicas;
CREATE TRIGGER tr_comision_politicas_updated BEFORE UPDATE ON dymaerp.comision_politicas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS compras_updated_at ON dymaerp.compras;
CREATE TRIGGER compras_updated_at BEFORE UPDATE ON dymaerp.compras FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS crm_etapas_updated_at ON dymaerp.crm_etapas;
CREATE TRIGGER crm_etapas_updated_at BEFORE UPDATE ON dymaerp.crm_etapas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS crm_notas_updated_at ON dymaerp.crm_notas;
CREATE TRIGGER crm_notas_updated_at BEFORE UPDATE ON dymaerp.crm_notas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS crm_prospectos_updated_at ON dymaerp.crm_prospectos;
CREATE TRIGGER crm_prospectos_updated_at BEFORE UPDATE ON dymaerp.crm_prospectos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_crm_prospectos_updated();
DROP TRIGGER IF EXISTS empresa_sifen_config_updated_at ON dymaerp.empresa_sifen_config;
CREATE TRIGGER empresa_sifen_config_updated_at BEFORE UPDATE ON dymaerp.empresa_sifen_config FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS factura_electronica_updated_at ON dymaerp.factura_electronica;
CREATE TRIGGER factura_electronica_updated_at BEFORE UPDATE ON dymaerp.factura_electronica FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS facturas_updated_at ON dymaerp.facturas;
CREATE TRIGGER facturas_updated_at BEFORE UPDATE ON dymaerp.facturas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_marketing_calendarios_updated ON dymaerp.marketing_calendarios;
CREATE TRIGGER tr_marketing_calendarios_updated BEFORE UPDATE ON dymaerp.marketing_calendarios FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_marketing_piezas_updated ON dymaerp.marketing_piezas;
CREATE TRIGGER tr_marketing_piezas_updated BEFORE UPDATE ON dymaerp.marketing_piezas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS marketing_tasks_updated_at ON dymaerp.marketing_tasks;
CREATE TRIGGER marketing_tasks_updated_at BEFORE UPDATE ON dymaerp.marketing_tasks FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS movimientos_updated_at ON dymaerp.movimientos_inventario;
CREATE TRIGGER movimientos_updated_at BEFORE UPDATE ON dymaerp.movimientos_inventario FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS nota_credito_updated_at ON dymaerp.nota_credito;
CREATE TRIGGER nota_credito_updated_at BEFORE UPDATE ON dymaerp.nota_credito FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS nota_credito_electronica_updated_at ON dymaerp.nota_credito_electronica;
CREATE TRIGGER nota_credito_electronica_updated_at BEFORE UPDATE ON dymaerp.nota_credito_electronica FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS pedidos_caja_touch ON dymaerp.pedidos_caja;
CREATE TRIGGER pedidos_caja_touch BEFORE UPDATE ON dymaerp.pedidos_caja FOR EACH ROW EXECUTE FUNCTION dymaerp.touch_pedidos_caja_updated_at();
DROP TRIGGER IF EXISTS planes_updated_at ON dymaerp.planes;
CREATE TRIGGER planes_updated_at BEFORE UPDATE ON dymaerp.planes FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS producto_presentaciones_touch ON dymaerp.producto_presentaciones;
CREATE TRIGGER producto_presentaciones_touch BEFORE UPDATE ON dymaerp.producto_presentaciones FOR EACH ROW EXECUTE FUNCTION dymaerp.touch_producto_presentaciones_updated_at();
DROP TRIGGER IF EXISTS productos_updated_at ON dymaerp.productos;
CREATE TRIGGER productos_updated_at BEFORE UPDATE ON dymaerp.productos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS proveedor_categorias_updated_at ON dymaerp.proveedor_categorias;
CREATE TRIGGER proveedor_categorias_updated_at BEFORE UPDATE ON dymaerp.proveedor_categorias FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS proveedor_productos_updated_at ON dymaerp.proveedor_productos;
CREATE TRIGGER proveedor_productos_updated_at BEFORE UPDATE ON dymaerp.proveedor_productos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS proveedores_updated_at ON dymaerp.proveedores;
CREATE TRIGGER proveedores_updated_at BEFORE UPDATE ON dymaerp.proveedores FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_proyecto_comentarios_updated ON dymaerp.proyecto_comentarios;
CREATE TRIGGER tr_proyecto_comentarios_updated BEFORE UPDATE ON dymaerp.proyecto_comentarios FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_proyecto_estados_updated ON dymaerp.proyecto_estados;
CREATE TRIGGER tr_proyecto_estados_updated BEFORE UPDATE ON dymaerp.proyecto_estados FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_proyecto_prioridades_config_updated ON dymaerp.proyecto_prioridades_config;
CREATE TRIGGER tr_proyecto_prioridades_config_updated BEFORE UPDATE ON dymaerp.proyecto_prioridades_config FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_proyecto_tareas_updated ON dymaerp.proyecto_tareas;
CREATE TRIGGER tr_proyecto_tareas_updated BEFORE UPDATE ON dymaerp.proyecto_tareas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_proyecto_tipos_updated ON dymaerp.proyecto_tipos;
CREATE TRIGGER tr_proyecto_tipos_updated BEFORE UPDATE ON dymaerp.proyecto_tipos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_proyectos_updated ON dymaerp.proyectos;
CREATE TRIGGER tr_proyectos_updated BEFORE UPDATE ON dymaerp.proyectos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS trg_receta_items_updated_at ON dymaerp.receta_items;
CREATE TRIGGER trg_receta_items_updated_at BEFORE UPDATE ON dymaerp.receta_items FOR EACH ROW EXECUTE FUNCTION dymaerp._touch_updated_at();
DROP TRIGGER IF EXISTS trg_recetas_updated_at ON dymaerp.recetas;
CREATE TRIGGER trg_recetas_updated_at BEFORE UPDATE ON dymaerp.recetas FOR EACH ROW EXECUTE FUNCTION dymaerp._touch_updated_at();
DROP TRIGGER IF EXISTS tr_sorteo_conv_updated ON dymaerp.sorteo_conversaciones;
CREATE TRIGGER tr_sorteo_conv_updated BEFORE UPDATE ON dymaerp.sorteo_conversaciones FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_sorteo_ent_updated ON dymaerp.sorteo_entradas;
CREATE TRIGGER tr_sorteo_ent_updated BEFORE UPDATE ON dymaerp.sorteo_entradas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_sorteo_revendedores_updated ON dymaerp.sorteo_revendedores;
CREATE TRIGGER tr_sorteo_revendedores_updated BEFORE UPDATE ON dymaerp.sorteo_revendedores FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_sorteo_ticket_deliveries_updated ON dymaerp.sorteo_ticket_deliveries;
CREATE TRIGGER tr_sorteo_ticket_deliveries_updated BEFORE UPDATE ON dymaerp.sorteo_ticket_deliveries FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_sorteos_updated ON dymaerp.sorteos;
CREATE TRIGGER tr_sorteos_updated BEFORE UPDATE ON dymaerp.sorteos FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tipificaciones_updated_at ON dymaerp.tipificaciones;
CREATE TRIGGER tipificaciones_updated_at BEFORE UPDATE ON dymaerp.tipificaciones FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS tr_usuario_modulos_validar_empresa ON dymaerp.usuario_modulos;
CREATE TRIGGER tr_usuario_modulos_validar_empresa BEFORE INSERT OR UPDATE OF modulo_id, usuario_id ON dymaerp.usuario_modulos FOR EACH ROW EXECUTE FUNCTION dymaerp.trg_usuario_modulos_validar_modulo_empresa();
DROP TRIGGER IF EXISTS ventas_updated_at ON dymaerp.ventas;
CREATE TRIGGER ventas_updated_at BEFORE UPDATE ON dymaerp.ventas FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();
DROP TRIGGER IF EXISTS ventas_items_updated_at ON dymaerp.ventas_items;
CREATE TRIGGER ventas_items_updated_at BEFORE UPDATE ON dymaerp.ventas_items FOR EACH ROW EXECUTE FUNCTION dymaerp.set_updated_at();

-- ---------------------------------------------------------------------------
-- 7) ROW LEVEL SECURITY
-- ---------------------------------------------------------------------------
ALTER TABLE dymaerp.caja_movimientos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cajas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.categorias_productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_campaign_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_campaign_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_campaign_recipients ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_campaign_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_campaigns ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_channel_quick_replies ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_comprobante_validaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_conversation_closures ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_empresa_operator_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_data ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_node_blocks ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_nodes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_recontact_rules ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_recontact_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flow_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_flows ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_omnicanal_work_schedules ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_queue_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_queue_closure_states ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_queue_closure_substates ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_queue_supervisors ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_queues ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_routing_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_supervisor_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.chat_usuario_omnicanal ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cliente_historial ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cliente_obligaciones_tributarias ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cliente_perfil_tributario ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cliente_tipos_servicio_catalogo ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cobros_clientes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_ajustes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_equipo_miembros ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_equipos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_escalas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_lineas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_periodos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_politica_versiones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.comision_politicas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.compras ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.crm_etapas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.crm_notas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.crm_prospectos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.cuentas_por_cobrar ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.dashboard_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.devoluciones_venta ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.devoluciones_venta_cambios ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.devoluciones_venta_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.empresa_autoimpresor_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.empresa_dashboard_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.empresa_facturacion_modo ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.empresa_modulos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.empresa_sifen_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.empresas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.entidades_bancarias ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.factura_autoimpresor ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.factura_correlativos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.factura_electronica ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.factura_electronica_evento ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.factura_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.facturas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.gastos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.imports_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.inventario_stock_ubicacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.inventario_ubicaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.marketing_calendarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.marketing_comentarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.marketing_historial_estados ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.marketing_piezas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.marketing_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.modulos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.movimientos_inventario ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.nota_credito ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.nota_credito_electronica ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.nota_credito_evento ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.notas_remision ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.notas_remision_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.notificaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.obligaciones_tributarias_catalogo ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.omnichannel_routes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.ordenes_compra ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.pagos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.pedidos_caja ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.planes ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.presupuesto_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.presupuestos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.produccion_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.producciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.producto_categorias ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.producto_presentaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.productos_codigo_secuencia ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.productos_stock_ubicacion ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proveedor_categoria_rel ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proveedor_categorias ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proveedor_productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proveedores ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_archivos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_comentarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_estado_historial ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_estados ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_prioridades_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_qa_revisiones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_tareas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyecto_tipos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.proyectos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.receta_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.recetas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.recibos_dinero ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sifen_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteo_conversaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteo_cupones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteo_entradas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteo_revendedor_clicks ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteo_revendedores ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteo_ticket_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.sorteos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.suscripciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.tipificaciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.usuario_dashboard_views ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.usuario_modulos ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.usuarios ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.ventas ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.ventas_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE dymaerp.ventas_pagos_detalle ENABLE ROW LEVEL SECURITY;

-- Policies (518)
CREATE POLICY caja_movimientos_delete ON dymaerp.caja_movimientos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY caja_movimientos_insert ON dymaerp.caja_movimientos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY caja_movimientos_select ON dymaerp.caja_movimientos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY caja_movimientos_update ON dymaerp.caja_movimientos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cajas_delete ON dymaerp.cajas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cajas_insert ON dymaerp.cajas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cajas_select ON dymaerp.cajas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cajas_update ON dymaerp.cajas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY categorias_productos_delete ON dymaerp.categorias_productos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY categorias_productos_insert ON dymaerp.categorias_productos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY categorias_productos_select ON dymaerp.categorias_productos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY categorias_productos_update ON dymaerp.categorias_productos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_agents_delete ON dymaerp.chat_agents AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_agents_insert ON dymaerp.chat_agents AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_agents_select ON dymaerp.chat_agents AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_agents_update ON dymaerp.chat_agents AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_events_delete ON dymaerp.chat_campaign_events AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_events_insert ON dymaerp.chat_campaign_events AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_events_select ON dymaerp.chat_campaign_events AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_events_update ON dymaerp.chat_campaign_events AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_jobs_delete ON dymaerp.chat_campaign_jobs AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_jobs_insert ON dymaerp.chat_campaign_jobs AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_jobs_select ON dymaerp.chat_campaign_jobs AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_jobs_update ON dymaerp.chat_campaign_jobs AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_recipients_delete ON dymaerp.chat_campaign_recipients AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_recipients_insert ON dymaerp.chat_campaign_recipients AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_recipients_select ON dymaerp.chat_campaign_recipients AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_recipients_update ON dymaerp.chat_campaign_recipients AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_templates_delete ON dymaerp.chat_campaign_templates AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_templates_insert ON dymaerp.chat_campaign_templates AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_templates_select ON dymaerp.chat_campaign_templates AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaign_templates_update ON dymaerp.chat_campaign_templates AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaigns_delete ON dymaerp.chat_campaigns AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaigns_insert ON dymaerp.chat_campaigns AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaigns_select ON dymaerp.chat_campaigns AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_campaigns_update ON dymaerp.chat_campaigns AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channel_quick_replies_delete ON dymaerp.chat_channel_quick_replies AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channel_quick_replies_insert ON dymaerp.chat_channel_quick_replies AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channel_quick_replies_select ON dymaerp.chat_channel_quick_replies AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channel_quick_replies_update ON dymaerp.chat_channel_quick_replies AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channels_delete ON dymaerp.chat_channels AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channels_insert ON dymaerp.chat_channels AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channels_select ON dymaerp.chat_channels AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_channels_update ON dymaerp.chat_channels AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_comp_val_delete ON dymaerp.chat_comprobante_validaciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_comp_val_insert ON dymaerp.chat_comprobante_validaciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_comp_val_select ON dymaerp.chat_comprobante_validaciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_comp_val_update ON dymaerp.chat_comprobante_validaciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_contacts_delete ON dymaerp.chat_contacts AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_contacts_insert ON dymaerp.chat_contacts AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_contacts_select ON dymaerp.chat_contacts AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_contacts_update ON dymaerp.chat_contacts AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_conversation_closures_insert ON dymaerp.chat_conversation_closures AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_conversation_closures_select ON dymaerp.chat_conversation_closures AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_conversations_delete ON dymaerp.chat_conversations AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_conversations_insert ON dymaerp.chat_conversations AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_conversations_select ON dymaerp.chat_conversations AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_conversations_update ON dymaerp.chat_conversations AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_empresa_operator_roles_delete ON dymaerp.chat_empresa_operator_roles AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_empresa_operator_roles_insert ON dymaerp.chat_empresa_operator_roles AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_empresa_operator_roles_select ON dymaerp.chat_empresa_operator_roles AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_empresa_operator_roles_update ON dymaerp.chat_empresa_operator_roles AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_data_delete ON dymaerp.chat_flow_data AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_data_insert ON dymaerp.chat_flow_data AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_data_select ON dymaerp.chat_flow_data AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_data_update ON dymaerp.chat_flow_data AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_events_delete ON dymaerp.chat_flow_events AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_events_insert ON dymaerp.chat_flow_events AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_events_select ON dymaerp.chat_flow_events AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_events_update ON dymaerp.chat_flow_events AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_node_blocks_delete_empresa ON dymaerp.chat_flow_node_blocks AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_node_blocks_insert_empresa ON dymaerp.chat_flow_node_blocks AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_node_blocks_select_empresa ON dymaerp.chat_flow_node_blocks AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_node_blocks_update_empresa ON dymaerp.chat_flow_node_blocks AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_nodes_delete ON dymaerp.chat_flow_nodes AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_nodes_insert ON dymaerp.chat_flow_nodes AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_nodes_select ON dymaerp.chat_flow_nodes AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_nodes_update ON dymaerp.chat_flow_nodes AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_options_delete ON dymaerp.chat_flow_options AS PERMISSIVE FOR DELETE TO PUBLIC USING ((EXISTS ( SELECT 1
   FROM dymaerp.chat_flow_nodes n
  WHERE ((n.id = chat_flow_options.node_id) AND dymaerp.puede_acceder_empresa(n.empresa_id)))));
CREATE POLICY chat_flow_options_insert ON dymaerp.chat_flow_options AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((EXISTS ( SELECT 1
   FROM dymaerp.chat_flow_nodes n
  WHERE ((n.id = chat_flow_options.node_id) AND dymaerp.puede_acceder_empresa(n.empresa_id)))));
CREATE POLICY chat_flow_options_select ON dymaerp.chat_flow_options AS PERMISSIVE FOR SELECT TO PUBLIC USING ((EXISTS ( SELECT 1
   FROM dymaerp.chat_flow_nodes n
  WHERE ((n.id = chat_flow_options.node_id) AND dymaerp.puede_acceder_empresa(n.empresa_id)))));
CREATE POLICY chat_flow_options_update ON dymaerp.chat_flow_options AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((EXISTS ( SELECT 1
   FROM dymaerp.chat_flow_nodes n
  WHERE ((n.id = chat_flow_options.node_id) AND dymaerp.puede_acceder_empresa(n.empresa_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM dymaerp.chat_flow_nodes n
  WHERE ((n.id = chat_flow_options.node_id) AND dymaerp.puede_acceder_empresa(n.empresa_id)))));
CREATE POLICY chat_flow_recontact_rules_delete ON dymaerp.chat_flow_recontact_rules AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_rules_insert ON dymaerp.chat_flow_recontact_rules AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_rules_select ON dymaerp.chat_flow_recontact_rules AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_rules_update ON dymaerp.chat_flow_recontact_rules AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_runs_delete ON dymaerp.chat_flow_recontact_runs AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_runs_insert ON dymaerp.chat_flow_recontact_runs AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_runs_select ON dymaerp.chat_flow_recontact_runs AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_recontact_runs_update ON dymaerp.chat_flow_recontact_runs AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_sessions_delete ON dymaerp.chat_flow_sessions AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_sessions_insert ON dymaerp.chat_flow_sessions AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_sessions_select ON dymaerp.chat_flow_sessions AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flow_sessions_update ON dymaerp.chat_flow_sessions AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flows_delete ON dymaerp.chat_flows AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flows_insert ON dymaerp.chat_flows AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flows_select ON dymaerp.chat_flows AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_flows_update ON dymaerp.chat_flows AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_messages_delete ON dymaerp.chat_messages AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_messages_insert ON dymaerp.chat_messages AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_messages_select ON dymaerp.chat_messages AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_messages_update ON dymaerp.chat_messages AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_omn_sched_delete ON dymaerp.chat_omnicanal_work_schedules AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_omn_sched_insert ON dymaerp.chat_omnicanal_work_schedules AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_omn_sched_select ON dymaerp.chat_omnicanal_work_schedules AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_omn_sched_update ON dymaerp.chat_omnicanal_work_schedules AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_channels_delete ON dymaerp.chat_queue_channels AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_channels_insert ON dymaerp.chat_queue_channels AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_channels_select ON dymaerp.chat_queue_channels AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_channels_update ON dymaerp.chat_queue_channels AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_states_delete ON dymaerp.chat_queue_closure_states AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_states_insert ON dymaerp.chat_queue_closure_states AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_states_select ON dymaerp.chat_queue_closure_states AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_states_update ON dymaerp.chat_queue_closure_states AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_substates_delete ON dymaerp.chat_queue_closure_substates AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_substates_insert ON dymaerp.chat_queue_closure_substates AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_substates_select ON dymaerp.chat_queue_closure_substates AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_closure_substates_update ON dymaerp.chat_queue_closure_substates AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_supervisors_delete ON dymaerp.chat_queue_supervisors AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_supervisors_insert ON dymaerp.chat_queue_supervisors AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_supervisors_select ON dymaerp.chat_queue_supervisors AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queue_supervisors_update ON dymaerp.chat_queue_supervisors AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queues_delete ON dymaerp.chat_queues AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queues_insert ON dymaerp.chat_queues AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queues_select ON dymaerp.chat_queues AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_queues_update ON dymaerp.chat_queues AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_routing_events_insert ON dymaerp.chat_routing_events AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_routing_events_select ON dymaerp.chat_routing_events AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_supervisor_agents_delete ON dymaerp.chat_supervisor_agents AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_supervisor_agents_insert ON dymaerp.chat_supervisor_agents AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_supervisor_agents_select ON dymaerp.chat_supervisor_agents AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_supervisor_agents_update ON dymaerp.chat_supervisor_agents AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_usuario_omnicanal_delete ON dymaerp.chat_usuario_omnicanal AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_usuario_omnicanal_insert ON dymaerp.chat_usuario_omnicanal AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_usuario_omnicanal_select ON dymaerp.chat_usuario_omnicanal AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY chat_usuario_omnicanal_update ON dymaerp.chat_usuario_omnicanal AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_historial_insert ON dymaerp.cliente_historial AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_historial_select ON dymaerp.cliente_historial AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_obligaciones_tributarias_delete ON dymaerp.cliente_obligaciones_tributarias AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_obligaciones_tributarias_insert ON dymaerp.cliente_obligaciones_tributarias AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_obligaciones_tributarias_select ON dymaerp.cliente_obligaciones_tributarias AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_obligaciones_tributarias_update ON dymaerp.cliente_obligaciones_tributarias AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_perfil_tributario_delete ON dymaerp.cliente_perfil_tributario AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_perfil_tributario_insert ON dymaerp.cliente_perfil_tributario AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_perfil_tributario_select ON dymaerp.cliente_perfil_tributario AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_perfil_tributario_update ON dymaerp.cliente_perfil_tributario AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_tipos_servicio_catalogo_delete ON dymaerp.cliente_tipos_servicio_catalogo AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_tipos_servicio_catalogo_insert ON dymaerp.cliente_tipos_servicio_catalogo AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_tipos_servicio_catalogo_select ON dymaerp.cliente_tipos_servicio_catalogo AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cliente_tipos_servicio_catalogo_update ON dymaerp.cliente_tipos_servicio_catalogo AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY clientes_delete ON dymaerp.clientes AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY clientes_insert ON dymaerp.clientes AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY clientes_select ON dymaerp.clientes AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY clientes_update ON dymaerp.clientes AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobros_clientes_delete ON dymaerp.cobros_clientes AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobros_clientes_insert ON dymaerp.cobros_clientes AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobros_clientes_select ON dymaerp.cobros_clientes AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cobros_clientes_update ON dymaerp.cobros_clientes AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_ajustes_delete ON dymaerp.comision_ajustes AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_ajustes_insert ON dymaerp.comision_ajustes AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_ajustes_select ON dymaerp.comision_ajustes AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_ajustes_update ON dymaerp.comision_ajustes AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipo_miembros_delete ON dymaerp.comision_equipo_miembros AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipo_miembros_insert ON dymaerp.comision_equipo_miembros AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipo_miembros_select ON dymaerp.comision_equipo_miembros AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipo_miembros_update ON dymaerp.comision_equipo_miembros AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipos_delete ON dymaerp.comision_equipos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipos_insert ON dymaerp.comision_equipos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipos_select ON dymaerp.comision_equipos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_equipos_update ON dymaerp.comision_equipos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_escalas_delete ON dymaerp.comision_escalas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_escalas_insert ON dymaerp.comision_escalas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_escalas_select ON dymaerp.comision_escalas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_escalas_update ON dymaerp.comision_escalas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_lineas_delete ON dymaerp.comision_lineas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_lineas_insert ON dymaerp.comision_lineas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_lineas_select ON dymaerp.comision_lineas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_lineas_update ON dymaerp.comision_lineas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_periodos_delete ON dymaerp.comision_periodos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_periodos_insert ON dymaerp.comision_periodos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_periodos_select ON dymaerp.comision_periodos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_periodos_update ON dymaerp.comision_periodos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politica_versiones_delete ON dymaerp.comision_politica_versiones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politica_versiones_insert ON dymaerp.comision_politica_versiones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politica_versiones_select ON dymaerp.comision_politica_versiones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politica_versiones_update ON dymaerp.comision_politica_versiones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politicas_delete ON dymaerp.comision_politicas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politicas_insert ON dymaerp.comision_politicas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politicas_select ON dymaerp.comision_politicas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY comision_politicas_update ON dymaerp.comision_politicas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY compras_delete ON dymaerp.compras AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY compras_insert ON dymaerp.compras AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY compras_select ON dymaerp.compras AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY compras_update ON dymaerp.compras AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_etapas_delete ON dymaerp.crm_etapas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_etapas_insert ON dymaerp.crm_etapas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_etapas_select ON dymaerp.crm_etapas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_etapas_update ON dymaerp.crm_etapas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_notas_delete ON dymaerp.crm_notas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_notas_insert ON dymaerp.crm_notas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_notas_select ON dymaerp.crm_notas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_notas_update ON dymaerp.crm_notas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_prospectos_delete ON dymaerp.crm_prospectos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_prospectos_insert ON dymaerp.crm_prospectos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_prospectos_select ON dymaerp.crm_prospectos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY crm_prospectos_update ON dymaerp.crm_prospectos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cuentas_por_cobrar_delete ON dymaerp.cuentas_por_cobrar AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cuentas_por_cobrar_insert ON dymaerp.cuentas_por_cobrar AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cuentas_por_cobrar_select ON dymaerp.cuentas_por_cobrar AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY cuentas_por_cobrar_update ON dymaerp.cuentas_por_cobrar AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY dashboard_views_all_super ON dymaerp.dashboard_views AS PERMISSIVE FOR ALL TO PUBLIC USING (dymaerp.es_super_admin()) WITH CHECK (dymaerp.es_super_admin());
CREATE POLICY dashboard_views_select_auth ON dymaerp.dashboard_views AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY devoluciones_venta_delete ON dymaerp.devoluciones_venta AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_insert ON dymaerp.devoluciones_venta AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_select ON dymaerp.devoluciones_venta AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_update ON dymaerp.devoluciones_venta AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_cambios_delete ON dymaerp.devoluciones_venta_cambios AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_cambios_insert ON dymaerp.devoluciones_venta_cambios AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_cambios_select ON dymaerp.devoluciones_venta_cambios AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_cambios_update ON dymaerp.devoluciones_venta_cambios AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_items_delete ON dymaerp.devoluciones_venta_items AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_items_insert ON dymaerp.devoluciones_venta_items AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_items_select ON dymaerp.devoluciones_venta_items AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY devoluciones_venta_items_update ON dymaerp.devoluciones_venta_items AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_autoimpresor_config_delete ON dymaerp.empresa_autoimpresor_config AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_autoimpresor_config_insert ON dymaerp.empresa_autoimpresor_config AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_autoimpresor_config_select ON dymaerp.empresa_autoimpresor_config AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_autoimpresor_config_update ON dymaerp.empresa_autoimpresor_config AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY edv_delete ON dymaerp.empresa_dashboard_views AS PERMISSIVE FOR DELETE TO PUBLIC USING ((dymaerp.es_super_admin() OR dymaerp.puede_acceder_empresa(empresa_id)));
CREATE POLICY edv_mutate ON dymaerp.empresa_dashboard_views AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((dymaerp.es_super_admin() OR dymaerp.puede_acceder_empresa(empresa_id)));
CREATE POLICY edv_select ON dymaerp.empresa_dashboard_views AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY edv_update ON dymaerp.empresa_dashboard_views AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((dymaerp.es_super_admin() OR dymaerp.puede_acceder_empresa(empresa_id))) WITH CHECK ((dymaerp.es_super_admin() OR dymaerp.puede_acceder_empresa(empresa_id)));
CREATE POLICY empresa_facturacion_modo_delete ON dymaerp.empresa_facturacion_modo AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_facturacion_modo_insert ON dymaerp.empresa_facturacion_modo AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_facturacion_modo_select ON dymaerp.empresa_facturacion_modo AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_facturacion_modo_update ON dymaerp.empresa_facturacion_modo AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_modulos_delete ON dymaerp.empresa_modulos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_modulos_insert ON dymaerp.empresa_modulos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_modulos_select ON dymaerp.empresa_modulos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_modulos_update ON dymaerp.empresa_modulos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_sifen_config_delete ON dymaerp.empresa_sifen_config AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_sifen_config_insert ON dymaerp.empresa_sifen_config AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_sifen_config_select ON dymaerp.empresa_sifen_config AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresa_sifen_config_update ON dymaerp.empresa_sifen_config AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY empresas_delete ON dymaerp.empresas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.es_super_admin());
CREATE POLICY empresas_insert ON dymaerp.empresas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.es_super_admin());
CREATE POLICY empresas_select ON dymaerp.empresas AS PERMISSIVE FOR SELECT TO PUBLIC USING ((dymaerp.es_super_admin() OR (id = dymaerp.empresa_id_actual())));
CREATE POLICY empresas_update ON dymaerp.empresas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(id)) WITH CHECK (dymaerp.puede_acceder_empresa(id));
CREATE POLICY entidades_bancarias_delete ON dymaerp.entidades_bancarias AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY entidades_bancarias_insert ON dymaerp.entidades_bancarias AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY entidades_bancarias_select ON dymaerp.entidades_bancarias AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY entidades_bancarias_update ON dymaerp.entidades_bancarias AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_autoimpresor_delete ON dymaerp.factura_autoimpresor AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_autoimpresor_insert ON dymaerp.factura_autoimpresor AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_autoimpresor_select ON dymaerp.factura_autoimpresor AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_autoimpresor_update ON dymaerp.factura_autoimpresor AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_correlativos_delete ON dymaerp.factura_correlativos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_correlativos_insert ON dymaerp.factura_correlativos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_correlativos_select ON dymaerp.factura_correlativos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_correlativos_update ON dymaerp.factura_correlativos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_delete ON dymaerp.factura_electronica AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_insert ON dymaerp.factura_electronica AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_select ON dymaerp.factura_electronica AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_update ON dymaerp.factura_electronica AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_evento_delete ON dymaerp.factura_electronica_evento AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_evento_insert ON dymaerp.factura_electronica_evento AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_evento_select ON dymaerp.factura_electronica_evento AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_electronica_evento_update ON dymaerp.factura_electronica_evento AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_items_delete ON dymaerp.factura_items AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_items_insert ON dymaerp.factura_items AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_items_select ON dymaerp.factura_items AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY factura_items_update ON dymaerp.factura_items AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY facturas_delete ON dymaerp.facturas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY facturas_insert ON dymaerp.facturas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY facturas_select ON dymaerp.facturas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY facturas_update ON dymaerp.facturas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gastos_delete ON dymaerp.gastos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gastos_insert ON dymaerp.gastos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gastos_select ON dymaerp.gastos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY gastos_update ON dymaerp.gastos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY imports_audit_delete ON dymaerp.imports_audit AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY imports_audit_insert ON dymaerp.imports_audit AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY imports_audit_select ON dymaerp.imports_audit AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY imports_audit_update ON dymaerp.imports_audit AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_stock_ubicacion_delete ON dymaerp.inventario_stock_ubicacion AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_stock_ubicacion_insert ON dymaerp.inventario_stock_ubicacion AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_stock_ubicacion_select ON dymaerp.inventario_stock_ubicacion AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_stock_ubicacion_update ON dymaerp.inventario_stock_ubicacion AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_ubicaciones_delete ON dymaerp.inventario_ubicaciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_ubicaciones_insert ON dymaerp.inventario_ubicaciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_ubicaciones_select ON dymaerp.inventario_ubicaciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY inventario_ubicaciones_update ON dymaerp.inventario_ubicaciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_calendarios_delete ON dymaerp.marketing_calendarios AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_calendarios_insert ON dymaerp.marketing_calendarios AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_calendarios_select ON dymaerp.marketing_calendarios AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_calendarios_update ON dymaerp.marketing_calendarios AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_comentarios_delete ON dymaerp.marketing_comentarios AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_comentarios_insert ON dymaerp.marketing_comentarios AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_comentarios_select ON dymaerp.marketing_comentarios AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_comentarios_update ON dymaerp.marketing_comentarios AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_historial_estados_delete ON dymaerp.marketing_historial_estados AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_historial_estados_insert ON dymaerp.marketing_historial_estados AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_historial_estados_select ON dymaerp.marketing_historial_estados AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_historial_estados_update ON dymaerp.marketing_historial_estados AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_piezas_delete ON dymaerp.marketing_piezas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_piezas_insert ON dymaerp.marketing_piezas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_piezas_select ON dymaerp.marketing_piezas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_piezas_update ON dymaerp.marketing_piezas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_tasks_delete ON dymaerp.marketing_tasks AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_tasks_insert ON dymaerp.marketing_tasks AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_tasks_select ON dymaerp.marketing_tasks AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY marketing_tasks_update ON dymaerp.marketing_tasks AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY modulos_delete ON dymaerp.modulos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.es_super_admin());
CREATE POLICY modulos_insert ON dymaerp.modulos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.es_super_admin());
CREATE POLICY modulos_select ON dymaerp.modulos AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY modulos_update ON dymaerp.modulos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.es_super_admin()) WITH CHECK (dymaerp.es_super_admin());
CREATE POLICY movimientos_delete ON dymaerp.movimientos_inventario AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY movimientos_insert ON dymaerp.movimientos_inventario AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY movimientos_select ON dymaerp.movimientos_inventario AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY movimientos_update ON dymaerp.movimientos_inventario AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_delete ON dymaerp.nota_credito AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_insert ON dymaerp.nota_credito AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_select ON dymaerp.nota_credito AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_update ON dymaerp.nota_credito AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_electronica_delete ON dymaerp.nota_credito_electronica AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_electronica_insert ON dymaerp.nota_credito_electronica AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_electronica_select ON dymaerp.nota_credito_electronica AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_electronica_update ON dymaerp.nota_credito_electronica AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_evento_delete ON dymaerp.nota_credito_evento AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_evento_insert ON dymaerp.nota_credito_evento AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_evento_select ON dymaerp.nota_credito_evento AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nota_credito_evento_update ON dymaerp.nota_credito_evento AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nr_all ON dymaerp.notas_remision AS PERMISSIVE FOR ALL TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY nri_all ON dymaerp.notas_remision_items AS PERMISSIVE FOR ALL TO PUBLIC USING ((EXISTS ( SELECT 1
   FROM dymaerp.notas_remision nr
  WHERE ((nr.id = notas_remision_items.nota_remision_id) AND dymaerp.puede_acceder_empresa(nr.empresa_id))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM dymaerp.notas_remision nr
  WHERE ((nr.id = notas_remision_items.nota_remision_id) AND dymaerp.puede_acceder_empresa(nr.empresa_id)))));
CREATE POLICY notificaciones_delete ON dymaerp.notificaciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY notificaciones_insert ON dymaerp.notificaciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY notificaciones_select ON dymaerp.notificaciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY notificaciones_update ON dymaerp.notificaciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY obligaciones_tributarias_catalogo_select ON dymaerp.obligaciones_tributarias_catalogo AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY obligaciones_tributarias_catalogo_select_sr ON dymaerp.obligaciones_tributarias_catalogo AS PERMISSIVE FOR SELECT TO service_role USING (true);
CREATE POLICY omnichannel_routes_delete ON dymaerp.omnichannel_routes AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY omnichannel_routes_insert ON dymaerp.omnichannel_routes AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY omnichannel_routes_select ON dymaerp.omnichannel_routes AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY omnichannel_routes_update ON dymaerp.omnichannel_routes AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ordenes_compra_delete ON dymaerp.ordenes_compra AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ordenes_compra_insert ON dymaerp.ordenes_compra AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ordenes_compra_select ON dymaerp.ordenes_compra AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ordenes_compra_update ON dymaerp.ordenes_compra AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pagos_delete ON dymaerp.pagos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pagos_insert ON dymaerp.pagos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pagos_select ON dymaerp.pagos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pagos_update ON dymaerp.pagos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pedidos_caja_delete ON dymaerp.pedidos_caja AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pedidos_caja_insert ON dymaerp.pedidos_caja AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pedidos_caja_select ON dymaerp.pedidos_caja AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY pedidos_caja_update ON dymaerp.pedidos_caja AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY planes_delete ON dymaerp.planes AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY planes_insert ON dymaerp.planes AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY planes_select ON dymaerp.planes AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY planes_update ON dymaerp.planes AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuesto_items_delete ON dymaerp.presupuesto_items AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuesto_items_insert ON dymaerp.presupuesto_items AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuesto_items_select ON dymaerp.presupuesto_items AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuesto_items_update ON dymaerp.presupuesto_items AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuestos_delete ON dymaerp.presupuestos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuestos_insert ON dymaerp.presupuestos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuestos_select ON dymaerp.presupuestos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY presupuestos_update ON dymaerp.presupuestos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY produccion_items_delete ON dymaerp.produccion_items AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY produccion_items_insert ON dymaerp.produccion_items AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY produccion_items_select ON dymaerp.produccion_items AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY produccion_items_update ON dymaerp.produccion_items AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producciones_delete ON dymaerp.producciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producciones_insert ON dymaerp.producciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producciones_select ON dymaerp.producciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producciones_update ON dymaerp.producciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_categorias_delete ON dymaerp.producto_categorias AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_categorias_insert ON dymaerp.producto_categorias AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_categorias_select ON dymaerp.producto_categorias AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_categorias_update ON dymaerp.producto_categorias AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_presentaciones_delete ON dymaerp.producto_presentaciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_presentaciones_insert ON dymaerp.producto_presentaciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_presentaciones_select ON dymaerp.producto_presentaciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY producto_presentaciones_update ON dymaerp.producto_presentaciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_delete ON dymaerp.productos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_insert ON dymaerp.productos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_select ON dymaerp.productos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_update ON dymaerp.productos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_codigo_secuencia_delete ON dymaerp.productos_codigo_secuencia AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_codigo_secuencia_insert ON dymaerp.productos_codigo_secuencia AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_codigo_secuencia_select ON dymaerp.productos_codigo_secuencia AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY productos_codigo_secuencia_update ON dymaerp.productos_codigo_secuencia AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY psu_all ON dymaerp.productos_stock_ubicacion AS PERMISSIVE FOR ALL TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categoria_rel_delete ON dymaerp.proveedor_categoria_rel AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categoria_rel_insert ON dymaerp.proveedor_categoria_rel AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categoria_rel_select ON dymaerp.proveedor_categoria_rel AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categoria_rel_update ON dymaerp.proveedor_categoria_rel AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categorias_delete ON dymaerp.proveedor_categorias AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categorias_insert ON dymaerp.proveedor_categorias AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categorias_select ON dymaerp.proveedor_categorias AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_categorias_update ON dymaerp.proveedor_categorias AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_productos_delete ON dymaerp.proveedor_productos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_productos_insert ON dymaerp.proveedor_productos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_productos_select ON dymaerp.proveedor_productos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedor_productos_update ON dymaerp.proveedor_productos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedores_delete ON dymaerp.proveedores AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedores_insert ON dymaerp.proveedores AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedores_select ON dymaerp.proveedores AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proveedores_update ON dymaerp.proveedores AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_archivos_delete ON dymaerp.proyecto_archivos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_archivos_insert ON dymaerp.proyecto_archivos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_archivos_select ON dymaerp.proyecto_archivos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_archivos_update ON dymaerp.proyecto_archivos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_comentarios_delete ON dymaerp.proyecto_comentarios AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_comentarios_insert ON dymaerp.proyecto_comentarios AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_comentarios_select ON dymaerp.proyecto_comentarios AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_comentarios_update ON dymaerp.proyecto_comentarios AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estado_historial_delete ON dymaerp.proyecto_estado_historial AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estado_historial_insert ON dymaerp.proyecto_estado_historial AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estado_historial_select ON dymaerp.proyecto_estado_historial AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estado_historial_update ON dymaerp.proyecto_estado_historial AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estados_delete ON dymaerp.proyecto_estados AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estados_insert ON dymaerp.proyecto_estados AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estados_select ON dymaerp.proyecto_estados AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_estados_update ON dymaerp.proyecto_estados AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_prioridades_config_delete ON dymaerp.proyecto_prioridades_config AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_prioridades_config_insert ON dymaerp.proyecto_prioridades_config AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_prioridades_config_select ON dymaerp.proyecto_prioridades_config AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_prioridades_config_update ON dymaerp.proyecto_prioridades_config AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_qa_revisiones_all ON dymaerp.proyecto_qa_revisiones AS PERMISSIVE FOR ALL TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tareas_delete ON dymaerp.proyecto_tareas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tareas_insert ON dymaerp.proyecto_tareas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tareas_select ON dymaerp.proyecto_tareas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tareas_update ON dymaerp.proyecto_tareas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tipos_delete ON dymaerp.proyecto_tipos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tipos_insert ON dymaerp.proyecto_tipos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tipos_select ON dymaerp.proyecto_tipos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyecto_tipos_update ON dymaerp.proyecto_tipos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyectos_delete ON dymaerp.proyectos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyectos_insert ON dymaerp.proyectos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyectos_select ON dymaerp.proyectos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY proyectos_update ON dymaerp.proyectos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY receta_items_delete ON dymaerp.receta_items AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY receta_items_insert ON dymaerp.receta_items AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY receta_items_select ON dymaerp.receta_items AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY receta_items_update ON dymaerp.receta_items AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recetas_delete ON dymaerp.recetas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recetas_insert ON dymaerp.recetas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recetas_select ON dymaerp.recetas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recetas_update ON dymaerp.recetas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recibos_dinero_delete ON dymaerp.recibos_dinero AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recibos_dinero_insert ON dymaerp.recibos_dinero AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recibos_dinero_select ON dymaerp.recibos_dinero AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY recibos_dinero_update ON dymaerp.recibos_dinero AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sifen_jobs_delete ON dymaerp.sifen_jobs AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sifen_jobs_insert ON dymaerp.sifen_jobs AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sifen_jobs_select ON dymaerp.sifen_jobs AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sifen_jobs_update ON dymaerp.sifen_jobs AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_conv_delete ON dymaerp.sorteo_conversaciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_conv_insert ON dymaerp.sorteo_conversaciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_conv_select ON dymaerp.sorteo_conversaciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_conv_update ON dymaerp.sorteo_conversaciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_cup_delete ON dymaerp.sorteo_cupones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_cup_insert ON dymaerp.sorteo_cupones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_cup_select ON dymaerp.sorteo_cupones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_cup_update ON dymaerp.sorteo_cupones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ent_delete ON dymaerp.sorteo_entradas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ent_insert ON dymaerp.sorteo_entradas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ent_select ON dymaerp.sorteo_entradas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ent_update ON dymaerp.sorteo_entradas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_clicks_delete ON dymaerp.sorteo_revendedor_clicks AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_clicks_insert ON dymaerp.sorteo_revendedor_clicks AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_clicks_select ON dymaerp.sorteo_revendedor_clicks AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_clicks_update ON dymaerp.sorteo_revendedor_clicks AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_delete ON dymaerp.sorteo_revendedores AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_insert ON dymaerp.sorteo_revendedores AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_select ON dymaerp.sorteo_revendedores AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_rev_update ON dymaerp.sorteo_revendedores AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ticket_deliveries_delete ON dymaerp.sorteo_ticket_deliveries AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ticket_deliveries_insert ON dymaerp.sorteo_ticket_deliveries AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ticket_deliveries_select ON dymaerp.sorteo_ticket_deliveries AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteo_ticket_deliveries_update ON dymaerp.sorteo_ticket_deliveries AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteos_delete ON dymaerp.sorteos AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteos_insert ON dymaerp.sorteos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteos_select ON dymaerp.sorteos AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY sorteos_update ON dymaerp.sorteos AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY suscripciones_delete ON dymaerp.suscripciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY suscripciones_insert ON dymaerp.suscripciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY suscripciones_select ON dymaerp.suscripciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY suscripciones_update ON dymaerp.suscripciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY tipificaciones_delete ON dymaerp.tipificaciones AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY tipificaciones_insert ON dymaerp.tipificaciones AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY tipificaciones_select ON dymaerp.tipificaciones AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY tipificaciones_update ON dymaerp.tipificaciones AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY udv_delete ON dymaerp.usuario_dashboard_views AS PERMISSIVE FOR DELETE TO PUBLIC USING ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_dashboard_views.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = lower(TRIM(BOTH FROM COALESCE((auth.jwt() ->> 'email'::text), ''::text)))) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text])))))));
CREATE POLICY udv_insert ON dymaerp.usuario_dashboard_views AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_dashboard_views.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = lower(TRIM(BOTH FROM COALESCE((auth.jwt() ->> 'email'::text), ''::text)))) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text])))))));
CREATE POLICY udv_select ON dymaerp.usuario_dashboard_views AS PERMISSIVE FOR SELECT TO PUBLIC USING ((dymaerp.es_super_admin() OR (usuario_id IN ( SELECT usuarios.id
   FROM dymaerp.usuarios
  WHERE (lower(TRIM(BOTH FROM COALESCE(usuarios.email, ''::text))) = lower(TRIM(BOTH FROM COALESCE((auth.jwt() ->> 'email'::text), ''::text))))))));
CREATE POLICY udv_update ON dymaerp.usuario_dashboard_views AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_dashboard_views.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = lower(TRIM(BOTH FROM COALESCE((auth.jwt() ->> 'email'::text), ''::text)))) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text]))))))) WITH CHECK ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_dashboard_views.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = lower(TRIM(BOTH FROM COALESCE((auth.jwt() ->> 'email'::text), ''::text)))) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text])))))));
CREATE POLICY usuario_modulos_delete ON dymaerp.usuario_modulos AS PERMISSIVE FOR DELETE TO PUBLIC USING ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_modulos.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = dymaerp.jwt_email_normalized()) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text])))))));
CREATE POLICY usuario_modulos_insert ON dymaerp.usuario_modulos AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_modulos.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = dymaerp.jwt_email_normalized()) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text])))))));
CREATE POLICY usuario_modulos_select ON dymaerp.usuario_modulos AS PERMISSIVE FOR SELECT TO PUBLIC USING ((dymaerp.es_super_admin() OR (usuario_id IN ( SELECT usuarios.id
   FROM dymaerp.usuarios
  WHERE (lower(TRIM(BOTH FROM COALESCE(usuarios.email, ''::text))) = dymaerp.jwt_email_normalized())))));
CREATE POLICY usuario_modulos_update ON dymaerp.usuario_modulos AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_modulos.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = dymaerp.jwt_email_normalized()) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text]))))))) WITH CHECK ((dymaerp.es_super_admin() OR (EXISTS ( SELECT 1
   FROM (dymaerp.usuarios ua
     JOIN dymaerp.usuarios ut ON ((ut.id = usuario_modulos.usuario_id)))
  WHERE ((lower(TRIM(BOTH FROM COALESCE(ua.email, ''::text))) = dymaerp.jwt_email_normalized()) AND (ua.empresa_id IS NOT NULL) AND (ua.empresa_id = ut.empresa_id) AND (COALESCE(ua.rol, ''::text) = ANY (ARRAY['admin'::text, 'administrador'::text])))))));
CREATE POLICY usuarios_delete ON dymaerp.usuarios AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.es_super_admin());
CREATE POLICY usuarios_insert ON dymaerp.usuarios AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK ((dymaerp.es_super_admin() OR ((empresa_id = dymaerp.empresa_id_actual()) AND (empresa_id IS NOT NULL))));
CREATE POLICY usuarios_select ON dymaerp.usuarios AS PERMISSIVE FOR SELECT TO PUBLIC USING ((dymaerp.es_super_admin() OR (empresa_id = dymaerp.empresa_id_actual()) OR ((empresa_id IS NULL) AND (rol = 'super_admin'::text)) OR (auth_user_id = auth.uid())));
CREATE POLICY usuarios_update ON dymaerp.usuarios AS PERMISSIVE FOR UPDATE TO PUBLIC USING ((dymaerp.es_super_admin() OR (empresa_id = dymaerp.empresa_id_actual()) OR ((empresa_id IS NULL) AND (rol = 'super_admin'::text)))) WITH CHECK ((dymaerp.es_super_admin() OR (empresa_id = dymaerp.empresa_id_actual()) OR ((empresa_id IS NULL) AND (rol = 'super_admin'::text))));
CREATE POLICY ventas_delete ON dymaerp.ventas AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_insert ON dymaerp.ventas AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_select ON dymaerp.ventas AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_update ON dymaerp.ventas AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_items_delete ON dymaerp.ventas_items AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_items_insert ON dymaerp.ventas_items AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_items_select ON dymaerp.ventas_items AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_items_update ON dymaerp.ventas_items AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_pagos_detalle_delete ON dymaerp.ventas_pagos_detalle AS PERMISSIVE FOR DELETE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_pagos_detalle_insert ON dymaerp.ventas_pagos_detalle AS PERMISSIVE FOR INSERT TO PUBLIC WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_pagos_detalle_select ON dymaerp.ventas_pagos_detalle AS PERMISSIVE FOR SELECT TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id));
CREATE POLICY ventas_pagos_detalle_update ON dymaerp.ventas_pagos_detalle AS PERMISSIVE FOR UPDATE TO PUBLIC USING (dymaerp.puede_acceder_empresa(empresa_id)) WITH CHECK (dymaerp.puede_acceder_empresa(empresa_id));

-- ---------------------------------------------------------------------------
-- 8) PERMISOS (copiados de instemaq)
-- ---------------------------------------------------------------------------
GRANT USAGE, CREATE ON SCHEMA dymaerp TO supabase_admin;
GRANT USAGE ON SCHEMA dymaerp TO postgres;
GRANT USAGE ON SCHEMA dymaerp TO anon;
GRANT USAGE ON SCHEMA dymaerp TO authenticated;
GRANT USAGE ON SCHEMA dymaerp TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.caja_movimientos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.caja_movimientos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.caja_movimientos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.caja_movimientos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.caja_movimientos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cajas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cajas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cajas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cajas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cajas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.categorias_productos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.categorias_productos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.categorias_productos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.categorias_productos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.categorias_productos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_agents TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_agents TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_agents TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_agents TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_agents TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_events TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_campaign_events TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_events TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_events TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_events TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_jobs TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_campaign_jobs TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_jobs TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_jobs TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_jobs TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_recipients TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_campaign_recipients TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_recipients TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_recipients TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_recipients TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_templates TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_campaign_templates TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_templates TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_templates TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaign_templates TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaigns TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_campaigns TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaigns TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaigns TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_campaigns TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channel_quick_replies TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_channel_quick_replies TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channel_quick_replies TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channel_quick_replies TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channel_quick_replies TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channels TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_channels TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channels TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channels TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_channels TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_comprobante_validaciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_comprobante_validaciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_comprobante_validaciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_comprobante_validaciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_comprobante_validaciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_contacts TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_contacts TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_contacts TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_contacts TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_contacts TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversation_closures TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_conversation_closures TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversation_closures TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversation_closures TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversation_closures TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversations TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_conversations TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversations TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversations TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_conversations TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_empresa_operator_roles TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_empresa_operator_roles TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_empresa_operator_roles TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_empresa_operator_roles TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_empresa_operator_roles TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_data TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_data TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_data TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_data TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_data TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_events TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_events TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_events TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_events TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_events TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_node_blocks TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_node_blocks TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_node_blocks TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_node_blocks TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_node_blocks TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_nodes TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_nodes TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_nodes TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_nodes TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_nodes TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_options TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_options TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_options TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_options TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_options TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_rules TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_recontact_rules TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_rules TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_rules TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_rules TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_runs TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_recontact_runs TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_runs TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_runs TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_recontact_runs TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_sessions TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flow_sessions TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_sessions TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_sessions TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flow_sessions TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flows TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_flows TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flows TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flows TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_flows TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_messages TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_messages TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_messages TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_messages TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_messages TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_omnicanal_work_schedules TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_omnicanal_work_schedules TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_omnicanal_work_schedules TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_omnicanal_work_schedules TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_omnicanal_work_schedules TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_channels TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_queue_channels TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_channels TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_channels TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_channels TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_states TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_queue_closure_states TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_states TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_states TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_states TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_substates TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_queue_closure_substates TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_substates TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_substates TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_closure_substates TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_supervisors TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_queue_supervisors TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_supervisors TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_supervisors TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queue_supervisors TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queues TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_queues TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queues TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queues TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_queues TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_routing_events TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_routing_events TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_routing_events TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_routing_events TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_routing_events TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_supervisor_agents TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_supervisor_agents TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_supervisor_agents TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_supervisor_agents TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_supervisor_agents TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_usuario_omnicanal TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.chat_usuario_omnicanal TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_usuario_omnicanal TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_usuario_omnicanal TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.chat_usuario_omnicanal TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_historial TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cliente_historial TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_historial TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_historial TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_historial TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_obligaciones_tributarias TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cliente_obligaciones_tributarias TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_obligaciones_tributarias TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_obligaciones_tributarias TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_obligaciones_tributarias TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_perfil_tributario TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cliente_perfil_tributario TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_perfil_tributario TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_perfil_tributario TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_perfil_tributario TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_tipos_servicio_catalogo TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cliente_tipos_servicio_catalogo TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_tipos_servicio_catalogo TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_tipos_servicio_catalogo TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cliente_tipos_servicio_catalogo TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.clientes TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.clientes TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.clientes TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.clientes TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.clientes TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cobros_clientes TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cobros_clientes TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cobros_clientes TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cobros_clientes TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cobros_clientes TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_ajustes TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_ajustes TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_ajustes TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_ajustes TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_ajustes TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipo_miembros TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_equipo_miembros TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipo_miembros TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipo_miembros TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipo_miembros TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_equipos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_equipos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_escalas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_escalas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_escalas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_escalas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_escalas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_lineas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_lineas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_lineas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_lineas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_lineas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_periodos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_periodos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_periodos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_periodos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_periodos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politica_versiones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_politica_versiones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politica_versiones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politica_versiones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politica_versiones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politicas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.comision_politicas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politicas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politicas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.comision_politicas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.compras TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.compras TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.compras TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.compras TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.compras TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_etapas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.crm_etapas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_etapas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_etapas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_etapas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_notas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.crm_notas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_notas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_notas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_notas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_prospectos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.crm_prospectos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_prospectos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_prospectos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.crm_prospectos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cuentas_por_cobrar TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.cuentas_por_cobrar TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cuentas_por_cobrar TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cuentas_por_cobrar TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.cuentas_por_cobrar TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.dashboard_views TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.dashboard_views TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.dashboard_views TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.dashboard_views TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.dashboard_views TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.devoluciones_venta TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_cambios TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.devoluciones_venta_cambios TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_cambios TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_cambios TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_cambios TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.devoluciones_venta_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_items TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.devoluciones_venta_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_autoimpresor_config TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.empresa_autoimpresor_config TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_autoimpresor_config TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_autoimpresor_config TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_autoimpresor_config TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_dashboard_views TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.empresa_dashboard_views TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_dashboard_views TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_dashboard_views TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_dashboard_views TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_facturacion_modo TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.empresa_facturacion_modo TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_facturacion_modo TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_facturacion_modo TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_facturacion_modo TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_modulos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.empresa_modulos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_modulos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_modulos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_modulos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_sifen_config TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.empresa_sifen_config TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_sifen_config TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_sifen_config TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresa_sifen_config TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.empresas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.empresas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.entidades_bancarias TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.entidades_bancarias TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.entidades_bancarias TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.entidades_bancarias TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.entidades_bancarias TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_autoimpresor TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.factura_autoimpresor TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_autoimpresor TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_autoimpresor TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_autoimpresor TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_correlativos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.factura_correlativos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_correlativos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_correlativos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_correlativos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.factura_electronica TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica_evento TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.factura_electronica_evento TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica_evento TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica_evento TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_electronica_evento TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.factura_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_items TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.factura_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.facturas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.facturas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.facturas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.facturas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.facturas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.gastos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.gastos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.gastos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.gastos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.gastos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.imports_audit TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.imports_audit TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.imports_audit TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.imports_audit TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.imports_audit TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_stock_ubicacion TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.inventario_stock_ubicacion TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_stock_ubicacion TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_stock_ubicacion TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_stock_ubicacion TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_ubicaciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.inventario_ubicaciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_ubicaciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_ubicaciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.inventario_ubicaciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_calendarios TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.marketing_calendarios TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_calendarios TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_calendarios TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_calendarios TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_comentarios TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.marketing_comentarios TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_comentarios TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_comentarios TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_comentarios TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_historial_estados TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.marketing_historial_estados TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_historial_estados TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_historial_estados TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_historial_estados TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_piezas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.marketing_piezas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_piezas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_piezas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_piezas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_tasks TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.marketing_tasks TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_tasks TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_tasks TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.marketing_tasks TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.modulos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.modulos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.modulos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.modulos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.modulos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.movimientos_inventario TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.movimientos_inventario TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.movimientos_inventario TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.movimientos_inventario TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.movimientos_inventario TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.nota_credito TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_electronica TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.nota_credito_electronica TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_electronica TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_electronica TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_electronica TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_evento TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.nota_credito_evento TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_evento TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_evento TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.nota_credito_evento TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notas_remision_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notificaciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.notificaciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notificaciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notificaciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.notificaciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.obligaciones_tributarias_catalogo TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.obligaciones_tributarias_catalogo TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.obligaciones_tributarias_catalogo TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.obligaciones_tributarias_catalogo TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.obligaciones_tributarias_catalogo TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.omnichannel_routes TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.omnichannel_routes TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.omnichannel_routes TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.omnichannel_routes TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.omnichannel_routes TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ordenes_compra TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.ordenes_compra TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ordenes_compra TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ordenes_compra TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ordenes_compra TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pagos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.pagos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pagos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pagos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pagos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pedidos_caja TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.pedidos_caja TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pedidos_caja TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pedidos_caja TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.pedidos_caja TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.planes TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.planes TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.planes TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.planes TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.planes TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuesto_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.presupuesto_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuesto_items TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuesto_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuesto_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuestos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.presupuestos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuestos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuestos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.presupuestos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.produccion_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.produccion_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.produccion_items TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.produccion_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.produccion_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.producciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_categorias TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.producto_categorias TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_categorias TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_categorias TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_categorias TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_presentaciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.producto_presentaciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_presentaciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_presentaciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.producto_presentaciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.productos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_codigo_secuencia TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.productos_codigo_secuencia TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_codigo_secuencia TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_codigo_secuencia TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_codigo_secuencia TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_stock_ubicacion TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_stock_ubicacion TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_stock_ubicacion TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.productos_stock_ubicacion TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categoria_rel TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proveedor_categoria_rel TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categoria_rel TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categoria_rel TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categoria_rel TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categorias TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proveedor_categorias TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categorias TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categorias TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_categorias TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_productos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proveedor_productos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_productos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_productos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedor_productos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedores TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proveedores TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedores TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedores TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proveedores TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_archivos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_archivos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_archivos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_archivos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_archivos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_comentarios TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_comentarios TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_comentarios TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_comentarios TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_comentarios TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estado_historial TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_estado_historial TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estado_historial TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estado_historial TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estado_historial TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estados TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_estados TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estados TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estados TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_estados TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_prioridades_config TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_prioridades_config TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_prioridades_config TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_prioridades_config TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_prioridades_config TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_qa_revisiones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_qa_revisiones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_qa_revisiones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_qa_revisiones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tareas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_tareas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tareas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tareas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tareas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tipos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyecto_tipos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tipos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tipos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyecto_tipos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyectos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.proyectos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyectos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyectos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.proyectos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.receta_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.receta_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.receta_items TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.receta_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.receta_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recetas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.recetas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recetas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recetas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recetas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recibos_dinero TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.recibos_dinero TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recibos_dinero TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recibos_dinero TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.recibos_dinero TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sifen_jobs TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sifen_jobs TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sifen_jobs TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sifen_jobs TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sifen_jobs TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_conversaciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteo_conversaciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_conversaciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_conversaciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_conversaciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_cupones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteo_cupones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_cupones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_cupones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_cupones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_entradas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteo_entradas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_entradas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_entradas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_entradas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedor_clicks TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteo_revendedor_clicks TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedor_clicks TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedor_clicks TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedor_clicks TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedores TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteo_revendedores TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedores TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedores TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_revendedores TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_ticket_deliveries TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteo_ticket_deliveries TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_ticket_deliveries TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_ticket_deliveries TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteo_ticket_deliveries TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.sorteos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.sorteos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.suscripciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.suscripciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.suscripciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.suscripciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.suscripciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.tipificaciones TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.tipificaciones TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.tipificaciones TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.tipificaciones TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.tipificaciones TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_dashboard_views TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.usuario_dashboard_views TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_dashboard_views TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_dashboard_views TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_dashboard_views TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_modulos TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.usuario_modulos TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_modulos TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_modulos TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuario_modulos TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuarios TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.usuarios TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuarios TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuarios TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.usuarios TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.ventas TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_items TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.ventas_items TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_items TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_items TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_items TO anon;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_pagos_detalle TO supabase_admin;
GRANT INSERT, SELECT, UPDATE, DELETE ON TABLE dymaerp.ventas_pagos_detalle TO authenticated;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_pagos_detalle TO postgres;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_pagos_detalle TO service_role;
GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE dymaerp.ventas_pagos_detalle TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO postgres;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT INSERT, SELECT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT SELECT, UPDATE, USAGE ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT EXECUTE ON FUNCTIONS TO anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT EXECUTE ON FUNCTIONS TO authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA dymaerp GRANT EXECUTE ON FUNCTIONS TO service_role;

-- 9) COMENTARIOS DE COLUMNAS (120)
COMMENT ON COLUMN dymaerp.caja_movimientos.anulado_at IS 'Cuando se anulo el movimiento. NULL = activo. Anulados NO suman a caja.';
COMMENT ON COLUMN dymaerp.caja_movimientos.anulado_por_id IS 'Usuario que ejecuto la anulacion (auditoria).';
COMMENT ON COLUMN dymaerp.caja_movimientos.anulado_motivo IS 'Texto libre con el motivo de la anulacion.';
COMMENT ON COLUMN dymaerp.caja_movimientos.usuario_email IS 'Email snapshot del usuario que registro (para listados sin JOIN).';
COMMENT ON COLUMN dymaerp.categorias_productos.imagen_url IS 'URL de imagen para mostrar en el carrusel del home publico.';
COMMENT ON COLUMN dymaerp.chat_agents.receives_new_chats IS 'Si false, el agente no entra en asignación automática de chats nuevos';
COMMENT ON COLUMN dymaerp.chat_agents.priority_in_queue IS 'Mayor = preferido al empatar estrategias (Etapa 2 puede usarlo más)';
COMMENT ON COLUMN dymaerp.chat_agents.operational_status_changed_at IS 'Momento del último cambio de operational_status (ready/offline) en esta fila.';
COMMENT ON COLUMN dymaerp.chat_agents.last_heartbeat_at IS 'Último ping desde el inbox del agente (sesión activa en conversaciones).';
COMMENT ON COLUMN dymaerp.chat_agents.operational_status IS 'Call center: ready = puede recibir autoasignación; offline = no recibe chats nuevos.';
COMMENT ON COLUMN dymaerp.chat_channels.type IS 'Canal omnicanal: whatsapp | instagram | facebook | email';
COMMENT ON COLUMN dymaerp.chat_channels.nombre IS 'Etiqueta visible en el ERP';
COMMENT ON COLUMN dymaerp.chat_channels.provider IS 'Proveedor: meta';
COMMENT ON COLUMN dymaerp.chat_channels.provider_channel_id IS 'ID de canal en el proveedor (ej. WABA o mismo phone_number_id)';
COMMENT ON COLUMN dymaerp.chat_channels.activo IS 'Si false, el webhook no enruta mensajes nuevos a este canal';
COMMENT ON COLUMN dymaerp.chat_channels.whatsapp_access_token IS 'Bearer de la app Meta para POST /messages; alternativa a WHATSAPP_TOKEN en Vercel';
COMMENT ON COLUMN dymaerp.chat_channels.connection_mode IS 'whatsapp: official (Meta Cloud API) | coexistence (YCloud) | standard | null';
COMMENT ON COLUMN dymaerp.chat_channels.config_status IS 'active = operativo; incomplete = falta credencial crítica; inactive = deshabilitado a propósito';
COMMENT ON COLUMN dymaerp.chat_comprobante_validaciones.monto_validacion_esperado_gs IS 'Monto esperado (GS) desde chat_flow_data del flow_session_id, si aplica validación.';
COMMENT ON COLUMN dymaerp.chat_comprobante_validaciones.monto_validacion_ocr_gs IS 'Monto interpretado del OCR (GS).';
COMMENT ON COLUMN dymaerp.chat_comprobante_validaciones.monto_validacion_diferencia_gs IS 'abs(esperado - ocr) al momento de validar.';
COMMENT ON COLUMN dymaerp.chat_comprobante_validaciones.monto_validacion_status IS 'omitido_config | omitido_sin_esperado | omitido_sin_ocr | coincide | discrepancia | null si no aplica';
COMMENT ON COLUMN dymaerp.chat_comprobante_validaciones.bank_val_status IS 'omitido_config | omitido_sin_esperado | omitido_sin_ocr_bancario | coincide | discrepancia';
COMMENT ON COLUMN dymaerp.chat_conversations.status IS 'Ciclo operador: open | pending | closed';
COMMENT ON COLUMN dymaerp.chat_conversations.active_flow_session_id IS 'Sesión de flujo activa; lecturas/escrituras de variables usan solo esta fila.';
COMMENT ON COLUMN dymaerp.chat_conversations.first_revendedor_id IS 'Primer revendedor atribuido en la vida de la conversación (no se pisa).';
COMMENT ON COLUMN dymaerp.chat_conversations.assigned_agent_id IS 'Agente responsable (chat_agents.id)';
COMMENT ON COLUMN dymaerp.chat_conversations.queue_id IS 'Cola por la que entró la conversación';
COMMENT ON COLUMN dymaerp.chat_conversations.assignment_wait_code IS 'UX: conversación en espera — manual_queue (cola manual), no_eligible_agent (sin agentes listos). NULL si hay agente o no aplica.';
COMMENT ON COLUMN dymaerp.chat_flow_data.flow_session_id IS 'Run del flujo; único junto con field_name.';
COMMENT ON COLUMN dymaerp.chat_flow_events.flow_session_id IS 'Sesión a la que pertenece el evento; hidratación usa solo la sesión activa.';
COMMENT ON COLUMN dymaerp.chat_flow_nodes.crm_action_type IS 'Preparado para acciones CRM por nodo (ej: create_lead, move_funnel_stage, assign_advisor)';
COMMENT ON COLUMN dymaerp.chat_flow_nodes.crm_action_config IS 'Configuración de acción CRM por nodo';
COMMENT ON COLUMN dymaerp.chat_flow_options.option_payload IS 'Payload opcional de variables a guardar en contexto cuando el cliente elige la opción';
COMMENT ON COLUMN dymaerp.chat_flow_options.group_title IS 'Título del grupo (cuerpo del mensaje interactivo). Vacío = modo legacy sin agrupación.';
COMMENT ON COLUMN dymaerp.chat_flow_options.group_order IS 'Orden del grupo respecto a otros del mismo nodo.';
COMMENT ON COLUMN dymaerp.chat_flow_sessions.referral_source IS 'click_token: canje desde sorteo_revendedor_clicks; inbound_text: parser ref= en mensaje.';
COMMENT ON COLUMN dymaerp.chat_flows.sorteo_id IS 'Si está definido, al recibir comprobante (imagen) en este flow se crea orden en sorteo_entradas + cupones (idempotente).';
COMMENT ON COLUMN dymaerp.chat_flows.sorteo_datos_incompletos_message IS 'Texto al cliente cuando falta nombre/cantidad/opción para crear la orden de sorteo; vacío = default del servidor.';
COMMENT ON COLUMN dymaerp.chat_flows.flow_config IS 'JSON por flujo: close_purchase_only_on_final_confirmation; restart_enabled, restart_node_code, restart_keywords, restart_strong_keywords, restart_when_completed, restart_when_abandoned, do_not_restart_when_human_taken_over.';
COMMENT ON COLUMN dymaerp.chat_queues.channel_type IS 'Si no es NULL, esta cola aplica solo a chat_channels.type igual';
COMMENT ON COLUMN dymaerp.chat_queues.distribution_strategy IS 'round_robin | least_load (default) | manual_pull (sin auto-asignación desde cola)';
COMMENT ON COLUMN dymaerp.chat_usuario_omnicanal.omnicanal_agent_enabled IS 'Si es true, el usuario puede operar como agente (autoasignación, circuito operativo).';
COMMENT ON COLUMN dymaerp.clientes.sifen_receptor_manual IS 'Si true, gDatRec del DE usa sifen_receptor_naturaleza, sifen_ti_ope y campos DE explícitos (sin inferencia legacy).';
COMMENT ON COLUMN dymaerp.crm_prospectos.origen_creacion IS 'Origen del lead: manual, whatsapp, formulario_web, referido, campaña_meta, automatizacion, otro';
COMMENT ON COLUMN dymaerp.crm_prospectos.origen_detalle IS 'Detalle opcional del origen del lead (ej: campaña, referido, utm, etc.)';
COMMENT ON COLUMN dymaerp.crm_prospectos.observaciones IS 'Notas internas comercial (contexto, objeciones, próximos pasos). Las crm_notas siguen siendo el historial por entrada.';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.certificado_password_encrypted IS 'Contraseña del .p12 cifrada en backend (neura:v1:...). Requiere SIFEN_SECRETS_KEY.';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.direccion_fiscal IS 'Domicilio/calle del emisor para XML SIFEN (gEmis.dDirEmi). Distinto de razon_social.';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.timbrado_fecha_inicio_vigencia IS 'Inicio de vigencia del timbrado según resolución DNIT (XML dFeIniT).';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.actividad_economica_codigo IS 'Código de actividad económica principal según catálogo SET (cActEco).';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.actividad_economica_descripcion IS 'Descripción oficial asociada al código (dDesActEco); debe coincidir con la SET.';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.sifen_plazo_cancelacion_horas IS 'Horas desde sifen_aprobado_at durante las cuales el DE puede anularse en ERP (sin pagos).';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.kude_logo_path IS 'Ruta del logo PNG dentro del bucket privado "sifen". Solo afecta KuDE/PDF; no toca XML/firma/SET.';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.kude_color_primario IS 'Color primario KuDE (#RRGGBB) para bordes y acentos del PDF. NULL = default Neura (#0EA5E9).';
COMMENT ON COLUMN dymaerp.empresa_sifen_config.kude_color_primario_fill IS 'Color de fondo suave KuDE (#RRGGBB). NULL = derivado del primario por el renderer.';
COMMENT ON COLUMN dymaerp.empresas.gestion_tributaria_clientes IS 'Si true, la empresa puede usar el bloque opcional de perfil tributario en clientes.';
COMMENT ON COLUMN dymaerp.empresas.ofertas_countdown_end IS 'Fecha/hora de fin del countdown del banner ofertas en el home. NULL = sin countdown.';
COMMENT ON COLUMN dymaerp.factura_electronica.xml_firmado_path IS 'Ruta en bucket sifen del XML con firma XML-DSig. xml_path conserva el borrador sin firma.';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_d_prot_cons_lote IS 'Valor dProtConsLote devuelto por SET al aceptar el lote (código 0300).';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_ultima_respuesta_recibe_lote IS 'Última respuesta parseada de recibe-lote (SOAP): códigos, cuerpo crudo, httpStatus.';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_ultima_respuesta_consulta_lote IS 'Última respuesta parseada de consulta-lote TEST: dCodResLot, dMsgResLot, detalle por CDC (gResProcLote).';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_aprobado_at IS 'Momento en que SET confirmó aprobación (consulta-lote); base del plazo de cancelación.';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_cancelado_at IS 'Anulación lógica del DE en ERP (no borra fila ni documento físico).';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_cancelacion_motivo IS 'Motivo declarado al cancelar en ERP.';
COMMENT ON COLUMN dymaerp.factura_electronica.sifen_regeneracion_seq IS 'Incrementado al regenerar XML desde estado rechazado (nueva semilla dCodSeg / nuevo CDC antes de reenviar a SET).';
COMMENT ON COLUMN dymaerp.gastos.descuenta_caja IS 'Si true y hay caja abierta al crear el gasto, se genera un egreso en caja_movimientos.';
COMMENT ON COLUMN dymaerp.gastos.caja_movimiento_id IS 'FK al caja_movimientos creado. Se usa para revertir al borrar el gasto.';
COMMENT ON COLUMN dymaerp.pedidos_caja.numero IS 'Numero visible PED-XXXXXX. Asignado por backend al crear, unico por empresa.';
COMMENT ON COLUMN dymaerp.pedidos_caja.abierto_por_id IS 'Cajero que abrio el pedido en /ventas/nueva (estado en_caja). NULL si nadie lo abrio aun.';
COMMENT ON COLUMN dymaerp.presupuesto_items.costo_unitario IS 'Costo estimado por unidad, para ver el margen del presupuesto antes de cerrar el trabajo.';
COMMENT ON COLUMN dymaerp.productos.controla_stock IS 'Si false, el producto puede venderse sin validar stock (servicios, tarifas).';
COMMENT ON COLUMN dymaerp.productos.valorizado IS 'Si false, no entra en valuación de inventario (combos, promociones).';
COMMENT ON COLUMN dymaerp.productos.unidad_compra IS 'Unidad usada al comprar (ej. "Bolsa 25kg").';
COMMENT ON COLUMN dymaerp.productos.unidad_receta IS 'Unidad usada en recetas (ej. "g", "ml").';
COMMENT ON COLUMN dymaerp.productos.factor_compra_receta IS 'Factor para convertir 1 unidad de compra a unidades de receta (ej. 25000 g por bolsa).';
COMMENT ON COLUMN dymaerp.productos.tiempo_prep_minutos IS 'Tiempo estimado de preparación en minutos (para Kanban de cocina).';
COMMENT ON COLUMN dymaerp.productos.descripcion IS 'Descripción detallada del producto (visible en Menú y edición).';
COMMENT ON COLUMN dymaerp.productos.destacado IS 'Si true, aparece en la seccion Productos Destacados del sitio publico.';
COMMENT ON COLUMN dymaerp.productos.discount_type IS 'Tipo de descuento promocional: percentage | fixed | NULL (sin oferta).';
COMMENT ON COLUMN dymaerp.productos.discount_value IS 'Valor del descuento (porcentaje 0-100 o monto en Gs.).';
COMMENT ON COLUMN dymaerp.productos.discount_starts_at IS 'Inicio de la ventana de oferta. NULL = sin restriccion.';
COMMENT ON COLUMN dymaerp.productos.discount_ends_at IS 'Fin de la ventana de oferta. NULL = sin restriccion.';
COMMENT ON COLUMN dymaerp.productos.oferta_semana_destacada IS 'Si true, aparece en el banner "Ofertas de la semana" del home publico (max 3).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.numero_orden IS 'Secuencia de compras/inscripciones por sorteo (distinta de numero_cupon).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.idempotency_key IS 'Clave estable (conv + flow + media_id) para evitar duplicar orden/cupones en reintentos.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.promo_nombre IS 'Nombre legible de la promo elegida en el flujo (option_payload), si aplica.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.precio_fuente IS 'lista: monto_total = precio_por_boleto * cantidad; promo: monto explícito del flujo.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.precio_regular_referencia IS 'Referencia opcional (ej. precio de lista) cuando precio_fuente = promo.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.comprobante_validacion_id IS 'Vínculo opcional a la fila de validación OCR/hash del comprobante (WhatsApp).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.codigo_referido_snapshot IS 'Copia del código al confirmar orden (histórico / comisiones).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.observacion_interna IS 'Nota interna ERP (no visible al comprador).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.venta_origen IS 'whatsapp_flow: flujo WhatsApp; erp_manual: carga manual en panel.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.venta_canal IS 'remote: compra remota; local: mostrador/presencial.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.pago_metodo IS 'Medio de pago declarado en venta manual o registro interno.';
COMMENT ON COLUMN dymaerp.sorteo_entradas.cupones_impresos_at IS 'Momento en que se confirmó la impresión física de cupones para urna (una vez por orden).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.cupones_impresos_by IS 'Usuario ERP que confirmó la impresión (usuarios.id si disponible; sin FK obligatoria).';
COMMENT ON COLUMN dymaerp.sorteo_entradas.cupones_impresion_count IS 'Cantidad de cupones (filas sorteo_cupones) considerados en la última confirmación de impresión.';
COMMENT ON COLUMN dymaerp.sorteos.ticket_delivery_mode IS 'text_only | text_and_image | image_only — respuesta al comprador tras confirmar orden.';
COMMENT ON COLUMN dymaerp.sorteos.ticket_image_config IS 'Diseño/caption/visibilidad del ticket PNG (JSON).';
COMMENT ON COLUMN dymaerp.suscripciones.plan_pendiente_id IS 'Plan a aplicar (vigente desde plan_pendiente_vigente_desde).';
COMMENT ON COLUMN dymaerp.suscripciones.precio_pendiente IS 'Precio a aplicar con el plan pendiente.';
COMMENT ON COLUMN dymaerp.suscripciones.moneda_pendiente IS 'Moneda del precio pendiente (GS o USD en aplicación).';
COMMENT ON COLUMN dymaerp.suscripciones.plan_pendiente_vigente_desde IS 'Fecha a partir de la cual aplica el cambio (p. ej. 1° del mes siguiente).';
COMMENT ON COLUMN dymaerp.suscripciones.mes_facturacion IS 'Mes en que se emite una suscripcion de plan anual (12 = diciembre). Las mensuales no lo usan.';
COMMENT ON COLUMN dymaerp.suscripciones.meses_hasta_vencimiento IS 'Meses que se corre el vencimiento hacia adelante. 0 = mismo mes. 3 = emitida en diciembre, vence en marzo.';
COMMENT ON COLUMN dymaerp.usuarios.auth_user_id IS 'UUID de auth.users para actualizar email/estado sin buscar por email';
COMMENT ON COLUMN dymaerp.usuarios.porcentaje_comision IS 'Porcentaje de comisión (0–100)';
COMMENT ON COLUMN dymaerp.usuarios.fecha_ingreso IS 'Fecha de ingreso laboral';
COMMENT ON COLUMN dymaerp.usuarios.tipo_contrato IS 'Tipo de contrato declarado en RR.HH.';
COMMENT ON COLUMN dymaerp.usuarios.salario_base IS 'Salario base en guaraníes';
COMMENT ON COLUMN dymaerp.usuarios.ips IS 'Si cotiza IPS';
COMMENT ON COLUMN dymaerp.usuarios.area IS 'Área funcional del usuario';
COMMENT ON COLUMN dymaerp.ventas.caja_id IS 'FK a cajas. NULL si la venta se hizo sin caja abierta (modo legacy o pre-funcionalidad). El cierre de caja agrupa ventas por este campo, no por fecha calendario.';
COMMENT ON COLUMN dymaerp.ventas_items.presentacion_id IS 'FK historica a producto_presentaciones. NULL = item legacy o sin presentacion (cantidad ES la cantidad base).';
COMMENT ON COLUMN dymaerp.ventas_items.presentacion_nombre IS 'Snapshot del nombre de la presentacion al momento de la venta. NULL para items legacy.';
COMMENT ON COLUMN dymaerp.ventas_items.presentacion_cantidad_base IS 'Snapshot de cuantas unidades base equivale 1 unidad de esta presentacion. NULL para items legacy (asumir 1).';
COMMENT ON COLUMN dymaerp.ventas_items.cantidad_total_base IS 'cantidad * presentacion_cantidad_base. Es lo que efectivamente se descuento de stock_actual. NULL para items legacy.';
COMMENT ON COLUMN dymaerp.ventas_items.es_manual IS 'Línea escrita a mano (servicio/trabajo): no sale del catálogo, no descuenta stock.';
COMMENT ON COLUMN dymaerp.ventas_items.costo_unitario IS 'Costo cargado a mano por unidad (repuestos + mano de obra). NULL en líneas de catálogo: ahí el costo sale de movimientos_inventario.';

COMMIT;
