-- =============================================================================
-- DYMA ERP — usuario administrador de la instancia
-- =============================================================================
-- Ejecutar DESPUÉS de 03_datos_maestros_dyma.sql.
--
-- Usuario: admin@corporaciondyma.com   ·   rol: administrador
--
-- PASO PREVIO (fuera de este script, para no escribir en el schema `auth`):
--   Supabase Studio → Authentication → Users → "Add user"
--     Email:    admin@corporaciondyma.com
--     Password: la que definas
--     Marcar "Auto Confirm User".
--
-- Este script solo INSERTA en `dymaerp.usuarios` y LEE `auth.users` para
-- enlazar el `auth_user_id`. No escribe en auth, public ni ningún otro schema.
--
-- Si todavía no creaste el usuario en Auth, el script igual inserta la fila con
-- `auth_user_id = NULL`: el login funciona igual (el ERP resuelve por email) y
-- podés volver a correrlo después para completar el enlace.
--
-- Idempotente.
-- =============================================================================

DO $$
DECLARE
  v_empresa_id uuid := '06255def-3835-4d37-8f7f-801af8043e8c';
  v_email      text := 'admin@corporaciondyma.com';
  v_auth_id    uuid;
BEGIN
  SELECT u.id INTO v_auth_id FROM auth.users u WHERE lower(u.email) = v_email LIMIT 1;

  INSERT INTO dymaerp.usuarios (id, email, nombre, rol, empresa_id, auth_user_id, activo, estado)
  VALUES (
    'c87bb0c2-658b-40b5-a268-1f5e4baff8fb',
    v_email,
    'Administrador DYMA',
    'administrador',   -- NO super_admin: super_admin vería el catálogo completo
    v_empresa_id,
    v_auth_id,
    true,
    'activo'
  )
  ON CONFLICT (id) DO UPDATE
    SET email        = EXCLUDED.email,
        nombre       = EXCLUDED.nombre,
        rol          = EXCLUDED.rol,
        empresa_id   = EXCLUDED.empresa_id,
        auth_user_id = COALESCE(EXCLUDED.auth_user_id, dymaerp.usuarios.auth_user_id),
        activo       = true,
        estado       = 'activo';

  IF v_auth_id IS NULL THEN
    RAISE NOTICE 'Usuario % creado en dymaerp.usuarios SIN auth_user_id. Creá el usuario en Supabase Auth y volvé a correr este script.', v_email;
  ELSE
    RAISE NOTICE 'Usuario % enlazado a auth.users id=%', v_email, v_auth_id;
  END IF;
END $$;

-- Verificación rápida: debe devolver 1 fila con los 9 módulos.
SELECT u.email,
       u.rol,
       e.nombre_empresa,
       (SELECT count(*) FROM dymaerp.empresa_modulos em
         WHERE em.empresa_id = u.empresa_id AND em.activo) AS modulos_activos,
       u.auth_user_id IS NOT NULL AS enlazado_a_auth
FROM dymaerp.usuarios u
JOIN dymaerp.empresas e ON e.id = u.empresa_id
WHERE u.email = 'admin@corporaciondyma.com';
