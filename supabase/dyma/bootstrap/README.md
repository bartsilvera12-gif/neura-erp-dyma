# Bootstrap DYMA ERP — schema `dymaerp`

Scripts para levantar la base de esta instancia desde cero, en orden. Pegar cada
archivo completo en el **SQL Editor de Supabase** y ejecutar. Cada uno es
idempotente: se puede repetir sin romper nada.

| # | Archivo | Qué hace |
|---|---|---|
| 1 | `01_schema_dymaerp.sql` | Crea el schema `dymaerp` como clon **exacto** del schema `instemaq`: 135 tablas, 630 constraints, 525 índices, 33 funciones, 62 triggers, 518 policies RLS y los mismos GRANTs. **Sin una sola fila de datos.** |
| 2 | `02_modulos_gerencia_cobranzas.sql` | Objetos que Instemaq no tiene y los módulos nuevos necesitan: `plan_categoria`, `cobranza_promesas` y las 6 views `v_*` del tablero Gerencia. |
| 3 | `03_datos_maestros_dyma.sql` | Empresa DYMA, catálogo de módulos (incluye `gerencia`, `cobranzas` y `limpieza`), vistas de dashboard, etapas CRM, tipos de servicio y **los 10 módulos habilitados**. |
| 4 | `04_usuario_admin.sql` | Usuario `admin@corporaciondyma.com` con rol `administrador`. Ver el paso previo en Supabase Auth documentado en el propio archivo. |
| 5 | `05_exponer_schema_postgrest.sql` | Agrega `dymaerp` a `pgrst.db_schemas` del rol `authenticator` y recarga PostgREST. Sin esto la app no lee nada del schema. |
| 6 | `06_modulo_limpieza.sql` | Módulo Limpieza: tabla `servicios_limpieza` (fecha, importe, cliente, factura asociada) y alta del módulo en el catálogo. |
| 7 | `07_modulo_lotes.sql` | Módulo Lotes (fase 1): jerarquía `loteamientos` → `loteamiento_fracciones` → `loteamiento_manzanas` → `lotes`, con estados y precios. |
| 8 | `08_ventas_y_cuotas.sql` | Venta financiada (fase 2): `lote_ventas` (contrato), `lote_venta_codeudores` y `lote_venta_cuotas` (plan de pago). |

El paso 5 es el que expone el schema en PostgREST; en este Supabase self-hosted eso
no se maneja desde Studio sino desde el setting `pgrst.db_schemas` del rol `authenticator`.

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
Planes · Limpieza · Lotes · Reportes

### Limpieza

Servicio que se presta sobre el lote de un cliente, típicamente terrenos sin construcción
todavía. No se genera solo ni por calendario: lo carga el usuario a mano el día que el
servicio se hizo, eligiendo cliente, fecha e importe. Cada alta emite una factura, así el
importe entra por sí solo a Cobranzas, Pagos, Estado de cuenta y Gerencia.

Anular un servicio borra su factura solo si todavía no tiene cobros; si ya los tiene, la
corrección va por el circuito de Facturas (anulación o nota de crédito).

### Lotes

Jerarquía del emprendimiento inmobiliario: **loteamiento → fracción → manzana → lote**.
El nivel superior se llama `loteamientos` y no `proyectos` porque en este schema
`proyectos` ya existe y es otra cosa (gestión de tareas y entregas).

El lote guarda dimensiones, linderos, precio de contado y precio financiado, y un
estado: **disponible · reservado · vendido · bloqueado**. La base obliga a que un lote
reservado o vendido tenga titular, y que uno disponible no lo tenga. Por esa misma regla
la FK a `clientes` es `ON DELETE RESTRICT`: no se puede borrar de verdad a un cliente con
lotes asignados (la baja lógica del ERP sigue funcionando igual).

Solo se puede eliminar un lote disponible, y solo se puede eliminar una manzana, fracción
o loteamiento si no cuelga de ellos ningún lote reservado, vendido o bloqueado.

### Financiamiento de lotes

Reglas definidas por el cliente, congeladas en cada contrato para que un cambio
de política no altere lo ya firmado:

- Recargo del **15%** sobre el capital (contado − entrega inicial), repartido en
  cuotas iguales. No se aplica sobre el precio de lista: lo que se paga al contado
  el primer día no se está financiando.
- Mora del **5% diario acumulativo** sobre el saldo impago de la cuota, desglosada
  en 1,7% de gastos administrativos y 3,3% moratorios.
- **5 días de gracia**: la mora corre desde el sexto día de atraso.

La tasa de mora es alta a propósito —a 20 días de atraso la mora iguala a la
cuota— y fue confirmada explícitamente por el cliente.

Al cobrar una cuota se emite su propia factura, así el cobro entra solo a
Cobranzas, Pagos y Estado de cuenta. La mora se cobra aparte y no reduce el
saldo de capital.

## Sobre `../provision/`

Los archivos de `supabase/dyma/provision/` son el historial de provisión heredado de
Instemaq (renombrado a `dymaerp`). **No hace falta ejecutarlos**: `01_schema_dymaerp.sql`
ya parte del estado final de ese schema, con todo lo que esos scripts aplicaron.
Quedan como referencia de por qué el schema es como es.
