-- =============================================================================
-- DYMA ERP — El dashboard muestra Lotes en vez de Inventario
-- =============================================================================
-- Ejecutar DESPUÉS de 11_contratos.sql.
--
-- El negocio de DYMA es loteamiento, no depósito: la pestaña Inventario del
-- dashboard mostraba siempre cero productos y cero stock. Se reemplaza por una
-- vista de Lotes, con el estado del loteamiento y cómo viene la cobranza.
--
-- Las pestañas del dashboard salen de `dashboard_views` cruzado con
-- `empresa_dashboard_views`, así que no alcanza con tocar el código: hay que
-- dar de alta la vista nueva y sacarle el permiso a la vieja.
--
-- No se borra la vista Inventario del catálogo: otras instancias del mismo ERP
-- la usan. Solo se le retira el acceso a esta empresa.
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

-- ---------------------------------------------------------------------------
-- 1) La vista Lotes en el catálogo
-- ---------------------------------------------------------------------------
-- Orden 15: queda antes de Financiero (20) y de Ventas (40), que es lo primero
-- que mira el dueño del loteamiento.
INSERT INTO dymaerp.dashboard_views (nombre, slug, orden, activo)
SELECT 'Lotes', 'lotes', 15, true
WHERE NOT EXISTS (SELECT 1 FROM dymaerp.dashboard_views WHERE slug = 'lotes');

UPDATE dymaerp.dashboard_views
   SET nombre = 'Lotes', orden = 15, activo = true
 WHERE slug = 'lotes';

-- ---------------------------------------------------------------------------
-- 2) DYMA ve Lotes y deja de ver Inventario
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_empresa uuid := '06255def-3835-4d37-8f7f-801af8043e8c';
  v_lotes uuid;
  v_inventario uuid;
BEGIN
  SELECT id INTO v_lotes FROM dymaerp.dashboard_views WHERE slug = 'lotes';
  SELECT id INTO v_inventario FROM dymaerp.dashboard_views WHERE slug = 'inventario';

  IF v_lotes IS NOT NULL THEN
    IF EXISTS (
      SELECT 1 FROM dymaerp.empresa_dashboard_views
      WHERE empresa_id = v_empresa AND dashboard_view_id = v_lotes
    ) THEN
      UPDATE dymaerp.empresa_dashboard_views
         SET activo = true
       WHERE empresa_id = v_empresa AND dashboard_view_id = v_lotes;
    ELSE
      INSERT INTO dymaerp.empresa_dashboard_views (empresa_id, dashboard_view_id, activo)
      VALUES (v_empresa, v_lotes, true);
    END IF;
  END IF;

  -- Se retira el permiso, no la vista: el catálogo lo comparten otras instancias.
  IF v_inventario IS NOT NULL THEN
    DELETE FROM dymaerp.empresa_dashboard_views
     WHERE empresa_id = v_empresa AND dashboard_view_id = v_inventario;
  END IF;
END $$;

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación: las vistas que ve DYMA, en orden.
SELECT v.slug, v.nombre, v.orden
FROM dymaerp.empresa_dashboard_views e
JOIN dymaerp.dashboard_views v ON v.id = e.dashboard_view_id
WHERE e.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
  AND e.activo = true
ORDER BY v.orden;
