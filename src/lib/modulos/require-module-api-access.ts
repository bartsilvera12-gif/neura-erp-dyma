import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-admin";
import { createServiceRoleClientForEmpresa } from "@/lib/supabase/empresa-data-schema";
import { getAuthUserForApiRoute } from "@/lib/auth/get-auth-user-for-api-route";
import { resolveUsuarioErpFromAuthUser } from "@/lib/auth/resolve-usuario-erp";
import { isBootstrapSuperAdminEmail } from "@/lib/auth/super-admin-bootstrap-email";
import { esRolAdminEmpresa, resolveEffectiveModules } from "@/lib/modulos/resolve-effective-modules";
import type { AppSupabaseClient } from "@/lib/supabase/schema";

export type ModuloApiAuth =
  | {
      ok: true;
      empresaId: string;
      usuarioCatalogId: string;
      rol: string | null;
      email: string | null;
      sb: AppSupabaseClient;
    }
  | { ok: false; status: number; message: string };

/**
 * Gate de acceso por módulo para rutas de API, más el cliente del schema de la empresa.
 *
 * Deja pasar a super_admin y al admin de empresa; al resto solo si `slug` está entre
 * sus módulos efectivos (empresa_modulos ∩ usuario_modulos).
 *
 * `etiqueta` es el nombre visible del módulo para el mensaje de error.
 */
export async function requireModuleApiAccess(
  request: Request,
  slug: string,
  etiqueta: string
): Promise<ModuloApiAuth> {
  const user = await getAuthUserForApiRoute(request);
  if (!user?.id) {
    return { ok: false, status: 401, message: "No autenticado" };
  }

  const catalog = createServiceRoleClient();
  const usuario = await resolveUsuarioErpFromAuthUser(catalog, user);

  if (!usuario?.empresa_id) {
    return { ok: false, status: 403, message: "Usuario sin empresa" };
  }

  const rol = (usuario.rol ?? "").trim();
  const esAdmin =
    rol === "super_admin" || isBootstrapSuperAdminEmail(user.email) || esRolAdminEmpresa(usuario.rol);

  if (!esAdmin) {
    const modulos = await resolveEffectiveModules(catalog, {
      id: usuario.id,
      empresa_id: usuario.empresa_id,
      rol: usuario.rol,
    });
    const slugs = new Set(modulos.map((m) => (m.slug ?? "").trim().toLowerCase()));
    if (!slugs.has(slug)) {
      return { ok: false, status: 403, message: `Sin acceso al módulo ${etiqueta}.` };
    }
  }

  const sb = await createServiceRoleClientForEmpresa(usuario.empresa_id);
  return {
    ok: true,
    empresaId: usuario.empresa_id,
    usuarioCatalogId: usuario.id,
    rol: usuario.rol,
    email: typeof user.email === "string" && user.email.trim() ? user.email.trim() : null,
    sb,
  };
}
