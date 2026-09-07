import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { calcularMoraCuota, DIAS_GRACIA } from "@/lib/financiacion/plan-cuotas";
import { hoyAsuncion } from "@/lib/reportes/calculo";
import { toCalendarDateStr } from "@/lib/fechas/calendario";
import type { PanelLotes } from "@/lib/lotes/panel-types";

export const dynamic = "force-dynamic";

/** Primer y último día del mes de `hoy`. */
function mesDe(hoy: string): { desde: string; hasta: string } {
  const [y, m] = hoy.split("-").map(Number);
  const ultimo = new Date(Date.UTC(y!, m!, 0)).getUTCDate();
  const p = (n: number) => String(n).padStart(2, "0");
  return { desde: `${y}-${p(m!)}-01`, hasta: `${y}-${p(m!)}-${p(ultimo)}` };
}

/**
 * GET /api/lotes/panel — resumen del negocio de loteamiento para el dashboard.
 *
 * Reúne en una sola llamada lo que el dueño mira primero: cuántos lotes hay y en
 * qué estado, cuánto vale lo que queda por vender, y cómo viene la cobranza de
 * lo ya vendido. La mora se calcula al vuelo, nunca se persiste.
 */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const hoy = hoyAsuncion();
    const mes = mesDe(hoy);

    const [lotesRes, ventasRes, cuotasRes] = await Promise.all([
      sb.from("lotes").select("id, estado, superficie_m2, precio_contado").eq("empresa_id", empresaId),
      sb.from("lote_ventas").select("id, estado, dias_gracia, monto_financiado").eq("empresa_id", empresaId),
      sb
        .from("lote_venta_cuotas")
        .select("id, venta_id, total, saldo, estado, vencimiento, factura_id")
        .eq("empresa_id", empresaId),
    ]);
    if (lotesRes.error) throw new Error(lotesRes.error.message);

    const lotes = (lotesRes.data ?? []) as Record<string, unknown>[];
    const ventas = (ventasRes.data ?? []) as Record<string, unknown>[];
    const cuotas = (cuotasRes.data ?? []) as Record<string, unknown>[];

    const porEstado = (e: string) => lotes.filter((l) => l.estado === e).length;
    const disponibles = lotes.filter((l) => l.estado === "disponible");

    const graciaPorVenta = new Map<string, number>();
    for (const v of ventas) graciaPorVenta.set(String(v.id), Number(v.dias_gracia ?? DIAS_GRACIA));

    const pendientes = cuotas.filter((c) => c.estado === "pendiente");
    let saldoPorCobrar = 0;
    let moraAcumulada = 0;
    let cuotasVencidas = 0;
    let venceEnTreinta = 0;
    const en30 = new Date(Date.parse(`${hoy}T00:00:00Z`) + 30 * 86_400_000).toISOString().slice(0, 10);

    for (const c of pendientes) {
      const saldo = Number(c.saldo ?? 0);
      const venc = toCalendarDateStr(String(c.vencimiento ?? ""));
      saldoPorCobrar += saldo;
      const m = calcularMoraCuota({
        montoCuota: saldo,
        vencimiento: venc,
        hoy,
        diasGracia: graciaPorVenta.get(String(c.venta_id)) ?? DIAS_GRACIA,
      });
      moraAcumulada += m.total;
      if (m.dias_atraso > 0) cuotasVencidas += 1;
      else if (venc && venc <= en30) venceEnTreinta += saldo;
    }

    // Cobrado del mes: los pagos imputados a las facturas de las cuotas.
    const facturaIds = [...new Set(cuotas.map((c) => (c.factura_id ? String(c.factura_id) : "")).filter(Boolean))];
    let cobradoMes = 0;
    let cobrosMes = 0;
    for (let i = 0; i < facturaIds.length; i += 120) {
      const slice = facturaIds.slice(i, i + 120);
      if (slice.length === 0) break;
      const { data } = await sb
        .from("pagos")
        .select("monto")
        .eq("empresa_id", empresaId)
        .in("factura_id", slice)
        .gte("fecha_pago", mes.desde)
        .lte("fecha_pago", mes.hasta);
      for (const p of (data ?? []) as { monto?: number }[]) {
        cobradoMes += Number(p.monto ?? 0);
        cobrosMes += 1;
      }
    }

    const payload: PanelLotes = {
      hoy,
      lotes: {
        total: lotes.length,
        disponible: porEstado("disponible"),
        reservado: porEstado("reservado"),
        vendido: porEstado("vendido"),
        bloqueado: porEstado("bloqueado"),
        superficie_total: lotes.reduce((a, l) => a + Number(l.superficie_m2 ?? 0), 0),
        // Lo que todavía se puede vender, a precio de lista.
        valor_disponible: disponibles.reduce((a, l) => a + Number(l.precio_contado ?? 0), 0),
      },
      contratos: {
        vigentes: ventas.filter((v) => v.estado === "vigente").length,
        cancelados: ventas.filter((v) => v.estado === "cancelada").length,
        anulados: ventas.filter((v) => v.estado === "anulada").length,
        financiado_total: ventas
          .filter((v) => v.estado !== "anulada")
          .reduce((a, v) => a + Number(v.monto_financiado ?? 0), 0),
      },
      cartera: {
        saldo_por_cobrar: saldoPorCobrar,
        mora_acumulada: moraAcumulada,
        cuotas_pendientes: pendientes.length,
        cuotas_vencidas: cuotasVencidas,
        vence_en_30_dias: venceEnTreinta,
        cobrado_mes: cobradoMes,
        cobros_mes: cobrosMes,
      },
    };

    return NextResponse.json(successResponse(payload));
  } catch (e) {
    console.error("[api/lotes/panel GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
