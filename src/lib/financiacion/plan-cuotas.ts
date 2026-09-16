/**
 * Motor de cálculo del financiamiento de lotes.
 *
 * Reglas definidas por el cliente:
 *   - Financiación por sistema de amortización FRANCÉS (cuota fija), igual a la
 *     calculadora del BCP. La tasa anual (15%) se convierte a tasa del período
 *     (15% / 12 = 1,25% mensual) y se arma una cuota fija con la fórmula
 *     `Cuota = capital × i / (1 − (1 + i)^(−n))`. En cada cuota el interés se
 *     calcula sobre el saldo, así el interés baja y la amortización sube; la
 *     última cuota se ajusta para que el saldo cierre exactamente en cero.
 *   - Mora: 5% diario acumulativo sobre la cuota vencida, desglosado en
 *     1,7% de gastos administrativos y 3,3% de gastos moratorios. Se calcula
 *     aparte y NO se mezcla con el interés de financiación.
 *   - 5 días de gracia: la mora recién corre a partir del sexto día de atraso.
 *
 * Todo es función pura y sin dependencias: la aritmética del dinero se prueba
 * sola, sin base ni red.
 */

/**
 * Tasa nominal ANUAL de financiación. Se divide por 12 para la tasa mensual del
 * sistema francés (15% → 1,25% mensual). No es un recargo total: el interés
 * total sale de la amortización y depende del plazo.
 */
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
  /** Saldo de capital al iniciar el período (antes de pagar esta cuota). */
  saldo_inicial: number;
  /** Interés del período = saldo_inicial × tasa del período. Baja cuota a cuota. */
  interes: number;
  /** Capital amortizado en esta cuota = total − interes. Sube cuota a cuota. */
  capital: number;
  /** Lo que el cliente paga ese mes (cuota fija; la última puede diferir por redondeo). */
  total: number;
  /** Saldo de capital después de pagar esta cuota. En la última queda en 0. */
  saldo_final: number;
}

