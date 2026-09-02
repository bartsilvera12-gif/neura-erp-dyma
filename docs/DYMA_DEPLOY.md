# DYMA — Instancia dedicada monocliente

Guía de despliegue y provisión de la instancia **DYMA**. Sin secretos.

- **Cliente:** DYMA
- **Modo:** `single_client` (instancia dedicada, un repo + un deploy + un schema)
- **Schema Postgres:** `dymaerp`
- **Schema fuente clonado:** `ferrecolor`
- **empresa_id (UUID propio):** `20863e7f-39f3-4bb7-87bf-90fd7e08f396`

## 1. Variables de entorno (Coolify) — completar los secretos en el panel

```env
NEXT_PUBLIC_SUPABASE_URL=https://api.neura.com.py
NEXT_PUBLIC_SUPABASE_ANON_KEY=        # secreto — panel Coolify
SUPABASE_SERVICE_ROLE_KEY=            # secreto — panel Coolify
SUPABASE_DB_URL=                      # secreto — panel Coolify (postgresql://...)
NEURA_CLIENT_SCHEMA=dymaerp
NEXT_PUBLIC_NEURA_CLIENT_SCHEMA=dymaerp
NEURA_INSTANCE_MODE=single_client
NEURA_CLIENT_NAME=DYMA
NODE_ENV=production
```

`NEXT_PUBLIC_NEURA_CLIENT_SCHEMA` es obligatoria: se inyecta en el bundle del navegador
durante el build y evita que el cliente use el fallback de schema. Debe estar presente
en el entorno de **build** de Coolify, no solo en runtime.

## 2. Provisión de base de datos (ya aplicada)

El schema `dymaerp` se creó clonando **la estructura** (sin datos) de `ferrecolor`:

```sql
SELECT public.neura_clone_schema_full('ferrecolor', 'dymaerp', false);
```

Datos maestros mínimos y empresa propia (idempotente):

```
supabase/dymaerp/provision/0001_provision_dymaerp_master_data.sql
```

Corrección de referencias heredadas en funciones de acceso (requiere conexión con
rol propietario `supabase_admin` / superusuario — ver §5):

```
supabase/dymaerp/provision/0002_retarget_access_functions.sql
```

Aplicar un `.sql` con el helper del repo:

```bash
node scripts/apply-migration-file-pg.cjs supabase/dymaerp/provision/0001_provision_dymaerp_master_data.sql
```

## 3. Exposición en PostgREST (ya aplicada)

`dymaerp` fue añadido (append-only) a `authenticator.pgrst.db_schemas` y se envió
`NOTIFY pgrst, 'reload config'` + `'reload schema'`. Equivalente al procedimiento oficial:

```bash
cd /root/supabase/docker
./exponer-schema.sh dymaerp
```

Verificación contra la API (requiere el anon key real):

```bash
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "apikey: $NEXT_PUBLIC_SUPABASE_ANON_KEY" \
  -H "Accept-Profile: dymaerp" \
  "https://api.neura.com.py/rest/v1/"
# esperado: 200

# tabla real del schema:
curl -s -o /dev/null -w "%{http_code}\n" \
  -H "apikey: $NEXT_PUBLIC_SUPABASE_ANON_KEY" \
  -H "Accept-Profile: dymaerp" \
  "https://api.neura.com.py/rest/v1/empresas?select=id,nombre_empresa&limit=1"
```

## 4. Usuario administrador (paso manual pendiente)

No se copian usuarios. Para vincular un administrador, crear el usuario en Supabase Auth
y luego insertar su fila de catálogo en `dymaerp.usuarios` con su `auth_user_id` real.
NO inventar `auth_user_id`.

```sql
-- Reemplazar <AUTH_USER_ID> por el UUID real de auth.users y <email> por el correo.
INSERT INTO dymaerp.usuarios (id, email, nombre, rol, empresa_id, auth_user_id, activo)
VALUES (
  gen_random_uuid(),
  '<email>',
  'Administrador',
  'super_admin',
  '20863e7f-39f3-4bb7-87bf-90fd7e08f396',
  '<AUTH_USER_ID>',
  true
);
```

Las funciones RLS (`empresa_id_actual()`, `es_super_admin()`) resuelven contra
`dymaerp.usuarios` por el email del JWT; hasta que exista al menos un usuario, el acceso
autenticado queda denegado por RLS (comportamiento esperado en una instancia recién creada).

## 5. Paso pendiente con credenciales elevadas

`supabase/dymaerp/provision/0002_retarget_access_functions.sql` re-apunta el
`search_path` de las funciones de acceso a `dymaerp` y elimina un guard heredado
específico de otro tenant. Esas funciones pertenecen al rol `supabase_admin`, por lo
que **no** pudieron alterarse con el rol `postgres` (no superusuario). Aplicar con una
conexión `supabase_admin`/superusuario. No afecta el aislamiento: los cuerpos de esas
funciones ya referencian `dymaerp.*` de forma calificada (el `search_path` heredado es inerte).
