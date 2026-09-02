-- =============================================================================
-- DYMA — selección de módulos habilitados para la empresa
-- =============================================================================
-- Reemplaza el set completo (28, heredado de ferrecolor) por el conjunto pedido
-- para DYMA (ferretería industrial): solo estos módulos quedan activos.
--
-- Replica el comportamiento del guardado de la app (admin/empresas/[id]):
-- DELETE de empresa_modulos + INSERT de los seleccionados con activo=true.
-- Idempotente (siempre deja exactamente estos módulos).
--
-- NOTA: `resolveEffectiveModules` hace fallback a "ERP completo" si NO hay filas
-- activas; por eso siempre debe quedar al menos un módulo activo.
-- =============================================================================

DO $$
DECLARE
  v_empresa_id uuid := '20863e7f-39f3-4bb7-87bf-90fd7e08f396';
  v_slugs text[] := ARRAY[
    'clientes',         -- Clientes
    'cobros',           -- Cobranzas
    'dashboard',        -- Dashboard
    'gastos',           -- Gastos
    'gestion-clientes', -- Gestión Clientes
    'notas_credito',    -- Notas de crédito
    'ventas',           -- Ventas
    'inventario',       -- Inventario (todo lo relacionado a inventario)
    'compras'           -- Compras + Proveedores (entrada de stock)
  ];
BEGIN
  DELETE FROM dymaerp.empresa_modulos WHERE empresa_id = v_empresa_id;

  INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
  SELECT v_empresa_id, m.id, true
  FROM dymaerp.modulos m
  WHERE m.slug = ANY (v_slugs);

  RAISE NOTICE 'empresa_modulos DYMA: % módulos activos',
    (SELECT count(*) FROM dymaerp.empresa_modulos WHERE empresa_id = v_empresa_id AND activo);
END $$;
