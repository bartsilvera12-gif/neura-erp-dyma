import { NextResponse } from "next/server";
import { requireLotesModuleAccess } from "@/lib/lotes/lotes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { esFrecuencia, simularPlan, type Frecuencia } from "@/lib/financiacion/plan-cuotas";
import type { SimulacionGuardada } from "@/lib/financiacion/simulaciones";
import { aSimulacionGuardada } from "@/lib/financiacion/simulaciones";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/** GET /api/lotes/simulaciones?cliente_id=&lote_id=&estado= — historial de propuestas. */
export async function GET(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const url = new URL(request.url);
    const clienteId = (url.searchParams.get("cliente_id") ?? "").trim();
    const loteId = (url.searchParams.get("lote_id") ?? "").trim();
    const estado = (url.searchParams.get("estado") ?? "").trim();

    let q = sb
      .from("plan_simulaciones")
      .select("*")
      .eq("empresa_id", empresaId)
      .order("created_at", { ascending: false })
      .limit(200);
    if (clienteId) q = q.eq("cliente_id", clienteId);
    if (loteId) q = q.eq("lote_id", loteId);
    if (estado) q = q.eq("estado", estado);

    const { data, error } = await q;
    if (error) throw new Error(error.message);

    const filas = (data ?? []) as Record<string, unknown>[];
    const simulaciones = filas.map(aSimulacionGuardada);

    // Etiquetas de cliente y lote, para que el historial se lea sin abrir cada fila.
    const clienteIds = [...new Set(simulaciones.map((s) => s.cliente_id).filter((v): v is string => !!v))];
    const loteIds = [...new Set(simulaciones.map((s) => s.lote_id).filter((v): v is string => !!v))];

    const [clientesRes, lotesRes] = await Promise.all([
      clienteIds.length
        ? sb.from("clientes").select("id, empresa, nombre_contacto, nombre").in("id", clienteIds)
        : Promise.resolve({ data: [] }),
      loteIds.length ? sb.from("lotes").select("id, numero").in("id", loteIds) : Promise.resolve({ data: [] }),
    ]);

    const etiquetaCliente = new Map<string, string>();
    for (const c of (clientesRes.data ?? []) as Record<string, string | null>[]) {
      if (!c.id) continue;
      etiquetaCliente.set(
        c.id,
        (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre"
      );
    }
    const etiquetaLote = new Map<string, string>();
    for (const l of (lotesRes.data ?? []) as Record<string, string>[]) {
      etiquetaLote.set(l.id, `Lote ${l.numero}`);
    }

    for (const s of simulaciones) {
      s.cliente_label = s.cliente_id ? (etiquetaCliente.get(s.cliente_id) ?? null) : null;
      s.lote_label = s.lote_id ? (etiquetaLote.get(s.lote_id) ?? null) : null;
    }

    return NextResponse.json(successResponse({ simulaciones }));
  } catch (e) {
    console.error("[api/lotes/simulaciones GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}

/**
 * POST /api/lotes/simulaciones — guarda una propuesta en el historial.
 *
 * El resultado se recalcula acá, no se confía en lo que mandó el navegador: la
 * fila guardada es lo que se le prometió al cliente y tiene que ser coherente.
 */
export async function POST(request: Request) {
  const auth = await requireLotesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  let body: Record<string, unknown>;
  try {
    body = (await request.json()) as Record<string, unknown>;
  } catch {
    return NextResponse.json(errorResponse("Body JSON inválido"), { status: 400 });
  }

  const primerVencimiento = typeof body.primer_vencimiento === "string" ? body.primer_vencimiento.trim() : "";
  if (!FECHA_RE.test(primerVencimiento)) {
    return NextResponse.json(errorResponse("Fecha de inicio de las cuotas inválida"), { status: 400 });
  }
  const frecuencia: Frecuencia = esFrecuencia(body.frecuencia) ? body.frecuencia : "mensual";

  let plan;
  try {
    plan = simularPlan({
      precioContado: Number(body.precio_contado),
      entregaInicial: Number(body.entrega_inicial ?? 0),
      primerVencimiento,
      frecuencia,
      recargo: body.recargo_pct == null ? undefined : Number(body.recargo_pct),
      cantidadCuotas: body.cantidad_cuotas == null ? undefined : Number(body.cantidad_cuotas),
      cuotaPropuesta: body.cuota_propuesta == null ? undefined : Number(body.cuota_propuesta),
    });
  } catch (e) {
    // Los errores del motor son de negocio y ya vienen redactados para el usuario.
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Datos inválidos"), { status: 400 });
  }

  try {
    const { sb, empresaId, usuarioCatalogId } = auth;
    const { data, error } = await sb
      .from("plan_simulaciones")
      .insert({
        empresa_id: empresaId,
        cliente_id: typeof body.cliente_id === "string" && body.cliente_id.trim() ? body.cliente_id.trim() : null,
        lote_id: typeof body.lote_id === "string" && body.lote_id.trim() ? body.lote_id.trim() : null,
        nombre: typeof body.nombre === "string" && body.nombre.trim() ? body.nombre.trim() : null,
        precio_contado: plan.precio_contado,
        entrega_inicial: plan.entrega_inicial,
        recargo_pct: plan.recargo_pct,
        frecuencia: plan.frecuencia,
        primer_vencimiento: plan.primer_vencimiento,
        modo: plan.modo,
        cuota_propuesta: plan.cuota_propuesta,
        capital: plan.capital,
        interes_total: plan.interes_total,
        monto_financiado: plan.monto_financiado,
        cantidad_cuotas: plan.cantidad_cuotas,
        cuota: plan.cuota,
        cuota_final: plan.cuota_final,
        ultimo_vencimiento: plan.ultimo_vencimiento,
        observacion:
          typeof body.observacion === "string" && body.observacion.trim() ? body.observacion.trim() : null,
        estado: "borrador",
        created_by: usuarioCatalogId,
      })
      .select()
      .single();

    if (error) throw new Error(error.message);

    return NextResponse.json(
      successResponse({ simulacion: aSimulacionGuardada(data as Record<string, unknown>) satisfies SimulacionGuardada })
    );
  } catch (e) {
    console.error("[api/lotes/simulaciones POST]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
