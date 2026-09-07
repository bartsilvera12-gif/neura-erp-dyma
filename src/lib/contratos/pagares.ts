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
  /** Suma de las cuotas del período. */
  monto: number;
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
    .map(([periodo, lista], i) => ({
      numero: `${numeroContrato}/${i + 1}`,
      orden: i + 1,
      desde: lista[0]!.vencimiento,
      vencimiento: lista[lista.length - 1]!.vencimiento,
      cuotas: lista.map((c) => c.numero),
      monto: lista.reduce((a, c) => a + c.total, 0),
      _periodo: periodo,
    }))
    .map(({ _periodo, ...p }) => p);
}
