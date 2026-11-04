/**
 * Estado de resultado del período: ventas, costo, gastos y ganancia.
 *
 * Sigue el modelo que trajo el cliente: un bloque de ventas con su costo y su
 * porcentaje de utilidad, un bloque de gastos abierto por cuenta con columnas
 * Debe y Haber, y un resumen con resultado bruto, gastos de la empresa y
 * resultado neto.
 *
 * Sobre Debe y Haber: el ERP no lleva partida doble. Acá un gasto normal va al
 * Debe y lo que lo revierte —una nota de crédito, una corrección cargada en
 * negativo— va al Haber. Es la lectura que el papel permite sin inventar
 * asientos que el sistema no tiene.
 *
 * Módulo puro: recibe filas ya leídas y devuelve el reporte armado.
 */

/** Cómo se decide a qué mes pertenece una venta. */
export type BaseReporte = "percibido" | "devengado";

export const BASES: Record<BaseReporte, { label: string; detalle: string }> = {
  percibido: {
    label: "Percibido (cobrado)",
    detalle: "La venta entra en el mes en que se cobró. Las cuotas suman mes a mes, como entra la plata.",
  },
  devengado: {
    label: "Devengado (facturado)",
    detalle:
      "La venta entra en el mes en que se firmó el contrato, por el precio total. Las cuotas posteriores ya no suman.",
  },
};

/** Una venta del período, con lo que costó si se sabe. */
export interface VentaPeriodo {
  /** Agrupador visible: "Venta de lotes", "Servicio de limpieza"… */
  concepto: string;
  ingreso: number;
  costo: number;
  /** Cuántas de las operaciones agrupadas no tienen costo cargado. */
  sin_costo: number;
}

/** Un gasto del período ya resuelto contra su cuenta. */
export interface GastoPeriodo {
  cuenta_codigo: string;
  cuenta_nombre: string;
  orden: number;
  monto: number;
}

export interface FilaVenta {
  concepto: string;
  ingreso: number;
  costo: number;
  utilidad: number;
  /** Margen sobre el ingreso, en porcentaje. Null si no hubo ingreso. */
  pct: number | null;
  sin_costo: number;
}

export interface FilaGasto {
  codigo: string;
  cuenta: string;
  debe: number;
  haber: number;
  /** Debe menos haber: lo que esta cuenta pesó en el período. */
  neto: number;
}

export interface EstadoResultado {
  desde: string;
  hasta: string;
  base: BaseReporte;
  ventas: FilaVenta[];
  total_ventas: FilaVenta;
  gastos: FilaGasto[];
  total_gastos: { debe: number; haber: number; neto: number };
  /** Ventas menos costo de ventas. */
  resultado_bruto: number;
  /** Gastos operativos del período. */
  gastos_operativos: number;
  /** Resultado bruto menos gastos operativos. */
  resultado_neto: number;
  /** Operaciones vendidas sin costo cargado: el margen queda inflado. */
  ventas_sin_costo: number;
}

const r = (n: number) => Math.round(Number(n) || 0);

/** Margen sobre el ingreso. Null cuando no hubo ingreso: 0/0 no es 0%. */
export function porcentajeUtilidad(ingreso: number, utilidad: number): number | null {
  const i = Number(ingreso) || 0;
  if (i === 0) return null;
  return Math.round((utilidad / i) * 1000) / 10;
}

function aFilaVenta(v: VentaPeriodo): FilaVenta {
  const ingreso = r(v.ingreso);
  const costo = r(v.costo);
  const utilidad = ingreso - costo;
  return {
    concepto: v.concepto,
    ingreso,
    costo,
    utilidad,
    pct: porcentajeUtilidad(ingreso, utilidad),
    sin_costo: Math.max(0, Math.trunc(Number(v.sin_costo) || 0)),
  };
}

/**
 * Arma el reporte.
 *
 * Las cuentas sin movimiento no se listan: el modelo en papel las tiene impresas
 * todas porque es un formulario, pero en pantalla dieciocho renglones en cero
 * esconden los tres que importan.
 */
export function armarEstadoResultado(input: {
  desde: string;
  hasta: string;
  base: BaseReporte;
  ventas: VentaPeriodo[];
  gastos: GastoPeriodo[];
}): EstadoResultado {
  const ventas = input.ventas.map(aFilaVenta).filter((v) => v.ingreso !== 0 || v.costo !== 0);

  const ingresoTotal = ventas.reduce((a, v) => a + v.ingreso, 0);
  const costoTotal = ventas.reduce((a, v) => a + v.costo, 0);
  const utilidadTotal = ingresoTotal - costoTotal;
  const total_ventas: FilaVenta = {
    concepto: "Total ventas del período",
    ingreso: ingresoTotal,
    costo: costoTotal,
    utilidad: utilidadTotal,
    pct: porcentajeUtilidad(ingresoTotal, utilidadTotal),
    sin_costo: ventas.reduce((a, v) => a + v.sin_costo, 0),
  };

  // Un gasto cargado en negativo es una corrección: va al Haber, no resta del Debe.
  const porCuenta = new Map<string, FilaGasto & { orden: number }>();
  for (const g of input.gastos) {
    const clave = g.cuenta_codigo || g.cuenta_nombre;
    let fila = porCuenta.get(clave);
    if (!fila) {
      fila = {
        codigo: g.cuenta_codigo,
        cuenta: g.cuenta_nombre,
        debe: 0,
        haber: 0,
        neto: 0,
        orden: Number(g.orden) || 0,
      };
      porCuenta.set(clave, fila);
    }
    const monto = r(g.monto);
    if (monto >= 0) fila.debe += monto;
    else fila.haber += -monto;
  }

  const gastos: FilaGasto[] = [...porCuenta.values()]
    .map((f) => ({ ...f, neto: f.debe - f.haber }))
    .sort((a, b) => a.orden - b.orden || a.cuenta.localeCompare(b.cuenta, "es"))
    .map(({ codigo, cuenta, debe, haber, neto }) => ({ codigo, cuenta, debe, haber, neto }));

  const total_gastos = gastos.reduce(
    (acc, g) => ({ debe: acc.debe + g.debe, haber: acc.haber + g.haber, neto: acc.neto + g.neto }),
    { debe: 0, haber: 0, neto: 0 }
  );

  return {
    desde: input.desde,
    hasta: input.hasta,
    base: input.base,
    ventas,
    total_ventas,
    gastos,
    total_gastos,
    resultado_bruto: utilidadTotal,
    gastos_operativos: total_gastos.neto,
    resultado_neto: utilidadTotal - total_gastos.neto,
    ventas_sin_costo: total_ventas.sin_costo,
  };
}

/** Primer y último día del mes de `ymd`. */
export function rangoDelMes(ymd: string): { desde: string; hasta: string } {
  const [y, m] = String(ymd).slice(0, 7).split("-").map(Number);
  if (!y || !m) throw new Error("Mes inválido");
  const ultimo = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const mm = String(m).padStart(2, "0");
  return { desde: `${y}-${mm}-01`, hasta: `${y}-${mm}-${String(ultimo).padStart(2, "0")}` };
}

/** Acepta el rango solo si son dos fechas válidas y en orden. */
export function validarRango(desde: string, hasta: string): { ok: true } | { ok: false; error: string } {
  const re = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;
  if (!re.test(desde) || !re.test(hasta)) return { ok: false, error: "Las fechas deben tener formato AAAA-MM-DD." };
  if (desde > hasta) return { ok: false, error: "La fecha de inicio no puede ser posterior a la de fin." };
  return { ok: true };
}
