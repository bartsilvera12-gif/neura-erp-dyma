export type EstadoVenta = "vigente" | "cancelada" | "anulada";
export type EstadoCuota = "pendiente" | "pagada" | "anulada";

export const ESTADO_VENTA_UI: Record<EstadoVenta, { label: string; chip: string }> = {
  vigente: { label: "Vigente", chip: "border-sky-200 bg-sky-50 text-sky-700" },
  cancelada: { label: "Cancelada", chip: "border-emerald-200 bg-emerald-50 text-emerald-700" },
  anulada: { label: "Anulada", chip: "border-slate-200 bg-slate-100 text-slate-500" },
};

export const ESTADO_CUOTA_UI: Record<EstadoCuota, { label: string; chip: string }> = {
  pendiente: { label: "Pendiente", chip: "border-amber-200 bg-amber-50 text-amber-700" },
  pagada: { label: "Pagada", chip: "border-emerald-200 bg-emerald-50 text-emerald-700" },
  anulada: { label: "Anulada", chip: "border-slate-200 bg-slate-100 text-slate-500" },
};

/** Una cuota tal como la devuelve la API, ya con su mora al día de hoy. */
export interface CuotaVenta {
  id: string;
  numero: number;
  vencimiento: string;
  capital: number;
  interes: number;
  total: number;
  saldo: number;
  estado: EstadoCuota;
  factura_id: string | null;
  factura_numero: string | null;
  pagada_at: string | null;
  /** Mora calculada al vuelo; no se guarda porque cambia todos los días. */
  dias_atraso: number;
  dias_en_mora: number;
  mora_administrativa: number;
  mora_moratoria: number;
  mora_total: number;
  /** Saldo + mora: lo que hay que cobrar hoy para cancelar la cuota. */
  total_a_pagar: number;
}

export interface VentaLote {
  id: string;
  numero_contrato: string;
  fecha_venta: string;
  lote_id: string;
  lote_label: string;
  cliente_id: string;
  cliente_label: string;
  /** Cónyuge y codeudores, con los datos que va a transcribir el contrato. */
  partes: {
    id: string;
    rol: "conyuge" | "codeudor";
    nombre: string;
    documento: string | null;
    domicilio: string | null;
    telefono: string | null;
  }[];
  /** Tipo de contrato elegido al vender; null en contratos anteriores al catálogo. */
  tipo_contrato: { id: string; slug: string; nombre: string } | null;
  precio_contado: number;
  entrega_inicial: number;
  capital: number;
  interes_total: number;
  monto_financiado: number;
  cantidad_cuotas: number;
  primer_vencimiento: string;
  moneda: string;
  recargo_pct: number;
  dias_gracia: number;
  mora_administrativa_pct: number;
  mora_moratoria_pct: number;
  estado: EstadoVenta;
  observacion: string | null;
  cuotas: CuotaVenta[];
  resumen: {
    cuotas_pagadas: number;
    cuotas_pendientes: number;
    cuotas_vencidas: number;
    cobrado: number;
    saldo: number;
    mora_acumulada: number;
    /** Saldo + mora de todo el contrato. */
    deuda_total: number;
  };
}

/** Fila del listado de contratos. */
export interface VentaResumen {
  id: string;
  numero_contrato: string;
  fecha_venta: string;
  lote_label: string;
  cliente_id: string;
  cliente_label: string;
  monto_financiado: number;
  cantidad_cuotas: number;
  moneda: string;
  estado: EstadoVenta;
  cuotas_pagadas: number;
  cuotas_vencidas: number;
  saldo: number;
  mora_acumulada: number;
}
