-- =============================================================================
-- DYMA ERP — Se retira el módulo Ventas
-- =============================================================================
-- Ejecutar DESPUÉS de 13_venta_contado.sql.
--
-- El módulo Ventas vende productos de inventario, que en esta instancia no
-- existen: lo que se vende son lotes, y eso ya se hace desde Lotes, al contado
-- o financiado. La pestaña Ventas del dashboard pasó a leer los contratos de
-- lotes, así que el módulo no aporta nada y su pantalla solo confunde.
--
-- Sacarlo del menú en el código no alcanza: sin retirar el permiso, la ruta
-- /ventas sigue siendo accesible escribiéndola a mano.
--
-- No se borra el módulo del catálogo: otras instancias del mismo ERP lo usan.
-- Solo se le retira el acceso a esta empresa. Las ventas de productos que
-- hubiera cargadas quedan intactas en la base.
--
-- Todo vive dentro de `dymaerp`. Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

DELETE FROM dymaerp.empresa_modulos em
USING dymaerp.modulos m
WHERE em.modulo_id = m.id
  AND em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
  AND m.slug = 'ventas';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación: los módulos que le quedan a DYMA.
SELECT m.slug
FROM dymaerp.empresa_modulos em
JOIN dymaerp.modulos m ON m.id = em.modulo_id
WHERE em.empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c'
  AND em.activo = true
ORDER BY m.slug;
