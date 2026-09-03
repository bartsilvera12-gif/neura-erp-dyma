/**
 * Comisión de vendedores sobre cuotas efectivamente cobradas.
 *
 * Regla del negocio: la comisión se devenga cuando entra la plata, no cuando se
 * firma el contrato ni cuando vence la cuota. Una cuota pendiente no genera
 * nada; el día que se cobra, la comisión cae en el mes de ese cobro. Un pago
 * parcial genera comisión solo por la parte cobrada.
 *
 * Nada de esto se persiste: se recalcula al consultar. Guardar el devengado
 * obligaría a mantenerlo sincronizado con cada pago, anulación y corrección.
 */

/** Comisión de un cobro. `pct` es fracción (0.03 = 3%). */
export function comisionDeCobro(montoCobrado: number, pct: number, moneda: string): number {
  if (!Number.isFinite(montoCobrado) || montoCobrado <= 0) return 0;
  if (!Number.isFinite(pct) || pct <= 0) return 0;
  const bruto = montoCobrado * pct;
  // El guaraní no tiene centavos; el dólar se liquida con dos decimales.
  return moneda === "USD" ? Math.round(bruto * 100) / 100 : Math.round(bruto);
}

/**
 * Normaliza el porcentaje que llega de un formulario.
 *
 * La UI se escribe en porcentaje ("3") y la base guarda fracción (0.03). Cargar
 * 3 donde va 0.03 multiplicaría la comisión por cien, así que la conversión vive
 * en un solo lugar y la base además lo topea con un CHECK.
 */
export function pctDesdeFormulario(valor: string | number): number | null {
  const n = typeof valor === "number" ? valor : Number(String(valor).replace(",", "."));
  if (!Number.isFinite(n) || n < 0) return null;
  if (n > 100) return null;
  return Math.round((n / 100) * 1e6) / 1e6;
}

/** Fracción → texto para mostrar: 0.0325 → "3,25%". */
export function pctVisible(fraccion: number): string {
  const n = Number(fraccion);
  if (!Number.isFinite(n) || n <= 0) return "—";
  const pct = n * 100;
  const txt = Number.isInteger(pct) ? String(pct) : pct.toFixed(2).replace(/0$/, "");
  return `${txt.replace(".", ",")}%`;
}

/** Primer y último día del mes de `ref` (YYYY-MM), en calendario. */
export function rangoDelMes(ref: string): { desde: string; hasta: string } | null {
  const m = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(ref.trim());
  if (!m) return null;
  const y = Number(m[1]);
  const mes = Number(m[2]);
  const ultimo = new Date(Date.UTC(y, mes, 0)).getUTCDate();
  const p = (n: number) => String(n).padStart(2, "0");
  return { desde: `${y}-${p(mes)}-01`, hasta: `${y}-${p(mes)}-${p(ultimo)}` };
}
