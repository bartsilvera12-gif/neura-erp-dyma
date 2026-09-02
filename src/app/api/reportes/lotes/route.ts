import { NextResponse } from "next/server";
import { requireReportesModuleAccess } from "@/lib/reportes/reportes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import type { FilaFraccion, ReporteLotesPayload } from "@/lib/reportes/types";

export const dynamic = "force-dynamic";

/**
 * GET /api/reportes/lotes?loteamiento_id=
 * Vendidos vs. disponibles por fracción, con superficie y valorización de lista.
 *
 * La valorización usa `precio_contado` como referencia: es el precio de lista con
 * el que se compara, no lo efectivamente pactado en cada venta (eso vive en el
 * contrato, que es fase 2).
 */
export async function GET(request: Request) {
  const auth = await requireReportesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const loteamientoId = (new URL(request.url).searchParams.get("loteamiento_id") ?? "").trim();

    const [lotRes, fraRes, mzRes, lotesRes] = await Promise.all([
      sb.from("loteamientos").select("id, codigo, nombre").eq("empresa_id", empresaId),
      sb.from("loteamiento_fracciones").select("id, loteamiento_id, codigo, nombre, orden").eq("empresa_id", empresaId),
      sb.from("loteamiento_manzanas").select("id, fraccion_id").eq("empresa_id", empresaId),
      sb
        .from("lotes")
        .select("id, manzana_id, estado, superficie_m2, precio_contado, moneda")
        .eq("empresa_id", empresaId),
    ]);
    for (const r of [lotRes, fraRes, mzRes, lotesRes]) {
      if (r.error) throw new Error(r.error.message);
    }

    type Lo = { id: string; codigo: string; nombre: string };
    type Fr = { id: string; loteamiento_id: string; codigo: string; nombre: string | null; orden: number };
    type Mz = { id: string; fraccion_id: string };
    type Lt = {
      id: string;
      manzana_id: string;
      estado: string;
      superficie_m2: number | string | null;
      precio_contado: number | string | null;
      moneda: string;
    };

    const loteamientos = (lotRes.data ?? []) as Lo[];
    let fracciones = (fraRes.data ?? []) as Fr[];
    const manzanas = (mzRes.data ?? []) as Mz[];
    const lotes = (lotesRes.data ?? []) as Lt[];

    if (loteamientoId) fracciones = fracciones.filter((f) => f.loteamiento_id === loteamientoId);

    const loteamientoPorId = new Map(loteamientos.map((l) => [l.id, l]));
    const fraccionPorId = new Map(fracciones.map((f) => [f.id, f]));
    // Manzana → fracción, para poder subir cada lote hasta su fracción.
    const fraccionDeManzana = new Map(manzanas.map((m) => [m.id, m.fraccion_id]));

    const filas = new Map<string, FilaFraccion>();
    for (const f of fracciones) {
      const lo = loteamientoPorId.get(f.loteamiento_id);
      filas.set(f.id, {
        loteamiento_id: f.loteamiento_id,
        loteamiento: lo ? `${lo.codigo} — ${lo.nombre}` : "—",
        fraccion_id: f.id,
        fraccion: f.nombre ? `${f.codigo} — ${f.nombre}` : f.codigo,
        total: 0,
        disponible: 0,
        reservado: 0,
        vendido: 0,
        bloqueado: 0,
        superficie_total: 0,
        vendido_gs: 0,
        vendido_usd: 0,
        disponible_gs: 0,
        disponible_usd: 0,
      });
    }

    for (const l of lotes) {
      const fraccionId = fraccionDeManzana.get(l.manzana_id);
      if (!fraccionId || !fraccionPorId.has(fraccionId)) continue;
      const fila = filas.get(fraccionId);
      if (!fila) continue;

      fila.total += 1;
      fila.superficie_total += Number(l.superficie_m2 ?? 0);
      const estado = l.estado as keyof Pick<FilaFraccion, "disponible" | "reservado" | "vendido" | "bloqueado">;
      if (estado in fila) fila[estado] += 1;

      const precio = Number(l.precio_contado ?? 0);
      const usd = l.moneda === "USD";
      if (l.estado === "vendido") {
        if (usd) fila.vendido_usd += precio;
        else fila.vendido_gs += precio;
      } else if (l.estado === "disponible") {
        if (usd) fila.disponible_usd += precio;
        else fila.disponible_gs += precio;
      }
    }

    const ordenFraccion = new Map(fracciones.map((f) => [f.id, f.orden]));
    const lista = [...filas.values()].sort(
      (a, b) =>
        a.loteamiento.localeCompare(b.loteamiento) ||
        (ordenFraccion.get(a.fraccion_id) ?? 0) - (ordenFraccion.get(b.fraccion_id) ?? 0) ||
        a.fraccion.localeCompare(b.fraccion)
    );

    const sum = (k: keyof FilaFraccion) => lista.reduce((a, f) => a + (f[k] as number), 0);
    const payload: ReporteLotesPayload = {
      fracciones: lista,
      totales: {
        total: sum("total"),
        disponible: sum("disponible"),
        reservado: sum("reservado"),
        vendido: sum("vendido"),
        bloqueado: sum("bloqueado"),
        superficie_total: sum("superficie_total"),
        vendido_gs: sum("vendido_gs"),
        vendido_usd: sum("vendido_usd"),
        disponible_gs: sum("disponible_gs"),
        disponible_usd: sum("disponible_usd"),
      },
    };
    return NextResponse.json(successResponse(payload));
  } catch (e) {
    console.error("[api/reportes/lotes GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
