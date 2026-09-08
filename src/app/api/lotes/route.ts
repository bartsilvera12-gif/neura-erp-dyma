import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { camposLoteDesdeBody } from "@/lib/lotes/lote-campos";
import { manzanaPorCodigo } from "@/lib/lotes/estructura-implicita";
import { ESTADOS_LOTE, type EstadoLote, type Lote, type LotesPayload } from "@/lib/lotes/types";

export const dynamic = "force-dynamic";

/** GET /api/lotes?manzana_id=&loteamiento_id=&estado=&q= */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const url = new URL(request.url);
    const manzanaId = (url.searchParams.get("manzana_id") ?? "").trim();
    const loteamientoId = (url.searchParams.get("loteamiento_id") ?? "").trim();
    const estado = (url.searchParams.get("estado") ?? "").trim();
    const q = (url.searchParams.get("q") ?? "").trim();

    let q1 = sb.from("lotes").select("*").eq("empresa_id", empresaId).order("numero");

    if (manzanaId) {
      q1 = q1.eq("manzana_id", manzanaId);
    } else if (loteamientoId) {
      // Sin manzana concreta se baja por el árbol para acotar al loteamiento.
      const { data: fr } = await sb
        .from("loteamiento_fracciones")
        .select("id")
        .eq("empresa_id", empresaId)
        .eq("loteamiento_id", loteamientoId);
      const fraccionIds = ((fr ?? []) as { id: string }[]).map((f) => f.id);
      if (fraccionIds.length === 0) {
        return NextResponse.json(
          successResponse({
            resumen: { total: 0, disponible: 0, reservado: 0, vendido: 0, bloqueado: 0, superficie_total: 0 },
            lotes: [],
          } satisfies LotesPayload)
        );
      }
      const { data: mz } = await sb
        .from("loteamiento_manzanas")
        .select("id")
        .eq("empresa_id", empresaId)
        .in("fraccion_id", fraccionIds);
      const manzanaIds = ((mz ?? []) as { id: string }[]).map((m) => m.id);
      if (manzanaIds.length === 0) {
        return NextResponse.json(
          successResponse({
            resumen: { total: 0, disponible: 0, reservado: 0, vendido: 0, bloqueado: 0, superficie_total: 0 },
            lotes: [],
          } satisfies LotesPayload)
        );
      }
      q1 = q1.in("manzana_id", manzanaIds);
    }

    if (estado && (ESTADOS_LOTE as string[]).includes(estado)) q1 = q1.eq("estado", estado);
    if (q) q1 = q1.ilike("numero", `%${q}%`);

    const { data, error } = await q1;
    if (error) throw new Error(error.message);
    const filas = (data ?? []) as Record<string, unknown>[];

    // Etiquetas de titular en una sola consulta.
    const clienteIds = [
      ...new Set(filas.map((f) => f.cliente_id).filter((v): v is string => typeof v === "string")),
    ];
    const etiquetas: Record<string, string> = {};
    if (clienteIds.length > 0) {
      const { data: cls } = await sb
        .from("clientes")
        .select("id, empresa, nombre_contacto, nombre")
        .in("id", clienteIds);
      for (const c of (cls ?? []) as Record<string, string | null>[]) {
        if (!c.id) continue;
        etiquetas[c.id] = (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre";
      }
    }

    const lotes: Lote[] = filas.map((f) => ({
      id: String(f.id),
      manzana_id: String(f.manzana_id),
      numero: String(f.numero ?? ""),
      superficie_m2: f.superficie_m2 == null ? null : Number(f.superficie_m2),
      frente_m: f.frente_m == null ? null : Number(f.frente_m),
      fondo_m: f.fondo_m == null ? null : Number(f.fondo_m),
      lindero_norte: (f.lindero_norte as string) ?? null,
      lindero_sur: (f.lindero_sur as string) ?? null,
      lindero_este: (f.lindero_este as string) ?? null,
      lindero_oeste: (f.lindero_oeste as string) ?? null,
      precio_contado: f.precio_contado == null ? null : Number(f.precio_contado),
      precio_financiado: f.precio_financiado == null ? null : Number(f.precio_financiado),
      moneda: f.moneda === "USD" ? "USD" : "GS",
      estado: f.estado as EstadoLote,
      estado_motivo: (f.estado_motivo as string) ?? null,
      cliente_id: (f.cliente_id as string) ?? null,
      cliente_label: f.cliente_id ? etiquetas[String(f.cliente_id)] ?? "Cliente sin nombre" : null,
      observacion: (f.observacion as string) ?? null,
    }));

    const cuenta = (e: EstadoLote) => lotes.filter((l) => l.estado === e).length;
    return NextResponse.json(
      successResponse({
        resumen: {
          total: lotes.length,
          disponible: cuenta("disponible"),
          reservado: cuenta("reservado"),
          vendido: cuenta("vendido"),
          bloqueado: cuenta("bloqueado"),
          superficie_total: lotes.reduce((a, l) => a + (l.superficie_m2 ?? 0), 0),
        },
        lotes,
      } satisfies LotesPayload)
    );
  } catch (e) {
    console.error("[api/lotes GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/** POST /api/lotes — alta de un lote dentro de una manzana. */
export async function POST(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const manzanaIdBody = typeof body.manzana_id === "string" ? body.manzana_id.trim() : "";
  // Alternativa a manzana_id: el código de la manzana dentro de un loteamiento.
  // Es la carga que pidió el cliente —manzana, número y dimensiones de una sola
  // vez— sin tener que ir antes a otra pantalla a dar de alta la manzana.
  const manzanaCodigo = typeof body.manzana_codigo === "string" ? body.manzana_codigo.trim() : "";
  const loteamientoId = typeof body.loteamiento_id === "string" ? body.loteamiento_id.trim() : "";

  const campos = camposLoteDesdeBody(body);
  if (!manzanaIdBody && !(manzanaCodigo && loteamientoId)) {
    return NextResponse.json(
      errorResponse("Falta la manzana: mandá manzana_id, o manzana_codigo junto con loteamiento_id."),
      { status: 400 }
    );
  }
  if (!campos.numero) return NextResponse.json(errorResponse("El número de lote es obligatorio"), { status: 400 });

  try {
    const { sb, empresaId } = auth;
    let manzanaId = manzanaIdBody;

    if (!manzanaId) {
      const { data: lo } = await sb
        .from("loteamientos")
        .select("id")
        .eq("id", loteamientoId)
        .eq("empresa_id", empresaId)
        .maybeSingle();
      if (!lo) return NextResponse.json(errorResponse("Loteamiento no encontrado"), { status: 404 });
      manzanaId = (await manzanaPorCodigo(sb, empresaId, loteamientoId, manzanaCodigo)).id;
    }

    const { data: mz } = await sb
      .from("loteamiento_manzanas")
      .select("id")
      .eq("id", manzanaId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (!mz) return NextResponse.json(errorResponse("Manzana no encontrada"), { status: 404 });

    // Un lote nace siempre disponible; reservar o vender es un cambio de estado aparte.
    const { data, error } = await sb
      .from("lotes")
      .insert({ ...campos, empresa_id: empresaId, manzana_id: manzanaId, estado: "disponible" })
      .select()
      .single();
    if (error) {
      if ((error as { code?: string }).code === "23505") {
        return NextResponse.json(
          errorResponse(`Ya existe el lote "${campos.numero}" en esa manzana.`),
          { status: 409 }
        );
      }
      throw new Error(error.message);
    }
    return NextResponse.json(successResponse(data));
  } catch (e) {
    console.error("[api/lotes POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
