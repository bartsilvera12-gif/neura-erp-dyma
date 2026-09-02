/** Moneda del servicio, alineada a la de `facturas`. */
export type MonedaLimpieza = "GS" | "USD";

/** Condición de la factura que emite el servicio. */
export type TipoFacturaLimpieza = "contado" | "credito";

/** Un servicio de limpieza prestado, con la factura que generó. */
export interface ServicioLimpieza {
  id: string;
  cliente_id: string;
  cliente_label: string;
  fecha_servicio: string; // YYYY-MM-DD
  importe: number;
  moneda: MonedaLimpieza;
  observacion: string | null;
  factura_id: string | null;
  factura_numero: string | null;
  /** Estado de la factura asociada; `null` si la factura ya no existe. */
  factura_estado: string | null;
  factura_saldo: number | null;
  creado_por_email: string | null;
  created_at: string;
}

/** Totales del conjunto filtrado, para las tarjetas de arriba. */
export interface ResumenLimpieza {
  servicios: number;
  clientes: number;
  total_gs: number;
  total_usd: number;
  pendiente_gs: number;
  pendiente_usd: number;
}

export interface LimpiezaPayload {
  resumen: ResumenLimpieza;
  servicios: ServicioLimpieza[];
}
