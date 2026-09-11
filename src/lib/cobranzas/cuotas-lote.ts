import { calcularMoraCuota, DIAS_GRACIA } from "@/lib/financiacion/plan-cuotas";

/**
 * La deuda de los contratos de lotes, vista desde Cobranzas.
 *
 * Cobranzas se arma sobre facturas con saldo, pero en un contrato de lote la
 * factura de cada cuota recién se emite al cobrarla. Una cuota vencida y sin
 * pagar todavía no tiene factura, y el cliente moroso no aparecía: justo el
 * caso para el que existe la pantalla.
 *
 * Por eso la deuda de lotes se lee directo de las cuotas del contrato, con tres
 * reglas:
 *
 *  - Solo lo vencido y lo que vence en el mes en curso. Si entraran todas las
 *    cuotas futuras, cada cliente financiado aparecería "debiendo" el saldo
 *    entero del lote, y la lista dejaría de servir para saber a quién llamar.
 *  - Una cuota que ya tiene factura no se cuenta acá: eso pasa cuando recibió
 *    un pago parcial, y entonces ya entra en Cobranzas como factura. Contarla
 *    de las dos formas duplicaría la deuda.
 *  - Solo contratos vigentes. Uno cancelado o anulado no se cobra.
 *
 * Módulo puro: recibe filas y devuelve grupos, sin tocar la base.
 */

export interface CuotaLoteFila {
  id: string;
  venta_id: string;
  numero: number;
  vencimiento: string;
  total: number;
  saldo: number;
  estado: string;
  factura_id: string | null;
}

export interface VentaLoteFila {
  id: string;
  cliente_id: string;
  numero_contrato: string;
  estado: string;
  dias_gracia: number | null;
  lote_label: string | null;
}

/** Una cuota de lote con la forma que Cobranzas ya sabe mostrar. */
export interface ItemCuotaLote {
  /** Con prefijo: no es el id de una factura y no puede confundirse con uno. */
  id: string;
  numero_factura: string;
  fecha: null;
  fecha_vencimiento: string;
  monto: number;
  saldo: number;
  estado: string;
  tipo: "cuota_lote";
  vencida: boolean;
  origen: "cuota_lote";
}

export interface GrupoCuotasLote {
  venta_id: string;
  cliente_id: string;
  tipo: string;
  plan: string;
  cuotas: ItemCuotaLote[];
  /** Mora a hoy de las cuotas vencidas, con los días de gracia del contrato. */
  mora: number;
}

export const TIPO_LOTE = "Lote";

/** Prefijo de los ids de cuota, para distinguirlos de los de factura en el front. */
export const PREFIJO_CUOTA = "cuota:";

export function esItemCuotaLote(id: string | null | undefined): boolean {
  return String(id ?? "").startsWith(PREFIJO_CUOTA);
}

/**
 * Agrupa las cuotas cobrables por contrato, y los contratos por cliente.
 *
 * Un cliente con dos lotes tiene dos grupos: se cobran por separado y cada uno
 * tiene su propia pantalla de contrato.
 */
export function gruposCuotasLote(
  cuotas: CuotaLoteFila[],
  ventas: VentaLoteFila[],
  hoyYmd: string
): Map<string, GrupoCuotasLote[]> {
  const ventaPorId = new Map(ventas.map((v) => [v.id, v]));
  const mesHoy = hoyYmd.slice(0, 7);
  const porVenta = new Map<string, GrupoCuotasLote>();

  for (const c of cuotas) {
    const v = ventaPorId.get(c.venta_id);
    if (!v || v.estado !== "vigente") continue;
    if (c.estado !== "pendiente" || !(Number(c.saldo) > 0)) continue;
    if (c.factura_id) continue;

    const venc = String(c.vencimiento ?? "").slice(0, 10);
    if (!venc || venc.slice(0, 7) > mesHoy) continue;

    let g = porVenta.get(v.id);
    if (!g) {
      g = {
        venta_id: v.id,
        cliente_id: v.cliente_id,
        tipo: TIPO_LOTE,
        plan: v.lote_label ? `${v.numero_contrato} · ${v.lote_label}` : v.numero_contrato,
        cuotas: [],
        mora: 0,
      };
      porVenta.set(v.id, g);
    }

    const vencida = venc < hoyYmd;
    g.cuotas.push({
      id: `${PREFIJO_CUOTA}${c.id}`,
      numero_factura: `${v.numero_contrato} · cuota ${c.numero}`,
      fecha: null,
      fecha_vencimiento: venc,
      monto: Number(c.total) || 0,
      saldo: Number(c.saldo) || 0,
      estado: c.estado,
      tipo: "cuota_lote",
      vencida,
      origen: "cuota_lote",
    });

    if (vencida) {
      g.mora += calcularMoraCuota({
        montoCuota: Number(c.saldo) || 0,
        vencimiento: venc,
        hoy: hoyYmd,
        diasGracia: v.dias_gracia ?? DIAS_GRACIA,
      }).total;
    }
  }

  const porCliente = new Map<string, GrupoCuotasLote[]>();
  for (const g of porVenta.values()) {
    g.cuotas.sort((a, b) => a.fecha_vencimiento.localeCompare(b.fecha_vencimiento));
    g.mora = Math.round(g.mora);
    porCliente.set(g.cliente_id, [...(porCliente.get(g.cliente_id) ?? []), g]);
  }
  return porCliente;
}
