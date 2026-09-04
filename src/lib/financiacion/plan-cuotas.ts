/**
 * Motor de cálculo del financiamiento de lotes.
 *
 * Reglas definidas por el cliente:
 *   - Recargo del 15% sobre el capital financiado, repartido en cuotas iguales.
 *   - Mora: 5% diario acumulativo sobre la cuota vencida, desglosado en
 *     1,7% de gastos administrativos y 3,3% de gastos moratorios.
 *   - 5 días de gracia: la mora recién corre a partir del sexto día de atraso.
 *
 * Todo es función pura y sin dependencias: la aritmética del dinero se prueba
 * sola, sin base ni red.
 */

/** Recargo por financiar, sobre el capital. */
export const RECARGO_FINANCIACION = 0.15;

/**
 * Tope de cuotas de un plan: 600 son 50 años de cuotas mensuales.
 *
 * No es un capricho de negocio, es un cortafuegos. El plan se arma cuota por
 * cuota, así que una cantidad disparatada congela el navegador mientras teclea
 * el vendedor —basta proponer una cuota muy chica para que el cálculo pida
 * millones de cuotas— y colgaría igual al servidor si llega por la API.
 */
export const MAX_CUOTAS = 600;

/** Días de gracia antes de que empiece a correr la mora. */
export const DIAS_GRACIA = 5;

/** Componentes del 5% diario de mora. Suman exactamente 5%. */
export const MORA_ADMINISTRATIVA_DIARIA = 0.017;
export const MORA_MORATORIA_DIARIA = 0.033;
export const MORA_TOTAL_DIARIA = MORA_ADMINISTRATIVA_DIARIA + MORA_MORATORIA_DIARIA;

export interface Cuota {
  numero: number;
  /** YYYY-MM-DD */
  vencimiento: string;
  /** Parte de la cuota que amortiza capital. */
  capital: number;
  /** Parte de la cuota que corresponde al recargo del 15%. */
  interes: number;
  /** Lo que el cliente paga ese mes. */
  total: number;
}

export interface PlanCuotas {
  precio_contado: number;
  entrega_inicial: number;
  /** Lo que queda a financiar antes del recargo. */
  capital: number;
  /** Recargo del 15% sobre el capital. */
  interes_total: number;
  /** Capital + recargo: lo que se reparte en cuotas. */
  monto_financiado: number;
  /** Entrega + monto financiado: lo que termina pagando el cliente. */
  total_operacion: number;
  cuotas: Cuota[];
}

export interface MoraCuota {
  /** Días corridos desde el vencimiento. 0 si todavía no venció. */
  dias_atraso: number;
  /** Días que efectivamente generan mora (descontada la gracia). */
  dias_en_mora: number;
  gastos_administrativos: number;
  gastos_moratorios: number;
  /** Suma de los dos anteriores. */
  total: number;
}

/**
 * Suma meses a una fecha YYYY-MM-DD conservando el día, recortando cuando el mes
 * destino es más corto: 31/01 + 1 mes = 28/02 (o 29 en bisiesto), no 03/03.
 * Se opera en UTC porque son fechas de calendario, no instantes.
 */
export function sumarMeses(fecha: string, meses: number): string {
  const [y, m, d] = fecha.split("-").map(Number);
  const base = new Date(Date.UTC(y, m - 1 + meses, 1));
  const ultimoDia = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth() + 1, 0)).getUTCDate();
  const dia = Math.min(d, ultimoDia);
  const mm = String(base.getUTCMonth() + 1).padStart(2, "0");
  return `${base.getUTCFullYear()}-${mm}-${String(dia).padStart(2, "0")}`;
}

/** Suma días corridos a una fecha YYYY-MM-DD, en UTC (fecha de calendario). */
export function sumarDias(fecha: string, dias: number): string {
  const t = Date.parse(`${fecha}T00:00:00Z`) + dias * 86_400_000;
  return new Date(t).toISOString().slice(0, 10);
}

/** Cada cuánto vence una cuota. El estándar del negocio es mensual. */
export type Frecuencia = "quincenal" | "mensual" | "bimestral" | "trimestral" | "semestral" | "anual";

