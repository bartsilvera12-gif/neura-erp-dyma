-- =============================================================================
-- DYMA ERP — datos maestros de la instancia
-- =============================================================================
-- Ejecutar DESPUÉS de 01_schema_dymaerp.sql y 02_modulos_gerencia_cobranzas.sql.
--
-- Inserta SOLO catálogos estructurales y la empresa propia. No trae ningún dato
-- operativo (clientes, facturas, pagos, productos, conversaciones, usuarios de
-- Instemaq, etc.). Todo dentro de `dymaerp`; no toca public, auth ni otro schema.
--
-- Empresa DYMA (UUID fijo, propio — distinto del de Instemaq):
--     06255def-3835-4d37-8f7f-801af8043e8c
--
-- Idempotente: se puede correr más de una vez.
-- =============================================================================

DO $$
DECLARE
  v_empresa_id uuid := '06255def-3835-4d37-8f7f-801af8043e8c';
  -- Los 10 módulos habilitados para DYMA. `empresa_modulos` es la única fuente de
  -- verdad: con NEURA_INSTANCE_MODE=single_client el gate corre en modo estricto,
  -- así que lo que no esté acá no aparece en el sidebar ni es accesible por URL.
  v_slugs text[] := ARRAY[
    'dashboard',        -- Dashboard
    'gerencia',         -- Gerencia
    'ventas',           -- Ventas
    'gestion-clientes', -- Gestión Clientes
    'clientes',         -- Clientes
    'pagos',            -- Pagos
    'cobranzas',        -- Cobranzas
    'planes',           -- Planes
    'reportes',         -- Reportes
    'limpieza'          -- Limpieza (servicio de limpieza de lote)
  ];
