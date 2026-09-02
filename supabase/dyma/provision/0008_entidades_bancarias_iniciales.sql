-- =============================================================================
-- DYMA — entidades de cobro iniciales
-- =============================================================================
-- Necesarias para cobrar con transferencia / tarjeta: la venta exige elegir una
-- entidad de la lista. Renombrables o ampliables desde el ERP. Idempotente.
-- =============================================================================

INSERT INTO dymaerp.entidades_bancarias (empresa_id, nombre, tipo, activo, orden)
SELECT '20863e7f-39f3-4bb7-87bf-90fd7e08f396', x.nombre, x.tipo, true, x.orden
FROM (VALUES
  ('Caja',            'caja',      10),
  ('Banco Itaú',      'banco',     20),
  ('Banco Continental','banco',    30),
  ('Ueno Bank',       'banco',     40),
  ('POS / Tarjeta',   'tarjeta',   50),
  ('Billetera',       'billetera', 60)
) AS x(nombre, tipo, orden)
WHERE NOT EXISTS (
  SELECT 1 FROM dymaerp.entidades_bancarias e
  WHERE e.empresa_id = '20863e7f-39f3-4bb7-87bf-90fd7e08f396' AND lower(e.nombre) = lower(x.nombre)
);
