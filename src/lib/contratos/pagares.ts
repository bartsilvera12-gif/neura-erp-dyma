import type { CuotaContrato } from "./types";

/**
 * Pagarés del contrato, uno por período anual.
 *
 * El cliente pidió pagarés anuales en vez de uno por cuota: en un plan a cinco
 * años eso baja de 60 documentos a 5. Cada pagaré cubre las cuotas de un período
 * de doce meses y vence junto con la última de ese período.
 *
 * Los períodos se cuentan desde el vencimiento de la PRIMERA cuota, no por año
 * calendario: un contrato que arranca en septiembre tiene su primer año hasta
 * agosto del siguiente, que es lo que las partes entienden por "un año de
 * contrato". Si el plan no completa el último período, ese pagaré sale por lo
 * que quede.
 *
 * Función pura: se prueba sin base ni red.
 */

/**
 * Dónde está parado cada pagaré respecto de lo que cubre.
 *
 * - vigente:   no se cobró nada de sus cuotas.
 * - parcial:   se cobró algo, pero todavía se debe.
 * - cancelado: todas sus cuotas están pagadas. Hay que devolvérselo al deudor:
 *              un pagaré cancelado que queda en poder del acreedor sigue siendo
 *              un título ejecutable en su contra.
 * - anulado:   ninguna cuota quedó pendiente, pero tampoco se pagó ninguna —
 *              se anularon. No se rotula como cancelado porque no lo es.
 */
export type EstadoPagare = "vigente" | "parcial" | "cancelado" | "anulado";

export interface Pagare {
  /** Identidad estable, derivada del contrato: CTR-000002/1. */
  numero: string;
  /** 1 = primer año del contrato. */
  orden: number;
  /** Vencimiento de la primera cuota que cubre. */
  desde: string;
  /** Vencimiento de la última: es la fecha en que el pagaré se hace exigible. */
  vencimiento: string;
  /** Números de cuota incluidos, para que el documento pueda detallarlos. */
  cuotas: number[];
  /** Suma de las cuotas del período. Es lo que dice el pagaré firmado. */
  monto: number;
  estado: EstadoPagare;
  cuotas_pagadas: number;
  /** Lo que todavía se debe de este pagaré. */
  saldo: number;
  /** Día en que se pagó la última de sus cuotas. Solo si está cancelado. */
  cancelado_el: string | null;
}

/** Arma un pagaré a partir de las cuotas que cubre. */
function armarPagare(numeroContrato: string, orden: number, lista: CuotaContrato[]): Pagare {
  const estadoDe = (c: CuotaContrato) => c.estado ?? "pendiente";
  const pendientes = lista.filter((c) => estadoDe(c) === "pendiente");
  const pagadas = lista.filter((c) => estadoDe(c) === "pagada");
  const saldo = pendientes.reduce((a, c) => a + (c.saldo ?? c.total), 0);
  // Una cuota pendiente con saldo menor al total ya recibió un pago parcial.
  const hayPagoParcial = pendientes.some((c) => c.saldo !== undefined && c.saldo < c.total);

  let estado: EstadoPagare;
  if (pendientes.length === 0) estado = pagadas.length > 0 ? "cancelado" : "anulado";
  else if (pagadas.length > 0 || hayPagoParcial) estado = "parcial";
  else estado = "vigente";

  const fechasPago = pagadas
    .map((c) => String(c.pagada_at ?? "").slice(0, 10))
    .filter(Boolean)
    .sort();

  return {
    numero: `${numeroContrato}/${orden}`,
    orden,
    desde: lista[0]!.vencimiento,
    vencimiento: lista[lista.length - 1]!.vencimiento,
    cuotas: lista.map((c) => c.numero),
    monto: lista.reduce((a, c) => a + c.total, 0),
    estado,
    cuotas_pagadas: pagadas.length,
    saldo,
    cancelado_el: estado === "cancelado" ? fechasPago[fechasPago.length - 1] ?? null : null,
  };
}

/** Meses completos entre dos fechas YYYY-MM-DD, contando el día. */
function mesesEntre(desde: string, hasta: string): number {
  const [ay, am, ad] = desde.split("-").map(Number);
  const [by, bm, bd] = hasta.split("-").map(Number);
  if (!ay || !by) return 0;
  let meses = (by - ay) * 12 + (bm! - am!);
  // Todavía no se cumplió el mes si no llegó el día.
  if (bd! < ad!) meses -= 1;
  return meses;
}

/**
 * Agrupa las cuotas en pagarés de `mesesPorPagare` meses (12 = anual).
 *
 * Devuelve `[]` si no hay cuotas: una venta al contado no genera pagarés.
 */
export function generarPagares(
  numeroContrato: string,
  cuotas: CuotaContrato[],
  mesesPorPagare = 12
): Pagare[] {
  if (cuotas.length === 0) return [];
  if (!Number.isFinite(mesesPorPagare) || mesesPorPagare < 1) {
    throw new Error("El período del pagaré debe ser de al menos un mes");
  }

  const ordenadas = [...cuotas].sort((a, b) => a.numero - b.numero);
  const inicio = ordenadas[0]!.vencimiento;

  const grupos = new Map<number, CuotaContrato[]>();
  for (const c of ordenadas) {
    const periodo = Math.floor(mesesEntre(inicio, c.vencimiento) / mesesPorPagare);
    grupos.set(periodo, [...(grupos.get(periodo) ?? []), c]);
  }

  return [...grupos.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([, lista], i) => armarPagare(numeroContrato, i + 1, lista));
}

/**
 * Un pagaré por cuota.
 *
 * No es lo mismo que agrupar por un mes: con cuotas quincenales, un pagaré
 * mensual cubriría dos. Acá es literalmente uno por cuota, sea cual sea la
 * frecuencia del plan, y el número del pagaré coincide con el de la cuota.
 */
export function generarPagaresPorCuota(numeroContrato: string, cuotas: CuotaContrato[]): Pagare[] {
  return [...cuotas]
    .sort((a, b) => a.numero - b.numero)
    .map((c) => armarPagare(numeroContrato, c.numero, [c]));
}
