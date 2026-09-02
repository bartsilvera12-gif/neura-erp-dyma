import "server-only";
import { requireModuleApiAccess, type ModuloApiAuth } from "@/lib/modulos/require-module-api-access";

export type LimpiezaApiAuth = ModuloApiAuth;

/** Acceso al módulo Limpieza (slug `limpieza`) + cliente del schema de la empresa. */
export function requireLimpiezaModuleAccess(request: Request): Promise<LimpiezaApiAuth> {
  return requireModuleApiAccess(request, "limpieza", "Limpieza");
}
