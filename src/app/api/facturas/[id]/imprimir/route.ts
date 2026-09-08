import { NextRequest, NextResponse } from "next/server";
import { getFacturasSupabaseFromAuth } from "@/lib/facturacion/facturas-service-client";
import { cargarFactura } from "@/lib/facturas/cargar-factura";
import { plantillaFactura } from "@/lib/facturas/plantilla-factura";

export const dynamic = "force-dynamic";

/**
 * GET /api/facturas/[id]/imprimir?auto=1
 *
 * La factura lista para el papel, en media hoja (8,5" x 5,5") y por triplicado.
 *
 * Solo dibuja: el número fiscal se asigna en `POST .../emitir`. Si la factura
 * todavía no se emitió, sale rotulada "SIN NUMERAR" con el aviso arriba, así
 * nadie la entrega por error creyendo que es válida.
 */
export async function GET(request: NextRequest, ctx: { params: Promise<{ id: string }> }) {
  const auth = await getFacturasSupabaseFromAuth(request);
  if (!auth) return new NextResponse("No autorizado", { status: 401 });

  const { id } = await ctx.params;
  const auto = new URL(request.url).searchParams.get("auto") === "1";

  try {
    const cargada = await cargarFactura(auth.supabase, auth.auth.empresa_id, id);
    if (!cargada) return new NextResponse("Factura no encontrada", { status: 404 });

    return new NextResponse(plantillaFactura(cargada.datos, { autoImprimir: auto }), {
      status: 200,
      headers: { "Content-Type": "text/html; charset=utf-8" },
    });
  } catch (e) {
    console.error("[api/facturas/[id]/imprimir GET]", e instanceof Error ? e.message : e);
    return new NextResponse("No se pudo generar la factura", { status: 500 });
  }
}
