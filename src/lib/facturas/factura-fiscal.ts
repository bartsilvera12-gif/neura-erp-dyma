/**
 * Corte fiscal de una factura, tal como tiene que salir impreso.
 *
 * El formulario paraguayo tiene tres columnas de venta (exentas, 5%, 10%) y
 * abajo la liquidación del IVA. Ojo con la diferencia, que es la que más se
 * equivoca: en las columnas va el importe de la línea CON IVA incluido, y en la
 * liquidación va solo el impuesto. Por eso el total de la factura es la suma de
 * las tres columnas y no la suma de columnas más liquidación.
 *
 * `factura_items` no guarda la tasa: guarda base (`subtotal`) e impuesto
 * (`iva`), y la tasa se deduce de esos dos. Es la misma deducción que hace el
 * generador del XML de SIFEN, así que el papel y el electrónico dicen lo mismo.
 *
 * Módulo puro: no toca base de datos ni red.
 */

export type TasaIva = 0 | 5 | 10;

export interface LineaFactura {
  descripcion: string;
  cantidad: number;
  precio_unitario: number;
  subtotal: number;
  iva: number;
  total: number;
}

export interface LineaImpresa {
  descripcion: string;
  cantidad: number;
  precio_unitario: number;
  tasa: TasaIva;
  /** Importe de la línea con IVA incluido; va en la columna de su tasa. */
  importe: number;
}

export interface TotalesFactura {
  exentas: number;
  gravado_5: number;
  iva_5: number;
  gravado_10: number;
  iva_10: number;
  /** Suma de las tres columnas: lo que el cliente paga. */
  total: number;
}

/**
 * Deduce la tasa a partir de base e impuesto.
 *
 * Se compara el porcentaje redondeado con tolerancia de un punto porque las
 * bases se guardan redondeadas al guaraní: en importes chicos, 2.000 con IVA 10
 * da 1.818 + 182, que es 10,01%.
 */
export function inferirTasaIva(subtotal: number, iva: number): TasaIva {
  const base = Number(subtotal);
  const imp = Number(iva);
  if (!(base > 0) || !(imp > 0)) return 0;
  const p = Math.round((100 * imp) / base);
  if (Math.abs(p - 10) <= 1) return 10;
  if (Math.abs(p - 5) <= 1) return 5;
  return 10;
}

/** Las líneas listas para la grilla, con su tasa ya deducida. */
export function lineasImpresas(items: LineaFactura[]): LineaImpresa[] {
  return items.map((it) => {
    const tasa = inferirTasaIva(it.subtotal, it.iva);
    const importe = Math.round(Number(it.total) || Number(it.subtotal) + Number(it.iva) || 0);
    const cantidad = Number(it.cantidad) > 0 ? Number(it.cantidad) : 1;
    const pu = Number(it.precio_unitario) > 0 ? Number(it.precio_unitario) : importe / cantidad;
    return {
      descripcion: String(it.descripcion ?? ""),
      cantidad,
      precio_unitario: Math.round(pu),
      tasa,
      importe,
    };
  });
}

/** Totales por columna y liquidación del IVA. */
export function calcularTotalesFactura(items: LineaFactura[]): TotalesFactura {
  const t: TotalesFactura = { exentas: 0, gravado_5: 0, iva_5: 0, gravado_10: 0, iva_10: 0, total: 0 };
  for (const it of items) {
    const tasa = inferirTasaIva(it.subtotal, it.iva);
    const importe = Math.round(Number(it.total) || Number(it.subtotal) + Number(it.iva) || 0);
    const impuesto = Math.round(Number(it.iva) || 0);
    if (tasa === 10) {
      t.gravado_10 += importe;
      t.iva_10 += impuesto;
    } else if (tasa === 5) {
      t.gravado_5 += importe;
      t.iva_5 += impuesto;
    } else {
      t.exentas += importe;
    }
    t.total += importe;
  }
  return t;
}

/** "001-001-0000007", como lo exige la SET. */
export function formatearNumeroFiscal(
  establecimiento: string,
  puntoExpedicion: string,
  secuencia: number
): string {
  const tres = (v: string) => String(v ?? "").replace(/\D/g, "").padStart(3, "0").slice(-3);
  return `${tres(establecimiento)}-${tres(puntoExpedicion)}-${String(Math.max(1, Math.trunc(secuencia))).padStart(7, "0")}`;
}

/**
 * Próximo correlativo a usar.
 *
 * Arranca en `inicial` aunque nunca se haya emitido nada, porque el rango lo fija
 * la SET y no siempre empieza en 1. Devuelve null si el rango se agotó: ahí hay
 * que pedir timbrado nuevo, no seguir numerando.
 */
export function siguienteSecuencia(
  ultimaEmitida: number | null,
  inicial: number | null,
  final: number | null
): number | null {
  const desde = Number.isFinite(Number(inicial)) && Number(inicial) > 0 ? Number(inicial) : 1;
  const usada = Number.isFinite(Number(ultimaEmitida)) ? Number(ultimaEmitida) : 0;
  const proximo = usada > 0 ? usada + 1 : desde;
  const tope = Number.isFinite(Number(final)) && Number(final) > 0 ? Number(final) : null;
  if (tope !== null && proximo > tope) return null;
  return proximo;
}

/** La condición de venta que va tildada en el formulario. */
export function condicionFactura(tipo: string | null | undefined): "contado" | "credito" {
  return String(tipo ?? "").trim().toLowerCase() === "credito" ? "credito" : "contado";
}