export interface PlanCuotas {
  precio_contado: number;
  entrega_inicial: number;
  /** Capital financiado (precio de contado − entrega inicial). */
  capital: number;
  /** Suma de los intereses de todas las cuotas del sistema francés. */
  interes_total: number;
  /** Capital + interés total = total a pagar del saldo financiado (suma de las cuotas). */
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

/**
 * Cuántos meses de calendario abarca una cuota, según su frecuencia. La
 * quincenal (15 días corridos) cuenta como medio mes.
 */
export function mesesPorCuota(frecuencia: Frecuencia): number {
  const f = FRECUENCIAS[frecuencia];
  return f.meses > 0 ? f.meses : f.dias / 30;
}

/**
 * Tasa de interés del período, a partir de la tasa nominal anual.
 *
 * La anual se prorratea por los meses que abarca cada cuota: mensual = anual/12
 * (15% → 1,25%), bimestral = anual/6, quincenal = anual/24. Así una misma tasa
 * anual sirve para cualquier frecuencia sin cambiar la fórmula.
 */
export function tasaPeriodica(recargoAnual: number, frecuencia: Frecuencia): number {
  return (recargoAnual * mesesPorCuota(frecuencia)) / 12;
}

/**
 * Cuota fija del sistema de amortización francés (la de la calculadora del BCP):
 *   Cuota = capital × i / (1 − (1 + i)^(−n))
 * Con tasa 0 (venta sin recargo) es el capital repartido en partes iguales.
 * Devuelve el valor exacto sin redondear; el redondeo lo hace quien la usa.
 */
export function cuotaFrancesa(capital: number, i: number, n: number): number {
  if (i <= 0) return capital / n;
  return (capital * i) / (1 - Math.pow(1 + i, -n));
}

/** Días corridos entre dos fechas YYYY-MM-DD. Positivo si `hasta` es posterior. */
export function diasEntre(desde: string, hasta: string): number {
  return Math.round((Date.parse(`${hasta}T00:00:00Z`) - Date.parse(`${desde}T00:00:00Z`)) / 86_400_000);
}

/**
 * Arma el plan de cuotas por amortización francesa (cuota fija), igual a la
 * calculadora del BCP.
 *
 * Se financia sólo el CAPITAL (precio de contado menos la entrega inicial): lo
 * que se paga al contado el primer día no se financia. Con la tasa del período
 * (anual/12 para mensual) se calcula una cuota fija y, cuota a cuota, el interés
 * se cobra sobre el saldo pendiente —así baja— y el resto amortiza capital
 * —así sube—.
 *
 * Los guaraníes no tienen centavos: la cuota y cada interés se redondean a
 * entero, y la última cuota se ajusta para que el saldo cierre exactamente en
 * cero. Por eso la suma de las cuotas es siempre exactamente el monto financiado.
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
  const frecuencia = input.frecuencia ?? "mensual";

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
  const i = tasaPeriodica(recargo, frecuencia);

  // Cuota fija del sistema francés, redondeada al guaraní. Las primeras n-1 salen
  // por esta cuota; la última amortiza el saldo que quede para cerrar en cero.
  const cuotaFija = Math.round(cuotaFrancesa(capital, i, n));

  const cuotas: Cuota[] = [];
  let saldo = capital;
  for (let k = 1; k <= n; k++) {
    const esUltima = k === n;
    const interes = Math.round(saldo * i);
    // La última cuota amortiza todo el saldo restante (ajuste por redondeo).
    const cap = esUltima ? saldo : cuotaFija - interes;
    const total = esUltima ? cap + interes : cuotaFija;
    const saldoFinal = saldo - cap;
    cuotas.push({
      numero: k,
      vencimiento: vencimientoCuota(input.primerVencimiento, k - 1, frecuencia),
      saldo_inicial: saldo,
      interes,
      capital: cap,
      total,
      saldo_final: saldoFinal,
    });
    saldo = saldoFinal;
  }

  const interesTotal = cuotas.reduce((a, c) => a + c.interes, 0);
  const montoFinanciado = capital + interesTotal;

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

/** Cómo se resolvió la simulación: qué dato puso el usuario y cuál dedujo el sistema. */
export type ModoSimulacion = "por_cuota" | "por_cantidad";

export interface Simulacion extends PlanCuotas {
  modo: ModoSimulacion;
  frecuencia: Frecuencia;
  recargo_pct: number;
  cantidad_cuotas: number;
  /** La cuota fija del plan (las primeras n-1). */
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

  let modo: ModoSimulacion;
  let n: number;
  let propuesta: number | null = null;

  if (input.cuotaPropuesta != null && input.cuotaPropuesta > 0) {
    modo = "por_cuota";
    propuesta = Math.round(input.cuotaPropuesta);
    // Sistema francés al revés: dada la cuota, se despeja la cantidad de meses de
    //   Cuota = capital × i / (1 − (1 + i)^(−n))   =>   n = −ln(1 − capital·i/Cuota) / ln(1+i)
    // La cuota tiene que superar el interés del primer período; si no, el saldo
    // nunca baja y el plan sería infinito.
    const i = tasaPeriodica(recargo, frecuencia);
    if (i <= 0) {
      n = Math.max(1, Math.ceil(capital / propuesta));
    } else {
      const interesPrimero = capital * i;
      if (propuesta <= interesPrimero) {
        const minima = Math.ceil(cuotaFrancesa(capital, i, MAX_CUOTAS));
        throw new Error(
          `La cuota de ${propuesta.toLocaleString("es-PY")} no alcanza a cubrir el interés del período ` +
            `(${Math.ceil(interesPrimero).toLocaleString("es-PY")}): el saldo nunca bajaría. ` +
            `La cuota mínima es ${minima.toLocaleString("es-PY")}.`
        );
      }
      n = Math.max(1, Math.ceil(-Math.log(1 - (capital * i) / propuesta) / Math.log(1 + i)));
    }
    if (n > MAX_CUOTAS) {
      const minima = Math.ceil(cuotaFrancesa(capital, i, MAX_CUOTAS));
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
