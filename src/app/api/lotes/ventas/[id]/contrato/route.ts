import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { cargarDatosContrato } from "@/lib/contratos/cargar-datos";
import { plantillaCompraventaPlazos } from "@/lib/contratos/plantilla-compraventa";

export const dynamic = "force-dynamic";

/**
 * GET /api/lotes/ventas/[id]/contrato?auto=1
 *
 * Documento del contrato, listo para imprimir o guardar como PDF. Se arma en el
 * momento con los datos vigentes; no se guarda una copia. Lo que fija las
 * condiciones económicas es el contrato en la base, y de ahí sale el documento.
 */
export async function GET(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return new NextResponse(auth.message, { status: auth.status });

  const { id } = await ctx.params;
  const auto = new URL(request.url).searchParams.get("auto") === "1";

  try {
    const datos = await cargarDatosContrato(auth.sb, auth.empresaId, id);
    if (!datos) return new NextResponse("Contrato no encontrado", { status: 404 });

    const html = plantillaCompraventaPlazos(datos, { autoImprimir: auto });
    return new NextResponse(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  } catch (e) {
    console.error("[api/lotes/ventas/[id]/contrato GET]", e instanceof Error ? e.message : e);
    return new NextResponse("No se pudo generar el contrato", { status: 500 });
  }
}
