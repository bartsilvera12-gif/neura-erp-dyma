-- =============================================================================
-- DYMA — remisión con destino externo (cliente / dirección)
-- =============================================================================
-- Hasta ahora la nota de remisión solo permitía mover entre depósitos propios
-- (origen y destino eran FK a inventario_ubicaciones, ambos obligatorios).
-- El negocio necesita además remitir mercadería a la dirección de un cliente
-- (p. ej. Ciudad del Este, Km 9) para el traslado, facturando después.
--
-- Cambios:
--   1) `ubicacion_destino_id` pasa a ser opcional (NULL cuando el destino es
--      un cliente / dirección externa).
--   2) Se agrega el destino externo: tipo, cliente y datos de entrega.
--
-- Idempotente. Requiere supabase_admin (las tablas son de ese rol).
-- =============================================================================

ALTER TABLE dymaerp.notas_remision
  ALTER COLUMN ubicacion_destino_id DROP NOT NULL;

ALTER TABLE dymaerp.notas_remision
  ADD COLUMN IF NOT EXISTS destino_tipo      text NOT NULL DEFAULT 'deposito',
  ADD COLUMN IF NOT EXISTS cliente_id        uuid,
  ADD COLUMN IF NOT EXISTS destino_nombre    text,
  ADD COLUMN IF NOT EXISTS destino_direccion text,
  ADD COLUMN IF NOT EXISTS destino_ciudad    text;

-- Solo dos tipos de destino admitidos.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint co
    JOIN pg_class cl ON cl.oid = co.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    WHERE n.nspname = 'dymaerp' AND cl.relname = 'notas_remision'
      AND co.conname = 'notas_remision_destino_tipo_check'
  ) THEN
    ALTER TABLE dymaerp.notas_remision
      ADD CONSTRAINT notas_remision_destino_tipo_check
      CHECK (destino_tipo IN ('deposito', 'cliente'));
  END IF;
END $$;

-- Coherencia: a depósito exige ubicación destino; a cliente exige a quién se envía.
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint co
    JOIN pg_class cl ON cl.oid = co.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    WHERE n.nspname = 'dymaerp' AND cl.relname = 'notas_remision'
      AND co.conname = 'notas_remision_destino_coherente_check'
  ) THEN
    ALTER TABLE dymaerp.notas_remision
      ADD CONSTRAINT notas_remision_destino_coherente_check
      CHECK (
        (destino_tipo = 'deposito' AND ubicacion_destino_id IS NOT NULL)
        OR
        (destino_tipo = 'cliente'  AND (cliente_id IS NOT NULL OR coalesce(destino_nombre, '') <> ''))
      );
  END IF;
END $$;

-- FK opcional al cliente (si se eligió de la cartera).
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint co
    JOIN pg_class cl ON cl.oid = co.conrelid
    JOIN pg_namespace n ON n.oid = cl.relnamespace
    WHERE n.nspname = 'dymaerp' AND cl.relname = 'notas_remision'
      AND co.conname = 'notas_remision_cliente_id_fkey'
  ) THEN
    ALTER TABLE dymaerp.notas_remision
      ADD CONSTRAINT notas_remision_cliente_id_fkey
      FOREIGN KEY (cliente_id) REFERENCES dymaerp.clientes(id);
  END IF;
END $$;