BEGIN
  -- ---------------------------------------------------------------------------
  -- 1) Empresa propia (única empresa operativa del schema dymaerp).
  -- ---------------------------------------------------------------------------
  INSERT INTO dymaerp.empresas (id, nombre_empresa, pais, estado, data_schema, gestion_tributaria_clientes)
  VALUES (v_empresa_id, 'DYMA', 'PARAGUAY', 'activo', 'dymaerp', false)
  ON CONFLICT (id) DO NOTHING;

  -- ---------------------------------------------------------------------------
  -- 2) Catálogo de módulos. Se replica el catálogo heredado y se agregan
  --    `gerencia`, `cobranzas` y `limpieza`, que Instemaq no tenía.
  -- ---------------------------------------------------------------------------
  INSERT INTO dymaerp.modulos (id, nombre, slug, descripcion) VALUES
    ('f497bf2a-d650-460a-b5ab-f72018fed47b','Gastos','gastos',NULL),
    ('de613097-35c8-4b05-be53-bc6bde5d5f0b','Pagos','pagos',NULL),
    ('98d53199-0259-4ade-9dbc-e8f67918305c','Marketing Ops','marketing',NULL),
    ('c0f676ac-d879-48b2-a78a-6db59fabb100','Sorteos','sorteos',NULL),
    ('3cb40f93-1aed-4bcc-a800-a1b4ecabc0fe','Conversaciones','conversaciones',NULL),
    ('7cb297a1-b49b-4ef5-9777-09f4518402a1','Dashboard','dashboard',NULL),
    ('3a1a6701-f6c5-48fd-b599-c6f88bc48374','Ventas','ventas',NULL),
    ('569781c8-7e1d-4ac9-b240-e7bb82a0b83b','Inventario','inventario',NULL),
    ('3b6391bb-e77a-464b-84ea-1f95884cffc3','Clientes','clientes',NULL),
    ('aea02686-46a2-4448-a9b3-fe83b4a03491','Compras','compras',NULL),
    ('1a9717b9-8a8e-42f3-b46b-a9e559543d8b','Usuarios','usuarios',NULL),
    ('96f10ea8-a801-41a6-951f-83b7fcf5a0ab','Configuración','configuracion',NULL),
    ('2f0b9c7b-965b-4c70-8480-53442cdd41fc','Planes','planes',NULL),
    ('63025c6b-8417-4b9a-8f1c-034002279778','Gestión Clientes','gestion-clientes',NULL),
    ('e59cc5a3-5f7c-4a6c-afe2-d7f1a67fe602','CRM Funnel','crm',NULL),
    ('1d917292-2e2e-4c9f-9615-4565b3b51dd9','Notas de crédito','notas_credito',NULL),
    ('4b6bdaf2-1790-424d-bb80-b404235ddd49','Historial omnicanal','historial-omnicanal',NULL),
    ('914f9f31-b968-4de6-907f-2a1281a8d5fc','Conversaciones finalizadas','conversaciones-finalizadas',NULL),
    ('ea66f279-2861-4835-8cec-1228e12f64ff','Monitoreo','monitoreo',NULL),
    ('80b7c821-5b12-4802-a7ed-2dd2c3d972d3','Omnicanal (paquete)','omnicanal',NULL),
    ('d6e12622-7178-4d19-8277-bb974e238faf','Campañas WhatsApp','campanas',NULL),
    ('dc402405-7428-4770-9573-2a45321aaaba','Proyectos','proyectos',NULL),
    ('49abab54-4d2b-40a3-8feb-131e2430e764','Marketing Ops','marketing_ops',NULL),
    ('e09e242b-2975-47d5-a4d5-42398e013641','Comisiones','comisiones',NULL),
    ('19f4f4cd-ee2a-41cf-a8a9-5930e8703fd2','Recetas','recetas','Recetas y costeo de productos'),
    ('e22671a3-2a8d-4478-9916-3b037f87c592','Reportes','reportes','Reportería operativa (estado de cuenta, proveedores)'),
    ('3f4b07ed-668d-4f86-917f-d354329b5fc3','Presupuestos','presupuestos','Presupuestos / cotizaciones comerciales'),
    ('3bcaff06-0785-47fd-bf7a-a3721d421b10','Cobros','cobros','Cuentas por cobrar y cobros de clientes'),
    ('81893fe0-8720-481a-ab33-5ab27d83a087','Recepción','recepcion',NULL),
    ('466e40f7-c3ce-4fc8-9197-8d828569fa34','Recibos','recibos',NULL),
    ('6fde0361-0ca7-4283-a645-579ff3cb9259','Remisión','remision',NULL),
    -- Módulos propios de DYMA (portados desde neura-erp-sistemas-propio).
    ('5f89f940-4cc1-4c8b-a808-538bcf06a6df','Gerencia','gerencia','Tablero gerencial comercial (read-only)'),
    ('db159659-1286-4acd-97ad-f7e8322a66e9','Cobranzas','cobranzas','Seguimiento de cartera y promesas de pago'),
    ('5f444016-01d1-43e0-b626-c11f2eea202c','Limpieza','limpieza','Servicio de limpieza de lote, carga manual por cliente')
  ON CONFLICT (id) DO NOTHING;

  -- ---------------------------------------------------------------------------
  -- 3) Catálogo global de vistas de dashboard.
  -- ---------------------------------------------------------------------------
  INSERT INTO dymaerp.dashboard_views (id, slug, nombre, orden, activo) VALUES
    ('2c64c937-5537-4550-b846-94345fbc8583','comercial','Comercial',10,true),
    ('c53eec08-84a9-4e5e-a656-74b8a2fc8e44','financiero','Financiero',20,true),
    ('87f0e8f7-7bda-4d72-9c51-8e45363fa5ba','inventario','Inventario',30,true),
    ('76e2b19c-2f47-4306-a8ce-da9162910f1f','ventas','Ventas',40,true)
  ON CONFLICT (id) DO NOTHING;

  -- ---------------------------------------------------------------------------
  -- 4) empresa_modulos — deja EXACTAMENTE los 10 módulos pedidos, activos.
  --    Se reemplaza el set completo (mismo comportamiento que el guardado desde
  --    admin/empresas/[id]) para que correr de nuevo no acumule módulos viejos.
  -- ---------------------------------------------------------------------------
  DELETE FROM dymaerp.empresa_modulos WHERE empresa_id = v_empresa_id;

  INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
  SELECT v_empresa_id, m.id, true
  FROM dymaerp.modulos m
  WHERE m.slug = ANY (v_slugs);

  -- ---------------------------------------------------------------------------
  -- 5) empresa_dashboard_views — las 4 vistas del dashboard, activas.
  -- ---------------------------------------------------------------------------
  INSERT INTO dymaerp.empresa_dashboard_views (empresa_id, dashboard_view_id, activo)
  SELECT v_empresa_id, dv.id, true
  FROM dymaerp.dashboard_views dv
  WHERE NOT EXISTS (
    SELECT 1 FROM dymaerp.empresa_dashboard_views edv
    WHERE edv.empresa_id = v_empresa_id AND edv.dashboard_view_id = dv.id
  );

  -- ---------------------------------------------------------------------------
  -- 6) crm_etapas — pipeline por defecto.
  -- ---------------------------------------------------------------------------
  INSERT INTO dymaerp.crm_etapas (empresa_id, codigo, nombre, color, orden, activo)
  SELECT v_empresa_id, x.codigo, x.nombre, x.color, x.orden, true
  FROM (VALUES
    ('LEAD','Lead','gray',1),
    ('CONTACTADO','Contactado','blue',2),
    ('NEGOCIACION','Negociación','amber',3),
    ('GANADO','Ganado','green',4),
    ('PERDIDO','Perdido','red',5)
  ) AS x(codigo, nombre, color, orden)
  WHERE NOT EXISTS (
    SELECT 1 FROM dymaerp.crm_etapas e
    WHERE e.empresa_id = v_empresa_id AND e.codigo = x.codigo
  );

  -- ---------------------------------------------------------------------------
  -- 7) cliente_tipos_servicio_catalogo — tipos de servicio del sistema.
  -- ---------------------------------------------------------------------------
  INSERT INTO dymaerp.cliente_tipos_servicio_catalogo (empresa_id, slug, nombre, activo, orden, es_sistema)
  SELECT v_empresa_id, x.slug, x.nombre, true, x.orden, true
  FROM (VALUES
    ('marketing','Marketing',10),
    ('saas','SaaS',20),
    ('branding','Branding',30),
    ('web','Web',40),
    ('otro','Otro',50)
  ) AS x(slug, nombre, orden)
  WHERE NOT EXISTS (
    SELECT 1 FROM dymaerp.cliente_tipos_servicio_catalogo t
    WHERE t.empresa_id = v_empresa_id AND t.slug = x.slug
  );

  RAISE NOTICE 'DYMA: empresa % con % módulos activos',
    v_empresa_id,
    (SELECT count(*) FROM dymaerp.empresa_modulos WHERE empresa_id = v_empresa_id AND activo);
END $$;