/**
 * Paso de cada frecuencia. Las mensuales y sus múltiplos avanzan por mes de
 * calendario (conservando el día); la quincenal avanza por días corridos,
 * porque "quincena" acá son 15 días, no medio mes.
 */
export const FRECUENCIAS: Record<Frecuencia, { label: string; meses: number; dias: number }> = {
  quincenal: { label: "Quincenal", meses: 0, dias: 15 },
  mensual: { label: "Mensual", meses: 1, dias: 0 },
  bimestral: { label: "Bimestral", meses: 2, dias: 0 },
  trimestral: { label: "Trimestral", meses: 3, dias: 0 },
  semestral: { label: "Semestral", meses: 6, dias: 0 },
  anual: { label: "Anual", meses: 12, dias: 0 },
};

export function esFrecuencia(v: unknown): v is Frecuencia {
  return typeof v === "string" && Object.prototype.hasOwnProperty.call(FRECUENCIAS, v);
}

/** Vencimiento de la cuota `indice` (0 = la primera) según la frecuencia. */
export function vencimientoCuota(primero: string, indice: number, frecuencia: Frecuencia): string {
  const f = FRECUENCIAS[frecuencia];
  return f.meses > 0 ? sumarMeses(primero, indice * f.meses) : sumarDias(primero, indice * f.dias);
}

/** Días corridos entre dos fechas YYYY-MM-DD. Positivo si `hasta` es posterior. */
export function diasEntre(desde: string, hasta: string): number {
  return Math.round((Date.parse(`${hasta}T00:00:00Z`) - Date.parse(`${desde}T00:00:00Z`)) / 86_400_000);
}

/**
 * Arma el plan de cuotas.
 *
 * El recargo del 15% se aplica sobre el CAPITAL (precio de contado menos la
 * entrega inicial), no sobre el precio de lista: lo que se paga al contado el
 * primer día no se está financiando, así que no corresponde recargarlo.
 *
 * Los guaraníes no tienen centavos, así que todo se redondea a entero y la
 * última cuota absorbe la diferencia. De esa forma la suma de las cuotas es
 * siempre exactamente el monto financiado, sin desvíos de uno o dos guaraníes.
 */
export function generarPlanCuotas(input: {
  precioContado: number;
  entregaInicial?: number;
  cantidadCuotas: number;
  /** Vencimiento de la primera cuota, YYYY-MM-DD. */
  primerVencimiento: string;
  /** Por defecto 15%. Se puede pisar para planes personalizados. */
  recargo?: number;
  /** Por defecto mensual. */
  frecuencia?: Frecuencia;
}): PlanCuotas {
  const precioContado = Math.round(input.precioContado);
  const entrega = Math.round(input.entregaInicial ?? 0);
  const n = Math.trunc(input.cantidadCuotas);
  const recargo = input.recargo ?? RECARGO_FINANCIACION;

  if (!Number.isFinite(precioContado) || precioContado <= 0) {
    throw new Error("El precio de contado debe ser mayor a 0");
  }
  if (entrega < 0) throw new Error("La entrega inicial no puede ser negativa");
  if (entrega >= precioContado) {
    throw new Error("La entrega inicial no puede cubrir todo el precio: no habría nada que financiar");
  }
  if (!Number.isFinite(n) || n < 1) throw new Error("La cantidad de cuotas debe ser al menos 1");
  if (n > MAX_CUOTAS) {
    throw new Error(`El plan no puede tener más de ${MAX_CUOTAS} cuotas (son 50 años).`);
  }

  const capital = precioContado - entrega;
  const interesTotal = Math.round(capital * recargo);
  const montoFinanciado = capital + interesTotal;

  // Cuota pareja para las n-1 primeras; la última cierra el total exacto.
  const cuotaBase = Math.round(montoFinanciado / n);
  const capitalBase = Math.round(capital / n);
  const interesBase = Math.round(interesTotal / n);

  const cuotas: Cuota[] = [];
  for (let i = 1; i <= n; i++) {
    const esUltima = i === n;
    const total = esUltima ? montoFinanciado - cuotaBase * (n - 1) : cuotaBase;
    const cap = esUltima ? capital - capitalBase * (n - 1) : capitalBase;
    const int = esUltima ? interesTotal - interesBase * (n - 1) : interesBase;
    cuotas.push({
      numero: i,
      vencimiento: vencimientoCuota(input.primerVencimiento, i - 1, input.frecuencia ?? "mensual"),
      capital: cap,
      interes: int,
      total,
    });
  }

  return {
    precio_contado: precioContado,
    entrega_inicial: entrega,
    capital,
    interes_total: interesTotal,
    monto_financiado: montoFinanciado,
    total_operacion: entrega + montoFinanciado,
    cuotas,
  };
}

