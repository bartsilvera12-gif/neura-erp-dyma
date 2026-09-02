import type { EstadoLote } from "@/lib/lotes/types";

// ── Dashboard de ventas de lotes ─────────────────────────────────────────────

/** Una fila del dashboard: los estados de una fracción, con su valorización. */
export interface FilaFraccion {
  loteamiento_id: string;
  loteamiento: string;
  fraccion_id: string;
  fraccion: string;
  total: number;
  disponible: number;
  reservado: number;
  vendido: number;
  bloqueado: number;
  superficie_total: number;
  /** Suma del precio de lista de los vendidos, por moneda. */
  vendido_gs: number;
  vendido_usd: number;
  /** Suma del precio de lista de los que siguen disponibles. */
  disponible_gs: number;
  disponible_usd: number;
}

export interface ReporteLotesPayload {
  fracciones: FilaFraccion[];
  totales: {
    total: number;
    disponible: number;
    reservado: number;
    vendido: number;
    bloqueado: number;
    superficie_total: number;
    vendido_gs: number;
    vendido_usd: number;
    disponible_gs: number;
    disponible_usd: number;
  };
}

// ── Extracto de cuenta por cliente ───────────────────────────────────────────

export interface MovimientoExtracto {
  tipo: "factura" | "pago";
  fecha: string;
  /** Número de factura, o el de la factura a la que se imputó el pago. */
  documento: string;
  detalle: string;
  /** Lo que el cliente debe (factura emitida). */
  debe: number;
  /** Lo que el cliente pagó. */
  haber: number;
  estado: string | null;
  vencimiento: string | null;
  dias_atraso: number | null;
}

export interface ExtractoPayload {
  cliente: { id: string; label: string; ruc: string | null; documento: string | null } | null;
  movimientos: MovimientoExtracto[];
  resumen: {
    facturado: number;
    cobrado: number;
    saldo: number;
    facturas_pendientes: number;
    facturas_vencidas: number;
    saldo_vencido: number;
  };
  moneda: string;
}

// ── Reportes financieros ─────────────────────────────────────────────────────

/** Un mes del flujo de caja. */
export interface MesFlujo {
  mes: string; // YYYY-MM
  cobrado: number;
  egresos: number;
  neto: number;
}

/** Un tramo de la proyección de cobros (facturas pendientes por vencer). */
export interface TramoProyeccion {
  clave: string;
  label: string;
  facturas: number;
  monto: number;
}

/** Una fila del listado de cartera en mora. */
export interface FilaMora {
  factura_id: string;
  numero_factura: string;
  cliente_id: string;
  cliente: string;
  fecha_vencimiento: string | null;
  dias_atraso: number;
  monto: number;
  saldo: number;
  tramo: TramoMora;
}

export type TramoMora = "1_30" | "31_60" | "61_90" | "90_mas";

export const TRAMO_MORA_UI: Record<TramoMora, { label: string; chip: string }> = {
  "1_30": { label: "1 a 30 días", chip: "border-amber-200 bg-amber-50 text-amber-700" },
  "31_60": { label: "31 a 60 días", chip: "border-orange-200 bg-orange-50 text-orange-700" },
  "61_90": { label: "61 a 90 días", chip: "border-rose-200 bg-rose-50 text-rose-700" },
  "90_mas": { label: "Más de 90 días", chip: "border-red-300 bg-red-100 text-red-800" },
};

export interface FinancieroPayload {
  flujo: MesFlujo[];
  proyeccion: TramoProyeccion[];
  mora: FilaMora[];
  resumen: {
    cobrado_periodo: number;
    egresos_periodo: number;
    por_cobrar_total: number;
    en_mora_total: number;
    clientes_en_mora: number;
  };
  /** El módulo Gastos no está habilitado: los egresos van en cero hasta que lo esté. */
  egresos_disponibles: boolean;
}

/** Reexport para las vistas del dashboard de lotes. */
export type { EstadoLote };
