import "server-only";
import { createServiceRoleClient } from "@/lib/supabase/service-admin";
import { createServiceRoleClientForEmpresa } from "@/lib/supabase/empresa-data-schema";
import { getAuthUserForApiRoute } from "@/lib/auth/get-auth-user-for-api-route";
import { resolveUsuarioErpFromAuthUser } from "@/lib/auth/resolve-usuario-erp";
import { isBootstrapSuperAdminEmail } from "@/lib/auth/super-admin-bootstrap-email";
import { esRolAdminEmpresa, resolveEffectiveModules } from "@/lib/modulos/resolve-effective-modules";
import type { AppSupabaseClient } from "@/lib/supabase/schema";

export type LotesApiAuth =
  | { ok: true; empresaId: string; usuarioCatalogId: string; sb: AppSupabaseClient }
  | { ok: false; status: number; message: string };

/**
 * Acceso al módulo Lotes (slug `lotes`) + cliente del schema de la empresa.
 * Mismo patrón que `requireLimpiezaModuleAccess`; devuelve además el cliente ya
 * resuelto porque todas las rutas del módulo lo necesitan.
 */
export async function requireLotesModuleAccess(request: Request): Promise<LotesApiAuth> {
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
    if (!slugs.has("lotes")) {
      return { ok: false, status: 403, message: "Sin acceso al módulo Lotes." };
    }
  }

  const sb = await createServiceRoleClientForEmpresa(usuario.empresa_id);
  return { ok: true, empresaId: usuario.empresa_id, usuarioCatalogId: usuario.id, sb };
}
