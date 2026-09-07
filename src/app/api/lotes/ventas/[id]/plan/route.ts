import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { cargarDatosContrato } from "@/lib/contratos/cargar-datos";
import { plantillaPlanPago, type EstadoCuotaPlan } from "@/lib/contratos/plantilla-plan-pago";

export const dynamic = "force-dynamic";

/**
 * GET /api/lotes/ventas/[id]/plan?auto=1
 *
 * Plan de pago como documento suelto. El mismo cuadro va como anexo del
 * contrato, pero el negocio lo entrega aparte: es lo que el comprador se lleva
 * para tener sus vencimientos sin las diecisiete cláusulas encima.
 *
 * Muestra el estado real de cada cuota, así sirve de estado del plan a la fecha
 * y no solo de cronograma inicial.
 */
export async function GET(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return new NextResponse(auth.message, { status: auth.status });

  const { id } = await ctx.params;
  const auto = new URL(request.url).searchParams.get("auto") === "1";

  try {
    const { sb, empresaId } = auth;
    const datos = await cargarDatosContrato(sb, empresaId, id);
    if (!datos) return new NextResponse("Contrato no encontrado", { status: 404 });

    const { data } = await sb
      .from("lote_venta_cuotas")
      .select("numero, saldo, estado")
      .eq("venta_id", id)
      .eq("empresa_id", empresaId)
      .order("numero");

    const estados: EstadoCuotaPlan[] = ((data ?? []) as Record<string, unknown>[]).map((c) => ({
      numero: Number(c.numero ?? 0),
      saldo: Number(c.saldo ?? 0),
      pagada: c.estado === "pagada",
    }));

    const html = plantillaPlanPago(datos, estados, { autoImprimir: auto });
    return new NextResponse(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  } catch (e) {
    console.error("[api/lotes/ventas/[id]/plan GET]", e instanceof Error ? e.message : e);
    return new NextResponse("No se pudo generar el plan de pago", { status: 500 });
  }
}
