import "server-only";
import { requireModuleApiAccess, type ModuloApiAuth } from "@/lib/modulos/require-module-api-access";

export type ReportesApiAuth = ModuloApiAuth;

/** Acceso al módulo Reportes (slug `reportes`) + cliente del schema de la empresa. */
export function requireReportesModuleAccess(request: Request): Promise<ReportesApiAuth> {
  return requireModuleApiAccess(request, "reportes", "Reportes");
}
