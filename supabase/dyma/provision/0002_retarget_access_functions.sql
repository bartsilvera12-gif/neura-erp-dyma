-- =============================================================================
-- DYMA — corrección de referencias heredadas a `enlodemari` en funciones
-- =============================================================================
-- El schema dymaerp se clonó desde ferrecolor, que a su vez arrastra en su linaje
-- funciones con `SET search_path TO 'enlodemari'`. En las funciones de control de
-- acceso (RLS) el cuerpo YA referencia `dymaerp.*` de forma calificada, por lo que
-- ese search_path era inerte; aun así se retarget-ea a `dymaerp` para dejar las
-- funciones de acceso apuntando explícitamente al schema propio.
--
-- Idempotente: ALTER FUNCTION ... SET search_path y DROP FUNCTION IF EXISTS.
-- =============================================================================

-- Funciones de acceso usadas por las políticas RLS de dymaerp.
ALTER FUNCTION dymaerp.jwt_email_normalized() SET search_path TO 'dymaerp';
ALTER FUNCTION dymaerp.empresa_id_actual()    SET search_path TO 'dymaerp';
ALTER FUNCTION dymaerp.es_super_admin()        SET search_path TO 'dymaerp';

-- Guard heredado específico de enlodemari (hardcodea el UUID de la empresa
-- enlodemari y fuerza data_schema='enlodemari'). No está asociado a ningún
-- trigger en dymaerp. Se elimina para no dejar el hardcode del tenant ajeno.
DROP FUNCTION IF EXISTS dymaerp.neura_enlodemari_block_other_empresas();
