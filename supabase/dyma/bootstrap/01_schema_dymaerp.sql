-- =============================================================================
-- DYMA ERP — crea el schema `dymaerp` como clon EXACTO de `instemaq`, SIN DATOS
-- =============================================================================
-- Pegar entero en el SQL Editor de Supabase y ejecutar. Tarda unos segundos.
--
-- Lee el catálogo de Postgres de `instemaq` y reproduce en `dymaerp` tablas,
-- constraints, índices, funciones, triggers, RLS + policies, GRANTs y comentarios.
-- Ninguna fila de datos se copia.
--
-- Qué NO toca: `instemaq` se lee, nunca se modifica. No escribe en public, auth
-- ni ningún otro schema. Lo único que se crea vive dentro de `dymaerp`.
--
-- Idempotente: se puede correr de nuevo (usa IF NOT EXISTS y saltea lo que ya está).
--
-- Las FKs que apuntan a `auth.users` se conservan tal cual, porque `auth` es el
-- proveedor de identidad compartido de la instancia Supabase.
-- =============================================================================

DO $clon$
DECLARE
  v_src  text := 'instemaq';
  v_dst  text := 'dymaerp';
  r      record;
  v_sql  text;
  v_cols text;
  v_n    int;

BEGIN
  IF to_regnamespace(v_src) IS NULL THEN
    RAISE EXCEPTION 'No existe el schema origen %', v_src;
  END IF;

  -- En `instemaq` todo pertenece a supabase_admin. Se asume ese rol antes de crear
  -- nada para que el clon quede con el mismo owner y los mismos grantors en la ACL.
  EXECUTE 'SET LOCAL ROLE supabase_admin';

  EXECUTE format('CREATE SCHEMA IF NOT EXISTS %I', v_dst);

  -- ===========================================================================
  -- 0) FUNCIONES — van primero: constraints, índices y policies las invocan.
  --    check_function_bodies=off permite crearlas antes que las tablas.
  -- ===========================================================================
  SET LOCAL check_function_bodies = false;

  v_n := 0;
  FOR r IN
    SELECT regexp_replace(pg_get_functiondef(p.oid), '\m' || v_src || '\M', v_dst, 'g') AS def
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = v_src
    ORDER BY p.proname
  LOOP
    EXECUTE r.def;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'funciones: %', v_n;

  -- ===========================================================================
  -- 1) TABLAS — columnas con tipo, collation, DEFAULT y NOT NULL.
  -- ===========================================================================
  v_n := 0;
  FOR r IN
    SELECT c.oid, c.relname
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src AND c.relkind = 'r'
    ORDER BY c.relname
  LOOP
    SELECT string_agg(
             quote_ident(a.attname)
             || ' ' || regexp_replace(format_type(a.atttypid, a.atttypmod), '\m' || v_src || '\M', v_dst, 'g')
             || CASE WHEN a.attcollation <> 0 AND a.attcollation <> ty.typcollation
                     THEN ' COLLATE ' || quote_ident(cl.collname) ELSE '' END
             || CASE WHEN ad.adbin IS NOT NULL
                     THEN ' DEFAULT ' || regexp_replace(pg_get_expr(ad.adbin, ad.adrelid), '\m' || v_src || '\M', v_dst, 'g')
                     ELSE '' END
             || CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END,
             E',\n  ' ORDER BY a.attnum)
      INTO v_cols
    FROM pg_attribute a
    JOIN pg_type ty ON ty.oid = a.atttypid
    LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    LEFT JOIN pg_collation cl ON cl.oid = a.attcollation
    WHERE a.attrelid = r.oid AND a.attnum > 0 AND NOT a.attisdropped;

    EXECUTE format('CREATE TABLE IF NOT EXISTS %I.%I (%s)', v_dst, r.relname, E'\n  ' || v_cols || E'\n');
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'tablas: %', v_n;

  -- ===========================================================================
  -- 2) CONSTRAINTS — primero PK/UNIQUE/CHECK, después las FK (necesitan que las
  --    tablas referenciadas ya tengan su PK/UNIQUE).
  -- ===========================================================================
  v_n := 0;
  FOR r IN
    SELECT c.relname AS tabla, con.conname,
           regexp_replace(pg_get_constraintdef(con.oid), '\m' || v_src || '\M', v_dst, 'g') AS def
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src AND con.contype IN ('p','u','c','x')
    ORDER BY CASE con.contype WHEN 'p' THEN 1 WHEN 'u' THEN 2 ELSE 3 END, c.relname, con.conname
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint k
      JOIN pg_class c2 ON c2.oid = k.conrelid
      JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
      WHERE n2.nspname = v_dst AND c2.relname = r.tabla AND k.conname = r.conname
    ) THEN
      EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', v_dst, r.tabla, r.conname, r.def);
      v_n := v_n + 1;
    END IF;
  END LOOP;

  FOR r IN
    SELECT c.relname AS tabla, con.conname,
           -- pg_get_constraintdef omite el schema cuando la tabla destino está en
           -- search_path; se fuerza el prefijo salvo si ya viene calificada (auth.users).
           regexp_replace(
             regexp_replace(pg_get_constraintdef(con.oid), 'REFERENCES (?!\w+\.)', 'REFERENCES ' || v_dst || '.'),
             '\m' || v_src || '\M', v_dst, 'g') AS def
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src AND con.contype = 'f'
    ORDER BY c.relname, con.conname
  LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_constraint k
      JOIN pg_class c2 ON c2.oid = k.conrelid
      JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
      WHERE n2.nspname = v_dst AND c2.relname = r.tabla AND k.conname = r.conname
    ) THEN
      EXECUTE format('ALTER TABLE %I.%I ADD CONSTRAINT %I %s', v_dst, r.tabla, r.conname, r.def);
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'constraints: %', v_n;

  -- ===========================================================================
  -- 3) ÍNDICES — solo los que no respaldan un constraint (esos ya se crearon).
  -- ===========================================================================
  v_n := 0;
  FOR r IN
    SELECT regexp_replace(
             regexp_replace(pg_get_indexdef(i.indexrelid), '\m' || v_src || '\M', v_dst, 'g'),
             '^CREATE (UNIQUE )?INDEX ', 'CREATE \1INDEX IF NOT EXISTS ') AS def
    FROM pg_index i
    JOIN pg_class ci ON ci.oid = i.indexrelid
    JOIN pg_class ct ON ct.oid = i.indrelid
    JOIN pg_namespace n ON n.oid = ct.relnamespace
    WHERE n.nspname = v_src
      AND NOT EXISTS (SELECT 1 FROM pg_constraint con WHERE con.conindid = i.indexrelid)
    ORDER BY ct.relname, ci.relname
  LOOP
    EXECUTE r.def;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'indices: %', v_n;

  -- ===========================================================================
  -- 4) TRIGGERS
  -- ===========================================================================
  v_n := 0;
  FOR r IN
    SELECT c.relname AS tabla, t.tgname,
           regexp_replace(pg_get_triggerdef(t.oid), '\m' || v_src || '\M', v_dst, 'g') AS def
    FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src AND NOT t.tgisinternal
    ORDER BY c.relname, t.tgname
  LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I', r.tgname, v_dst, r.tabla);
    EXECUTE r.def;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'triggers: %', v_n;

  -- ===========================================================================
  -- 5) ROW LEVEL SECURITY + POLICIES
  -- ===========================================================================
  FOR r IN
    SELECT c.relname, c.relrowsecurity, c.relforcerowsecurity
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src AND c.relkind = 'r' AND c.relrowsecurity
  LOOP
    EXECUTE format('ALTER TABLE %I.%I ENABLE ROW LEVEL SECURITY', v_dst, r.relname);
    IF r.relforcerowsecurity THEN
      EXECUTE format('ALTER TABLE %I.%I FORCE ROW LEVEL SECURITY', v_dst, r.relname);
    END IF;
  END LOOP;

  v_n := 0;
  FOR r IN
    SELECT c.relname AS tabla, pol.polname, pol.polpermissive,
           CASE pol.polcmd WHEN '*' THEN 'ALL' WHEN 'r' THEN 'SELECT'
                           WHEN 'a' THEN 'INSERT' WHEN 'w' THEN 'UPDATE'
                           ELSE 'DELETE' END AS cmd,
           CASE WHEN pol.polroles = '{0}' THEN 'PUBLIC'
                ELSE (SELECT string_agg(quote_ident(ro.rolname), ', ' ORDER BY ro.rolname)
                        FROM unnest(pol.polroles) rid JOIN pg_roles ro ON ro.oid = rid) END AS roles,
           regexp_replace(pg_get_expr(pol.polqual, pol.polrelid), '\m' || v_src || '\M', v_dst, 'g') AS usando,
           regexp_replace(pg_get_expr(pol.polwithcheck, pol.polrelid), '\m' || v_src || '\M', v_dst, 'g') AS chequeo
    FROM pg_policy pol
    JOIN pg_class c ON c.oid = pol.polrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src
    ORDER BY c.relname, pol.polname
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.polname, v_dst, r.tabla);
    v_sql := format('CREATE POLICY %I ON %I.%I AS %s FOR %s TO %s',
                    r.polname, v_dst, r.tabla,
                    CASE WHEN r.polpermissive THEN 'PERMISSIVE' ELSE 'RESTRICTIVE' END,
                    r.cmd, r.roles);
    IF r.usando  IS NOT NULL THEN v_sql := v_sql || format(' USING (%s)', r.usando); END IF;
    IF r.chequeo IS NOT NULL THEN v_sql := v_sql || format(' WITH CHECK (%s)', r.chequeo); END IF;
    EXECUTE v_sql;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'policies: %', v_n;

  -- ===========================================================================
  -- 6) PERMISOS — se replican los GRANTs del schema y de cada tabla.
  -- ===========================================================================
  v_n := 0;
  FOR r IN
    WITH acl AS (
      SELECT NULL::text AS tabla, unnest(coalesce(n.nspacl, '{}')::text[]) AS item
      FROM pg_namespace n WHERE n.nspname = v_src
      UNION ALL
      SELECT c.relname, unnest(coalesce(c.relacl, '{}')::text[])
      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = v_src AND c.relkind = 'r'
    )
    SELECT a.tabla,
           CASE WHEN split_part(a.item, '=', 1) = '' THEN 'PUBLIC'
                ELSE quote_ident(trim(both '"' from split_part(a.item, '=', 1))) END AS grantee,
           (SELECT string_agg(p.priv, ', ')
              FROM regexp_split_to_table(split_part(split_part(a.item, '=', 2), '/', 1), '') AS ch(c)
              JOIN (VALUES ('r','SELECT'),('w','UPDATE'),('a','INSERT'),('d','DELETE'),
                           ('D','TRUNCATE'),('x','REFERENCES'),('t','TRIGGER'),('X','EXECUTE'),
                           ('U','USAGE'),('C','CREATE'),('c','CONNECT'),('T','TEMPORARY')
                   ) AS p(code, priv) ON p.code = ch.c) AS privs
    FROM acl a
  LOOP
    CONTINUE WHEN r.privs IS NULL;
    IF r.tabla IS NULL THEN
      EXECUTE format('GRANT %s ON SCHEMA %I TO %s', r.privs, v_dst, r.grantee);
    ELSE
      EXECUTE format('GRANT %s ON TABLE %I.%I TO %s', r.privs, v_dst, r.tabla, r.grantee);
    END IF;
    v_n := v_n + 1;
  END LOOP;
  RAISE NOTICE 'grants: %', v_n;

  -- Default privileges del schema (para objetos que se creen después).
  FOR r IN
    SELECT pg_get_userbyid(d.defaclrole) AS rol, d.defaclobjtype AS tipo,
           unnest(d.defaclacl::text[]) AS item
    FROM pg_default_acl d JOIN pg_namespace n ON n.oid = d.defaclnamespace
    WHERE n.nspname = v_src
  LOOP
    v_sql := (SELECT string_agg(p.priv, ', ')
                FROM regexp_split_to_table(split_part(split_part(r.item, '=', 2), '/', 1), '') AS ch(c)
                JOIN (VALUES ('r','SELECT'),('w','UPDATE'),('a','INSERT'),('d','DELETE'),
                             ('D','TRUNCATE'),('x','REFERENCES'),('t','TRIGGER'),('X','EXECUTE'),
                             ('U','USAGE'),('C','CREATE')
                     ) AS p(code, priv) ON p.code = ch.c);
    CONTINUE WHEN v_sql IS NULL;
    EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I GRANT %s ON %s TO %s',
                   r.rol, v_dst, v_sql,
                   CASE r.tipo WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES'
                               WHEN 'f' THEN 'FUNCTIONS' WHEN 'T' THEN 'TYPES' ELSE 'SCHEMAS' END,
                   CASE WHEN split_part(r.item, '=', 1) = '' THEN 'PUBLIC'
                        ELSE quote_ident(trim(both '"' from split_part(r.item, '=', 1))) END);
  END LOOP;

  -- ===========================================================================
  -- 7) COMENTARIOS de tablas y columnas
  -- ===========================================================================
  FOR r IN
    SELECT c.relname AS tabla, NULL::text AS col, d.description
    FROM pg_description d
    JOIN pg_class c ON c.oid = d.objoid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = v_src AND d.objsubid = 0 AND c.relkind = 'r'
    UNION ALL
    SELECT c.relname, a.attname, d.description
    FROM pg_description d
    JOIN pg_class c ON c.oid = d.objoid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = d.objsubid
    WHERE n.nspname = v_src AND d.objsubid > 0
  LOOP
    IF r.col IS NULL THEN
      EXECUTE format('COMMENT ON TABLE %I.%I IS %L', v_dst, r.tabla, r.description);
    ELSE
      EXECUTE format('COMMENT ON COLUMN %I.%I.%I IS %L', v_dst, r.tabla, r.col, r.description);
    END IF;
  END LOOP;

  RAISE NOTICE 'Clon % -> % completado.', v_src, v_dst;
END
$clon$;

-- Verificación: las dos filas deben dar los mismos números.
SELECT n.nspname AS schema,
       count(*) FILTER (WHERE c.relkind = 'r') AS tablas,
       count(*) FILTER (WHERE c.relkind = 'i') AS indices,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace x ON x.oid = p.pronamespace
         WHERE x.nspname = n.nspname) AS funciones,
       (SELECT count(*) FROM pg_policy pl JOIN pg_class cc ON cc.oid = pl.polrelid
          JOIN pg_namespace x ON x.oid = cc.relnamespace WHERE x.nspname = n.nspname) AS policies,
       (SELECT count(*) FROM pg_constraint k JOIN pg_class cc ON cc.oid = k.conrelid
          JOIN pg_namespace x ON x.oid = cc.relnamespace WHERE x.nspname = n.nspname) AS constraints
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname IN ('instemaq', 'dymaerp')
GROUP BY n.nspname ORDER BY 1;
