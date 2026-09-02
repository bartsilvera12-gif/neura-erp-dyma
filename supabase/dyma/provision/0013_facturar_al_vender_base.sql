-- =============================================================================
-- DYMA — base para "facturar al confirmar la venta" (SIFEN)
-- =============================================================================
-- Fase 0 (NO activa la facturación automática): solo agrega la infraestructura
-- de datos. El modo de facturación sigue en 'sin_factura_fiscal' hasta que se
-- valide el circuito en ambiente TEST y se active explícitamente (0014).
--
-- Cambios:
--   ventas.factura_id                 → enlace venta → factura emitida (idempotencia).
--   clientes.sifen_receptor_innominado→ marca el cliente "Consumidor Final" para
--                                       emitir DE innominado (venta de mostrador).
--   seed cliente "Consumidor Final"   → receptor por defecto de ventas sin cliente.
--
-- Idempotente. Requiere supabase_admin (las tablas son de ese rol).
-- =============================================================================

-- M1 — enlace venta → factura
ALTER TABLE dymaerp.ventas
  ADD COLUMN IF NOT EXISTS factura_id uuid NULL;

CREATE INDEX IF NOT EXISTS ventas_factura_id_idx
  ON dymaerp.ventas (factura_id);

-- M2 — flag innominado en clientes
ALTER TABLE dymaerp.clientes
  ADD COLUMN IF NOT EXISTS sifen_receptor_innominado boolean NOT NULL DEFAULT false;

-- M3 — cliente "Consumidor Final" (receptor innominado por defecto)
-- Un solo registro por empresa. La venta sin cliente se factura contra este.
INSERT INTO dymaerp.clientes (empresa_id, empresa, nombre_contacto, sifen_receptor_innominado)
SELECT '20863e7f-39f3-4bb7-87bf-90fd7e08f396'::uuid, 'Consumidor Final', 'Consumidor Final', true
WHERE NOT EXISTS (
  SELECT 1 FROM dymaerp.clientes
  WHERE empresa_id = '20863e7f-39f3-4bb7-87bf-90fd7e08f396'::uuid
    AND sifen_receptor_innominado = true
);
