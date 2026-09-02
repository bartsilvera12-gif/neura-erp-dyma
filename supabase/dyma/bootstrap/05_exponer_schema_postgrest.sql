-- =============================================================================
-- DYMA ERP — exponer el schema `dymaerp` en PostgREST
-- =============================================================================
-- Ejecutar DESPUÉS de 01..04. Sin esto el ERP no puede leer NADA del schema:
-- toda consulta responde PGRST106 "Invalid schema", `resolveEffectiveModules`
-- devuelve vacío y la app muestra "Módulo no habilitado para esta empresa".
--
-- En este Supabase self-hosted la lista de schemas expuestos NO se maneja desde
-- Studio → Settings → API, sino desde un setting del rol `authenticator`:
--     pgrst.db_schemas
--
-- Este script agrega `dymaerp` al final de esa lista sin tocar los demás schemas,
-- y le avisa a PostgREST que recargue. Idempotente: si ya está, no hace nada.
--
-- OJO: `pgrst.db_schemas` es compartido por todos los tenants de la instancia.
-- Por eso el script nunca reescribe la lista entera: la lee, verifica y agrega.
-- =============================================================================

DO $$
DECLARE
  v_actual text;
BEGIN
  SELECT substr(cfg, length('pgrst.db_schemas=') + 1)
    INTO v_actual
  FROM pg_roles r, unnest(r.rolconfig) AS cfg
  WHERE r.rolname = 'authenticator' AND cfg LIKE 'pgrst.db_schemas=%';

  IF v_actual IS NULL THEN
    RAISE EXCEPTION
      'El rol authenticator no tiene pgrst.db_schemas. Esta instancia configura PostgREST por otro lado (env PGRST_DB_SCHEMAS del contenedor); agregá dymaerp ahí.';
  END IF;

  IF 'dymaerp' = ANY (string_to_array(v_actual, ',')) THEN
    RAISE NOTICE 'dymaerp ya estaba expuesto (% schemas). Nada que hacer.',
      array_length(string_to_array(v_actual, ','), 1);
  ELSE
    EXECUTE format('ALTER ROLE authenticator SET pgrst.db_schemas = %L', v_actual || ',dymaerp');
    RAISE NOTICE 'dymaerp agregado. Ahora son % schemas.',
      array_length(string_to_array(v_actual, ','), 1) + 1;
  END IF;
END $$;

-- PostgREST recarga su configuración y el cache de schema sin reiniciar el contenedor.
NOTIFY pgrst, 'reload config';
NOTIFY pgrst, 'reload schema';

-- Verificación: debe devolver expuesto = true.
SELECT 'dymaerp' = ANY (string_to_array(substr(cfg, length('pgrst.db_schemas=') + 1), ',')) AS expuesto,
       array_length(string_to_array(substr(cfg, length('pgrst.db_schemas=') + 1), ','), 1) AS total_schemas
FROM pg_roles r, unnest(r.rolconfig) AS cfg
WHERE r.rolname = 'authenticator' AND cfg LIKE 'pgrst.db_schemas=%';
