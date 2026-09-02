-- =============================================================================
-- DYMA — módulo Recibos de dinero
-- =============================================================================
-- Solo DML (catálogo). La tabla `recibos_dinero` ya existe en el schema.
-- Idempotente.
-- =============================================================================

INSERT INTO dymaerp.modulos (id, nombre, slug, descripcion)
SELECT gen_random_uuid(), 'Recibos', 'recibos', 'Recibos de dinero (comprobante interno no fiscal)'
WHERE NOT EXISTS (SELECT 1 FROM dymaerp.modulos WHERE slug = 'recibos');

INSERT INTO dymaerp.empresa_modulos (empresa_id, modulo_id, activo)
SELECT '20863e7f-39f3-4bb7-87bf-90fd7e08f396', m.id, true
FROM dymaerp.modulos m
WHERE m.slug = 'recibos'
  AND NOT EXISTS (
    SELECT 1 FROM dymaerp.empresa_modulos em
    WHERE em.empresa_id = '20863e7f-39f3-4bb7-87bf-90fd7e08f396' AND em.modulo_id = m.id
  );
