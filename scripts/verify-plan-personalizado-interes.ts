/**
 * Verificación del plan personalizado CON interés:
 *  - el cronograma generado, al partirse en capital/interés, cierra el saldo en 0;
 *  - Σ capital = capital financiado, Σ total = monto financiado;
 *  - cada cuota (menos la última) amortiza (capital > 0);
 *  - la cuota demasiado chica corta con error.
 */
import {
  generarCronogramaMensualConInteres,
  generarPlanPersonalizadoConInteres,
  RECARGO_FINANCIACION,
} from "../src/lib/financiacion/plan-cuotas";

let fallos = 0;
function check(nombre: string, cond: boolean, extra?: unknown) {
  if (cond) {
    console.log(`  ok  ${nombre}`);
  } else {
    fallos += 1;
    console.error(`FALLO  ${nombre}`, extra ?? "");
  }
}

function fmt(n: number) {
  return `Gs. ${Math.round(n).toLocaleString("es-PY")}`;
}

function corre(titulo: string, opts: {
  precio: number;
  entrega: number;
  mensual: number;
  primer: string;
  fechaVenta: string;
  refuerzos?: { vencimiento: string; monto: number }[];
}) {
  console.log(`\n### ${titulo}`);
  const capital = opts.precio - opts.entrega;
  const pagos = generarCronogramaMensualConInteres({
    capital,
    montoMensual: opts.mensual,
    primerVencimiento: opts.primer,
    fechaVenta: opts.fechaVenta,
    refuerzos: opts.refuerzos,
    recargo: RECARGO_FINANCIACION,
  });
  const plan = generarPlanPersonalizadoConInteres({
    precioContado: opts.precio,
    entregaInicial: opts.entrega,
    cuotas: pagos,
    fechaVenta: opts.fechaVenta,
    recargo: RECARGO_FINANCIACION,
  });

  const sumaCapital = plan.cuotas.reduce((a, c) => a + c.capital, 0);
  const sumaTotal = plan.cuotas.reduce((a, c) => a + c.total, 0);
  const ultima = plan.cuotas[plan.cuotas.length - 1]!;
  const noUltimas = plan.cuotas.slice(0, -1);

  console.log(
    `  saldo financiado ${fmt(capital)} | cuotas ${plan.cuotas.length} | ` +
      `interés total ${fmt(plan.interes_total)} | total a pagar ${fmt(plan.monto_financiado)}`
  );
  console.log(
    `  cuota 1 ${fmt(plan.cuotas[0]!.total)} (cap ${fmt(plan.cuotas[0]!.capital)} + int ${fmt(plan.cuotas[0]!.interes)}) ` +
      `| última ${fmt(ultima.total)}`
  );

  check("saldo final = 0", ultima.saldo_final === 0, ultima.saldo_final);
  check("Σ capital = capital financiado", sumaCapital === capital, { sumaCapital, capital });
  check("Σ total = monto financiado", sumaTotal === plan.monto_financiado, { sumaTotal, mf: plan.monto_financiado });
  check("monto financiado = capital + interés", plan.monto_financiado === capital + plan.interes_total);
  check("interés total > 0 (hay recargo)", plan.interes_total > 0, plan.interes_total);
  check("todas las cuotas menos la última amortizan (capital > 0)", noUltimas.every((c) => c.capital > 0));
  check("interés de cada cuota ≥ 0", plan.cuotas.every((c) => c.interes >= 0));
  check("saldos encadenan (saldo_final[k] = saldo_inicial[k+1])",
    plan.cuotas.every((c, i) => i === 0 || c.saldo_inicial === plan.cuotas[i - 1]!.saldo_final));
}

// Caso del cliente: 175M, entrega 20M, cuota 2.000.000, un refuerzo anual.
corre("175M · entrega 20M · cuota 2.000.000 · 1 refuerzo 10M", {
  precio: 175_000_000,
  entrega: 20_000_000,
  mensual: 2_000_000,
  primer: "2026-11-13",
  fechaVenta: "2026-10-13",
  refuerzos: [{ vencimiento: "2027-11-13", monto: 10_000_000 }],
});

// Sin refuerzos, cuota más alta.
corre("175M · entrega 20M · cuota 3.000.000 · sin refuerzos", {
  precio: 175_000_000,
  entrega: 20_000_000,
  mensual: 3_000_000,
  primer: "2026-11-13",
  fechaVenta: "2026-10-13",
});

// Varios refuerzos.
corre("175M · entrega 20M · cuota 2.500.000 · 3 refuerzos", {
  precio: 175_000_000,
  entrega: 20_000_000,
  mensual: 2_500_000,
  primer: "2026-11-13",
  fechaVenta: "2026-10-13",
  refuerzos: [
    { vencimiento: "2027-12-01", monto: 15_000_000 },
    { vencimiento: "2028-12-01", monto: 15_000_000 },
    { vencimiento: "2029-12-01", monto: 15_000_000 },
  ],
});

// La cuota chica (1.800.000) debe cortar con error "no cubre el interés".
console.log("\n### cuota 1.800.000 (demasiado chica) debe tirar error");
try {
  generarCronogramaMensualConInteres({
    capital: 155_000_000,
    montoMensual: 1_800_000,
    primerVencimiento: "2026-11-13",
    fechaVenta: "2026-10-13",
    recargo: RECARGO_FINANCIACION,
  });
  check("tiró error con cuota chica", false, "no tiró");
} catch (e) {
  console.log(`  mensaje: ${e instanceof Error ? e.message : e}`);
  check("tiró error con cuota chica", true);
}

console.log(fallos === 0 ? "\n✅ TODO OK" : `\n❌ ${fallos} fallo(s)`);
process.exit(fallos === 0 ? 0 : 1);
