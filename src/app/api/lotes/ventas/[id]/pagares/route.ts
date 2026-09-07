import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { cargarDatosContrato } from "@/lib/contratos/cargar-datos";
import { generarPagares } from "@/lib/contratos/pagares";
import { plantillaPagares } from "@/lib/contratos/plantilla-pagares";

export const dynamic = "force-dynamic";

/**
 * GET /api/lotes/ventas/[id]/pagares?auto=1&meses=12
 *
 * Pagarés a la orden del contrato, uno por hoja. Por defecto anuales, que es lo
 * que pidió el negocio: en un plan a cinco años son 5 documentos en vez de 60.
 * `meses` permite otro agrupamiento (6 = semestral) sin tocar código.
 *
 * Se arman en el momento a partir del plan de cuotas real, igual que el
 * contrato: los dos documentos tienen que decir exactamente lo mismo.
 */
export async function GET(request: Request, ctx: { params: Promise<{ id: string }> }) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return new NextResponse(auth.message, { status: auth.status });

  const { id } = await ctx.params;
  const url = new URL(request.url);
  const auto = url.searchParams.get("auto") === "1";
  const mesesRaw = Number(url.searchParams.get("meses"));
  const meses = Number.isFinite(mesesRaw) && mesesRaw >= 1 ? Math.trunc(mesesRaw) : 12;

  try {
    const datos = await cargarDatosContrato(auth.sb, auth.empresaId, id);
    if (!datos) return new NextResponse("Contrato no encontrado", { status: 404 });

    const pagares = generarPagares(datos.operacion.numero_contrato, datos.cuotas, meses);
    const html = plantillaPagares(datos, pagares, { autoImprimir: auto });
    return new NextResponse(html, {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  } catch (e) {
    console.error("[api/lotes/ventas/[id]/pagares GET]", e instanceof Error ? e.message : e);
    return new NextResponse("No se pudieron generar los pagarés", { status: 500 });
  }
}
