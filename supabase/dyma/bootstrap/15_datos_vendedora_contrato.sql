-- =============================================================================
-- DYMA ERP — Datos de LA VENDEDORA en el contrato
-- =============================================================================
-- Ejecutar en cualquier momento después de 11_contratos.sql.
--
-- Completa el domicilio de la empresa y corrige el nombre del representante,
-- que en la semilla del 11 estaba abreviado. Los dos salen impresos en el
-- encabezado del contrato y en el bloque de firmas.
--
-- El domicilio además resuelve la Cláusula Tercera: "los pagos se realizan en
-- las oficinas de LA VENDEDORA, sitas en …", que hasta ahora salía con una
-- línea de puntos para completar a mano.
--
-- Es un UPDATE y no un INSERT: la fila ya existe desde el 11.
-- Idempotente.
-- =============================================================================

BEGIN;

SET LOCAL ROLE supabase_admin;

UPDATE dymaerp.contrato_config
   SET representante_nombre = 'Rody Sebastian Verdún Rios',
       domicilio = 'Calle Monday, Barrio San Juan, Juan Emilio O''Leary - Alto Paraná'
 WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c';

COMMIT;

NOTIFY pgrst, 'reload schema';

-- Verificación: así va a salir el encabezado del contrato.
SELECT razon_social, ruc, representante_nombre, domicilio, ciudad_firma, departamento
FROM dymaerp.contrato_config
WHERE empresa_id = '06255def-3835-4d37-8f7f-801af8043e8c';
