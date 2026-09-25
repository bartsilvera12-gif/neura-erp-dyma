import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/**
 * PATCH /api/lotes/cuotas/[id] — reprograma el vencimiento de una sola cuota.
 *
 * Cambia la fecha de una cuota puntual sin tocar el resto del plan. El atraso, la
 * mora y el "a pagar" se calculan al vuelo desde el vencimiento cada vez que se
 * lee la cuota, así que con guardar la fecha nueva ya quedan recalculados; el
 * estado (pendiente/pagada) no depende de la fecha y no se toca.
 *
 * Solo se reprograma una cuota PENDIENTE de un contrato VIGENTE: una cuota ya
 * cobrada o anulada no se mueve, porque su fecha ya quedó en la factura y en el
 * cobro.
 */
export async function PATCH(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const vencimiento = typeof body.vencimiento === "string" ? body.vencimiento.trim() : "";
  if (!FECHA_RE.test(vencimiento)) {
    return NextResponse.json(errorResponse("Fecha de vencimiento inválida"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;

    const { data: cuota, error: errCuota } = await sb
      .from("lote_venta_cuotas")
      .select("id, estado, venta_id, numero, vencimiento")
      .eq("id", id)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errCuota) throw new Error(errCuota.message);
    if (!cuota) return NextResponse.json(errorResponse("Cuota no encontrada"), { status: 404 });

    const c = cuota as Record<string, unknown>;
    if (c.estado !== "pendiente") {
      return NextResponse.json(
        errorResponse("Solo se puede reprogramar una cuota pendiente."),
        { status: 409 }
      );
    }

    const { data: venta, error: errVenta } = await sb
      .from("lote_ventas")
      .select("estado")
      .eq("id", String(c.venta_id))
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errVenta) throw new Error(errVenta.message);
    if (!venta || (venta as { estado?: string }).estado !== "vigente") {
      return NextResponse.json(errorResponse("El contrato no está vigente."), { status: 409 });
    }

    const { error: errUpd } = await sb
      .from("lote_venta_cuotas")
      .update({ vencimiento })
      .eq("id", id)
      .eq("empresa_id", empresaId);
    if (errUpd) throw new Error(`No se pudo reprogramar la cuota: ${errUpd.message}`);

    return NextResponse.json(
      successResponse({ ok: true, cuota_id: id, numero: Number(c.numero), vencimiento })
    );
  } catch (e) {
    console.error("[api/lotes/cuotas/[id] PATCH]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
