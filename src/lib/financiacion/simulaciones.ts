import type { Frecuencia, ModoSimulacion } from "./plan-cuotas";

export type EstadoSimulacion = "borrador" | "descartada" | "aprobada";

export const ESTADO_SIMULACION_UI: Record<EstadoSimulacion, { label: string; chip: string }> = {
  borrador: { label: "En análisis", chip: "border-slate-200 bg-slate-50 text-slate-600" },
  descartada: { label: "Descartada", chip: "border-amber-200 bg-amber-50 text-amber-700" },
  aprobada: { label: "Aprobada", chip: "border-emerald-200 bg-emerald-50 text-emerald-700" },
};

/** Una propuesta guardada en el historial, con el resultado tal como se calculó ese día. */
export interface SimulacionGuardada {
  id: string;
  cliente_id: string | null;
  lote_id: string | null;
  nombre: string | null;
  precio_contado: number;
  entrega_inicial: number;
  recargo_pct: number;
  frecuencia: Frecuencia;
  primer_vencimiento: string;
  modo: ModoSimulacion;
  cuota_propuesta: number | null;
  capital: number;
  interes_total: number;
  monto_financiado: number;
  cantidad_cuotas: number;
  cuota: number;
  cuota_final: number;
  ultimo_vencimiento: string;
  observacion: string | null;
  estado: EstadoSimulacion;
  created_at: string;
  /** Etiquetas resueltas en el listado; no vienen de la tabla. */
  cliente_label?: string | null;
  lote_label?: string | null;
}

/** Fila de `plan_simulaciones` → objeto de dominio. */
export function aSimulacionGuardada(row: Record<string, unknown>): SimulacionGuardada {
  const ymd = (v: unknown) => String(v ?? "").slice(0, 10);
  return {
    id: String(row.id),
    cliente_id: (row.cliente_id as string) ?? null,
    lote_id: (row.lote_id as string) ?? null,
    nombre: (row.nombre as string) ?? null,
    precio_contado: Number(row.precio_contado ?? 0),
    entrega_inicial: Number(row.entrega_inicial ?? 0),
    recargo_pct: Number(row.recargo_pct ?? 0),
    frecuencia: (row.frecuencia as Frecuencia) ?? "mensual",
    primer_vencimiento: ymd(row.primer_vencimiento),
    modo: (row.modo as ModoSimulacion) ?? "por_cantidad",
    cuota_propuesta: row.cuota_propuesta == null ? null : Number(row.cuota_propuesta),
    capital: Number(row.capital ?? 0),
    interes_total: Number(row.interes_total ?? 0),
    monto_financiado: Number(row.monto_financiado ?? 0),
    cantidad_cuotas: Number(row.cantidad_cuotas ?? 0),
    cuota: Number(row.cuota ?? 0),
    cuota_final: Number(row.cuota_final ?? 0),
    ultimo_vencimiento: ymd(row.ultimo_vencimiento),
    observacion: (row.observacion as string) ?? null,
    estado: (row.estado as EstadoSimulacion) ?? "borrador",
    created_at: String(row.created_at ?? ""),
    cliente_label: null,
    lote_label: null,
  };
}