/**
 * Cuántas cuotas hacen falta para cubrir `montoFinanciado` pagando `cuota` por vez.
 *
 * Se redondea hacia arriba: si sobra un resto, hace falta una cuota más. Esa
 * última sale más chica que las demás, no más grande, así el cliente nunca paga
 * de más al final.
 */
export function cuotasNecesarias(montoFinanciado: number, cuota: number): number {
  if (!Number.isFinite(montoFinanciado) || montoFinanciado <= 0) {
    throw new Error("No hay saldo para financiar");
  }
  if (!Number.isFinite(cuota) || cuota <= 0) {
    throw new Error("La cuota propuesta debe ser mayor a 0");
  }
  const n = Math.ceil(montoFinanciado / cuota);
  if (!Number.isFinite(n)) throw new Error("La cuota propuesta no permite calcular un plan");
  return Math.max(1, n);
}

/** Cómo se resolvió la simulación: qué dato puso el usuario y cuál dedujo el sistema. */
export type ModoSimulacion = "por_cuota" | "por_cantidad";

export interface Simulacion extends PlanCuotas {
  modo: ModoSimulacion;
  frecuencia: Frecuencia;
  recargo_pct: number;
  cantidad_cuotas: number;
  /** La cuota pareja del plan (las primeras n-1). */
  cuota: number;
  /** La última, que absorbe el redondeo. Puede diferir en unos guaraníes. */
  cuota_final: number;
  /** Solo en modo por_cuota: lo que pidió el cliente, antes de ajustar. */
  cuota_propuesta: number | null;
  primer_vencimiento: string;
  ultimo_vencimiento: string;
}

/**
 * Simula un plan de pago sin tocar la base.
 *
 * Dos formas de entrar, que es lo que pide el negocio al negociar con el cliente:
 *   - `cantidadCuotas`: "quiero 24 cuotas, ¿de cuánto me sale cada una?"
 *   - `cuotaPropuesta`: "puedo pagar 1.000.000 por mes, ¿en cuántas termino?"
 *
 * En el segundo caso la cantidad sale de dividir y redondear hacia arriba, y
 * después el plan se rearma con esa cantidad: por eso la cuota resultante puede
 * quedar unos guaraníes por debajo de la propuesta.
 */
