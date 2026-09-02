import "server-only";
import { requireModuleApiAccess, type ModuloApiAuth } from "@/lib/modulos/require-module-api-access";

export type LotesApiAuth = ModuloApiAuth;

/** Acceso al módulo Lotes (slug `lotes`) + cliente del schema de la empresa. */
export function requireLotesModuleAccess(request: Request): Promise<LotesApiAuth> {
  return requireModuleApiAccess(request, "lotes", "Lotes");
}
