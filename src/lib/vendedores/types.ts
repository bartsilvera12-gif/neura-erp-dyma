/** Vendedor con su código de negocio (el que figura en el listado de comisiones). */
export interface Vendedor {
  id: string;
  codigo: string;
  nombre: string;
  documento: string | null;
  telefono: string | null;
  email: string | null;
  /** Comisión sugerida para ventas nuevas, como fracción: 0.03 = 3%. */
  comision_pct: number;
  activo: boolean;
  observacion: string | null;
  /** Contratos vigentes o cancelados a su nombre. Solo en el listado. */
  ventas?: number;
}

/** Un cobro concreto que generó comisión: una imputación a la factura de una cuota. */
export interface ComisionCobro {
  pago_id: string;
  fecha_pago: string; // YYYY-MM-DD
  monto_cobrado: number;
  venta_id: string;
  numero_contrato: string;
  lote_label: string;
  cliente_id: string;
  cliente_label: string;
  cuota_numero: number;
  cuota_vencimiento: string;
  factura_numero: string | null;
  moneda: string;
  /** Fracción congelada en el contrato: 0.03 = 3%. */
  comision_pct: number;
  comision: number;
}

/** Lo que le corresponde a un vendedor en el período consultado. */
export interface ComisionVendedor {
  vendedor_id: string;
  codigo: string;
  nombre: string;
  cobros: ComisionCobro[];
  /** Contratos distintos con al menos un cobro en el período. */
  ventas: number;
  clientes: number;
  cuotas_cobradas: number;
  total_cobrado: number;
  total_comision: number;
}

export interface ComisionesPayload {
  desde: string;
  hasta: string;
  vendedores: ComisionVendedor[];
  total_cobrado: number;
  total_comision: number;
  /** Cobros de contratos sin vendedor asignado: no generan comisión, pero conviene verlos. */
  cobros_sin_vendedor: number;
  monto_sin_vendedor: number;
}
