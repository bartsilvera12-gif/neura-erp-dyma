import { NextResponse } from "next/server";
import { requireReportesModuleAccess } from "@/lib/reportes/reportes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { cargarEstadoResultado } from "@/lib/reportes/estado-resultado-datos";
import { rangoDelMes, validarRango, type BaseReporte } from "@/lib/reportes/estado-resultado";
import { hoyAsuncion } from "@/lib/reportes/calculo";

export const dynamic = "force-dynamic";

/**
 * GET /api/reportes/estado-resultado?desde=&hasta=&base=percibido|devengado
 *
 * También acepta `mes=AAAA-MM`, que es como se pide casi siempre; sin
 * parámetros devuelve el mes en curso.
 */
export async function GET(request: Request) {
  const auth = await requireReportesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const url = new URL(request.url);
    const base: BaseReporte = url.searchParams.get("base") === "devengado" ? "devengado" : "percibido";
    const mes = url.searchParams.get("mes") ?? "";

    let desde = url.searchParams.get("desde") ?? "";
    let hasta = url.searchParams.get("hasta") ?? "";
    if (!desde || !hasta) {
      const r = rangoDelMes(/^\d{4}-\d{2}/.test(mes) ? mes : hoyAsuncion());
      desde = r.desde;
      hasta = r.hasta;
    }

    const v = validarRango(desde, hasta);
    if (!v.ok) return NextResponse.json(errorResponse(v.error), { status: 400 });

    const data = await cargarEstadoResultado(auth.sb, auth.empresaId, desde, hasta, base);
    return NextResponse.json(successResponse(data));
  } catch (e) {
    console.error("[api/reportes/estado-resultado GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
