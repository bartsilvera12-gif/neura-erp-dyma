import { NextResponse } from "next/server";
import { requireReportesModuleAccess } from "@/lib/reportes/reportes-auth";
import { logoIncrustado } from "@/lib/contratos/cargar-datos";
import { cargarEstadoResultado } from "@/lib/reportes/estado-resultado-datos";
import { rangoDelMes, validarRango, type BaseReporte } from "@/lib/reportes/estado-resultado";
import { plantillaEstadoResultado } from "@/lib/reportes/plantilla-estado-resultado";
import { hoyAsuncion } from "@/lib/reportes/calculo";

export const dynamic = "force-dynamic";

/**
 * GET /api/reportes/estado-resultado/imprimir?desde=&hasta=&base=&auto=1
 *
 * El mismo reporte, con el formato del modelo del cliente y listo para el papel.
 */
export async function GET(request: Request) {
  const auth = await requireReportesModuleAccess(request);
  if (!auth.ok) return new NextResponse(auth.message, { status: auth.status });

  try {
    const url = new URL(request.url);
    const base: BaseReporte = url.searchParams.get("base") === "devengado" ? "devengado" : "percibido";
    const auto = url.searchParams.get("auto") === "1";
    const mes = url.searchParams.get("mes") ?? "";

    let desde = url.searchParams.get("desde") ?? "";
    let hasta = url.searchParams.get("hasta") ?? "";
    if (!desde || !hasta) {
      const r = rangoDelMes(/^\d{4}-\d{2}/.test(mes) ? mes : hoyAsuncion());
      desde = r.desde;
      hasta = r.hasta;
    }

    const v = validarRango(desde, hasta);
    if (!v.ok) return new NextResponse(v.error, { status: 400 });

    const { data: cfgRow } = await auth.sb
      .from("contrato_config")
      .select("razon_social, ruc")
      .eq("empresa_id", auth.empresaId)
      .maybeSingle();
    const cfg = (cfgRow ?? null) as { razon_social?: string; ruc?: string } | null;

    const reporte = await cargarEstadoResultado(auth.sb, auth.empresaId, desde, hasta, base);
    const html = plantillaEstadoResultado(
      {
        razon_social: cfg?.razon_social || "CORPORACION DYMA S.A.",
        ruc: cfg?.ruc ?? null,
        logoUrl: logoIncrustado(),
        emitido: hoyAsuncion(),
        reporte,
      },
      { autoImprimir: auto }
    );

    return new NextResponse(html, { status: 200, headers: { "Content-Type": "text/html; charset=utf-8" } });
  } catch (e) {
    console.error("[api/reportes/estado-resultado/imprimir GET]", e instanceof Error ? e.message : e);
    return new NextResponse("No se pudo generar el estado de resultado", { status: 500 });
  }
}
