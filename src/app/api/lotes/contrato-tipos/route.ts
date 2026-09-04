import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import type { ContratoTipo } from "@/lib/contratos/types";

export const dynamic = "force-dynamic";

/**
 * GET /api/lotes/contrato-tipos — catálogo de tipos de contrato.
 *
 * Es data-driven a propósito: el cliente todavía tiene que confirmar la lista
 * completa, y sumar un tipo debe ser insertar una fila, no tocar código.
 */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const { data, error } = await sb
      .from("contrato_tipos")
      .select("*")
      .eq("empresa_id", empresaId)
      .eq("activo", true)
      .order("orden");
    if (error) throw new Error(error.message);

    const tipos: ContratoTipo[] = ((data ?? []) as Record<string, unknown>[]).map((t) => ({
      id: String(t.id),
      slug: String(t.slug),
      nombre: String(t.nombre),
      descripcion: (t.descripcion as string) ?? null,
      requiere_conyuge: t.requiere_conyuge === true,
      requiere_codeudor: t.requiere_codeudor === true,
      plantilla: String(t.plantilla ?? "compraventa_plazos"),
      activo: t.activo !== false,
    }));

    return NextResponse.json(successResponse({ tipos }));
  } catch (e) {
    console.error("[api/lotes/contrato-tipos GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