export function simularPlan(input: {
  precioContado: number;
  entregaInicial?: number;
  primerVencimiento: string;
  frecuencia?: Frecuencia;
  recargo?: number;
  cantidadCuotas?: number;
  cuotaPropuesta?: number;
}): Simulacion {
  const frecuencia = input.frecuencia ?? "mensual";
  const recargo = input.recargo ?? RECARGO_FINANCIACION;
  if (!Number.isFinite(recargo) || recargo < 0 || recargo > 1) {
    throw new Error("El recargo debe estar entre 0% y 100%");
  }

  const precioContado = Math.round(input.precioContado);
  const entrega = Math.round(input.entregaInicial ?? 0);
  if (!Number.isFinite(precioContado) || precioContado <= 0) {
    throw new Error("El valor del lote debe ser mayor a 0");
  }
  if (entrega < 0) throw new Error("La entrega no puede ser negativa");
  if (entrega >= precioContado) {
    throw new Error("La entrega cubre todo el precio: no queda saldo para financiar");
  }

  const capital = precioContado - entrega;
  const montoFinanciado = capital + Math.round(capital * recargo);

  let modo: ModoSimulacion;
  let n: number;
  let propuesta: number | null = null;

  if (input.cuotaPropuesta != null && input.cuotaPropuesta > 0) {
    modo = "por_cuota";
    propuesta = Math.round(input.cuotaPropuesta);
    n = cuotasNecesarias(montoFinanciado, propuesta);
    if (n > MAX_CUOTAS) {
      const minima = Math.ceil(montoFinanciado / MAX_CUOTAS);
      throw new Error(
        `Con una cuota de ${propuesta.toLocaleString("es-PY")} harían falta ${n.toLocaleString("es-PY")} cuotas. ` +
          `La cuota mínima para entrar en ${MAX_CUOTAS} es ${minima.toLocaleString("es-PY")}.`
      );
    }
  } else {
    modo = "por_cantidad";
    n = Math.trunc(input.cantidadCuotas ?? 0);
    if (!Number.isFinite(n) || n < 1) throw new Error("Indicá la cantidad de cuotas o la cuota propuesta");
  }

  const plan = generarPlanCuotas({
    precioContado,
    entregaInicial: entrega,
    cantidadCuotas: n,
    primerVencimiento: input.primerVencimiento,
    recargo,
    frecuencia,
  });

  return {
    ...plan,
    modo,
    frecuencia,
    recargo_pct: recargo,
    cantidad_cuotas: n,
    cuota: plan.cuotas[0]?.total ?? 0,
    cuota_final: plan.cuotas[plan.cuotas.length - 1]?.total ?? 0,
    cuota_propuesta: propuesta,
    primer_vencimiento: input.primerVencimiento,
    ultimo_vencimiento: plan.cuotas[plan.cuotas.length - 1]?.vencimiento ?? input.primerVencimiento,
  };
}

/**
 * Mora de una cuota vencida a una fecha dada.
 *
 * 5% diario ACUMULATIVO sobre el importe de la cuota, contando desde el sexto día
 * de atraso: con 5 días de gracia, 5 días de atraso no generan nada y 6 días
 * generan un día de mora.
 *
 * El cálculo es simple (no compuesto): se multiplica el porcentaje por la
 * cantidad de días. Esta tasa es muy alta y crece rápido —a 20 días de mora la
 * cuota se duplica—, pero es la regla que definió el cliente.
 */
export function calcularMoraCuota(input: {
  montoCuota: number;
  /** Vencimiento de la cuota, YYYY-MM-DD. */
  vencimiento: string;
  /** Fecha de cálculo, YYYY-MM-DD. */
  hoy: string;
  diasGracia?: number;
}): MoraCuota {
  const gracia = input.diasGracia ?? DIAS_GRACIA;
  const atraso = Math.max(0, diasEntre(input.vencimiento, input.hoy));
  const enMora = Math.max(0, atraso - gracia);

  const monto = Math.max(0, input.montoCuota);
  const administrativos = Math.round(monto * MORA_ADMINISTRATIVA_DIARIA * enMora);
  const moratorios = Math.round(monto * MORA_MORATORIA_DIARIA * enMora);

  return {
    dias_atraso: atraso,
    dias_en_mora: enMora,
    gastos_administrativos: administrativos,
    gastos_moratorios: moratorios,
    total: administrativos + moratorios,
  };
}

/** Cuota con su mora al día de hoy y lo que habría que cobrar para cancelarla. */
export interface CuotaConMora extends Cuota {
  mora: MoraCuota;
  total_a_pagar: number;
}

/** Aplica la mora a un conjunto de cuotas impagas. */
export function aplicarMora(cuotas: Cuota[], hoy: string, diasGracia?: number): CuotaConMora[] {
  return cuotas.map((c) => {
    const mora = calcularMoraCuota({
      montoCuota: c.total,
      vencimiento: c.vencimiento,
      hoy,
      diasGracia,
    });
    return { ...c, mora, total_a_pagar: c.total + mora.total };
  });
}
