/** Resumen del negocio de loteamiento que alimenta la pestaña Lotes del dashboard. */
export interface PanelLotes {
  /** Fecha de cálculo en Asunción, para que la mora sea reproducible. */
  hoy: string;
  lotes: {
    total: number;
    disponible: number;
    reservado: number;
    vendido: number;
    bloqueado: number;
    superficie_total: number;
    /** Precio de lista de los lotes que todavía se pueden vender. */
    valor_disponible: number;
  };
  contratos: {
    vigentes: number;
    cancelados: number;
    anulados: number;
    financiado_total: number;
  };
  cartera: {
    saldo_por_cobrar: number;
    mora_acumulada: number;
    cuotas_pendientes: number;
    cuotas_vencidas: number;
    vence_en_30_dias: number;
    cobrado_mes: number;
    cobros_mes: number;
  };
}
