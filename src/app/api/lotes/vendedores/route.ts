import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { pctDesdeFormulario } from "@/lib/vendedores/calculo-comision";
import type { Vendedor } from "@/lib/vendedores/types";

export const dynamic = "force-dynamic";

function aVendedor(row: Record<string, unknown>): Vendedor {
  return {
    id: String(row.id),
    codigo: String(row.codigo ?? ""),
    nombre: String(row.nombre ?? ""),
    documento: (row.documento as string) ?? null,
    telefono: (row.telefono as string) ?? null,
    email: (row.email as string) ?? null,
    comision_pct: Number(row.comision_pct ?? 0),
    activo: row.activo !== false,
    observacion: (row.observacion as string) ?? null,
  };
}

/** GET /api/lotes/vendedores?incluir_inactivos=1 — catálogo de vendedores. */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const url = new URL(request.url);
    const incluirInactivos = url.searchParams.get("incluir_inactivos") === "1";

    let q = sb.from("vendedores").select("*").eq("empresa_id", empresaId).order("nombre");
    if (!incluirInactivos) q = q.eq("activo", true);

    const { data, error } = await q;
    if (error) throw new Error(error.message);

    const vendedores = ((data ?? []) as Record<string, unknown>[]).map(aVendedor);

    // Cuántos contratos tiene cada uno: el listado avisa a quién no se puede borrar.
    if (vendedores.length > 0) {
      const { data: ventas } = await sb
        .from("lote_ventas")
        .select("vendedor_id")
        .eq("empresa_id", empresaId)
        .not("vendedor_id", "is", null);
      const conteo = new Map<string, number>();
      for (const v of (ventas ?? []) as { vendedor_id: string | null }[]) {
        if (!v.vendedor_id) continue;
        conteo.set(v.vendedor_id, (conteo.get(v.vendedor_id) ?? 0) + 1);
      }
      for (const v of vendedores) v.ventas = conteo.get(v.id) ?? 0;
    }

    return NextResponse.json(successResponse({ vendedores }));
  } catch (e) {
    console.error("[api/lotes/vendedores GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/** POST /api/lotes/vendedores — alta de vendedor. */
export async function POST(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const codigo = typeof body.codigo === "string" ? body.codigo.trim() : "";
  const nombre = typeof body.nombre === "string" ? body.nombre.trim() : "";
  if (!codigo) return NextResponse.json(errorResponse("El código del vendedor es obligatorio"), { status: 400 });
  if (!nombre) return NextResponse.json(errorResponse("El nombre del vendedor es obligatorio"), { status: 400 });

  const pct = pctDesdeFormulario(body.comision_pct == null ? 0 : (body.comision_pct as string | number));
  if (pct == null) {
    return NextResponse.json(errorResponse("La comisión debe estar entre 0 y 100%"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;
    const { data, error } = await sb
      .from("vendedores")
      .insert({
        empresa_id: empresaId,
        codigo,
        nombre,
        documento: typeof body.documento === "string" && body.documento.trim() ? body.documento.trim() : null,
        telefono: typeof body.telefono === "string" && body.telefono.trim() ? body.telefono.trim() : null,
        email: typeof body.email === "string" && body.email.trim() ? body.email.trim() : null,
        comision_pct: pct,
        activo: body.activo !== false,
        observacion:
          typeof body.observacion === "string" && body.observacion.trim() ? body.observacion.trim() : null,
      })
      .select()
      .single();

    if (error) {
      if ((error as { code?: string }).code === "23505") {
        return NextResponse.json(
          errorResponse(`Ya hay un vendedor con el código ${codigo}.`),
          { status: 409 }
        );
      }
      throw new Error(error.message);
    }

    return NextResponse.json(successResponse({ vendedor: aVendedor(data as Record<string, unknown>) }));
  } catch (e) {
    console.error("[api/lotes/vendedores POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
