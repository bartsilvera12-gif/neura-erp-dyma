import { NextResponse } from "next/server";
import { requireLimpiezaModuleAccess } from "@/lib/limpieza/limpieza-auth";
import { borrarFacturaLimpiezaSiNoTienePagos } from "@/lib/limpieza/limpieza-factura";
import { getFacturasServiceClientForEmpresa } from "@/lib/facturacion/facturas-service-client";
import { errorResponse, successResponse } from "@/lib/api/response";

export const dynamic = "force-dynamic";

/**
 * DELETE /api/limpieza/[id] — anula un servicio cargado por error.
 *
 * Se niega si la factura ya tiene cobros: en ese caso el saldo se movió y la
 * corrección corresponde al circuito de Facturas (anulación / nota de crédito),
 * no a borrar el registro por atrás.
 */
export async function DELETE(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLimpiezaModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const { id } = await ctx.params;
  if (!id?.trim()) return NextResponse.json(errorResponse("id requerido"), { status: 400 });

  try {
    const sb = await getFacturasServiceClientForEmpresa(auth.empresaId);

    const { data: servicio, error: errGet } = await sb
      .from("servicios_limpieza")
      .select("id, factura_id")
      .eq("id", id)
      .eq("empresa_id", auth.empresaId)
      .maybeSingle();
    if (errGet) throw new Error(errGet.message);
    if (!servicio) return NextResponse.json(errorResponse("Servicio no encontrado"), { status: 404 });

    const facturaId = (servicio as { factura_id: string | null }).factura_id;
    if (facturaId) {
      const borrada = await borrarFacturaLimpiezaSiNoTienePagos(sb, auth.empresaId, facturaId);
      if (!borrada) {
        return NextResponse.json(
          errorResponse(
            "La factura de este servicio ya tiene cobros registrados. Anulala o emití una nota de crédito desde Facturas."
          ),
          { status: 409 }
        );
      }
    }

    const { error } = await sb
      .from("servicios_limpieza")
      .delete()
      .eq("id", id)
      .eq("empresa_id", auth.empresaId);
    if (error) throw new Error(error.message);

    return NextResponse.json(successResponse({ ok: true, id }));
  } catch (e) {
    console.error("[api/limpieza DELETE]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
