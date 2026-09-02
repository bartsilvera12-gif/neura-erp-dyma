/** Saneamiento y reglas de negocio del lote, compartidos por las rutas del módulo. */
import { type EstadoLote } from "@/lib/lotes/types";

/** Campos editables del lote, con su saneamiento. Compartido por POST y PATCH. */
export function camposLoteDesdeBody(body: Record<string, unknown>): Record<string, unknown> {
  const num = (v: unknown): number | null => {
    if (v === null || v === undefined || v === "") return null;
    const n = Number(v);
    return Number.isFinite(n) ? n : null;
  };
  const txt = (v: unknown): string | null => (typeof v === "string" && v.trim() ? v.trim() : null);

  const out: Record<string, unknown> = {};
  if ("numero" in body) out.numero = typeof body.numero === "string" ? body.numero.trim() : "";
  if ("superficie_m2" in body) out.superficie_m2 = num(body.superficie_m2);
  if ("frente_m" in body) out.frente_m = num(body.frente_m);
  if ("fondo_m" in body) out.fondo_m = num(body.fondo_m);
  if ("lindero_norte" in body) out.lindero_norte = txt(body.lindero_norte);
  if ("lindero_sur" in body) out.lindero_sur = txt(body.lindero_sur);
  if ("lindero_este" in body) out.lindero_este = txt(body.lindero_este);
  if ("lindero_oeste" in body) out.lindero_oeste = txt(body.lindero_oeste);
  if ("precio_contado" in body) out.precio_contado = num(body.precio_contado);
  if ("precio_financiado" in body) out.precio_financiado = num(body.precio_financiado);
  if ("moneda" in body) out.moneda = body.moneda === "USD" ? "USD" : "GS";
  if ("observacion" in body) out.observacion = txt(body.observacion);
  if ("estado_motivo" in body) out.estado_motivo = txt(body.estado_motivo);
  return out;
}

/**
 * Regla de negocio del estado, la misma que protege el CHECK en la base:
 * reservado y vendido exigen titular; disponible no puede tenerlo.
 */
export function validarEstadoYTitular(
  estado: EstadoLote,
  clienteId: string | null
): { ok: true } | { ok: false; error: string } {
  if ((estado === "reservado" || estado === "vendido") && !clienteId) {
    return { ok: false, error: `Un lote ${estado} necesita un cliente asignado.` };
  }
  if (estado === "disponible" && clienteId) {
    return { ok: false, error: "Un lote disponible no puede tener cliente asignado." };
  }
  return { ok: true };
}
