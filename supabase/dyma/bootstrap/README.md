# Bootstrap DYMA ERP — schema `dymaerp`

Scripts para levantar la base de esta instancia desde cero, en orden. Pegar cada
archivo completo en el **SQL Editor de Supabase** y ejecutar. Cada uno es
idempotente: se puede repetir sin romper nada.

| # | Archivo | Qué hace |
|---|---|---|
| 1 | `01_schema_dymaerp.sql` | Crea el schema `dymaerp` como clon **exacto** del schema `instemaq`: 135 tablas, 630 constraints, 525 índices, 33 funciones, 62 triggers, 518 policies RLS y los mismos GRANTs. **Sin una sola fila de datos.** |
| 2 | `02_modulos_gerencia_cobranzas.sql` | Objetos que Instemaq no tiene y los módulos nuevos necesitan: `plan_categoria`, `cobranza_promesas` y las 6 views `v_*` del tablero Gerencia. |
| 3 | `03_datos_maestros_dyma.sql` | Empresa DYMA, catálogo de módulos (incluye `gerencia` y `cobranzas`), vistas de dashboard, etapas CRM, tipos de servicio y **los 9 módulos habilitados**. |
| 4 | `04_usuario_admin.sql` | Usuario `admin@corporaciondyma.com` con rol `administrador`. Ver el paso previo en Supabase Auth documentado en el propio archivo. |

Después de correrlos, exponer el schema en **Settings → API → Exposed schemas**
agregando `dymaerp` (ese paso es manual, fuera de estos scripts).

## Independencia

- Todo se crea dentro de `dymaerp`. Los scripts no escriben en `public`, `auth`,
  `instemaq` ni ningún otro schema. La única lectura externa es `auth.users` en el
  paso 4, para enlazar el `auth_user_id` del admin.
- Las FKs que en Instemaq apuntan a `auth.users` (9 en total) se conservan igual,
  porque `auth` es el proveedor de identidad compartido de la instancia Supabase.
- La empresa DYMA tiene un UUID propio: `06255def-3835-4d37-8f7f-801af8043e8c`.

## Módulos habilitados

`empresa_modulos` es la única fuente de verdad: con `NEURA_INSTANCE_MODE=single_client`
el gate corre en modo estricto, así que lo que no esté activo ahí no aparece en el
sidebar ni es accesible por URL.

Dashboard · Gerencia · Ventas · Gestión Clientes · Clientes · Pagos · Cobranzas ·
Planes · Reportes

## Sobre `../provision/`

Los archivos de `supabase/dyma/provision/` son el historial de provisión heredado de
Instemaq (renombrado a `dymaerp`). **No hace falta ejecutarlos**: `01_schema_dymaerp.sql`
ya parte del estado final de ese schema, con todo lo que esos scripts aplicaron.
Quedan como referencia de por qué el schema es como es.
