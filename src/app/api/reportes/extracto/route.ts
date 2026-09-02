import { NextResponse } from "next/server";
import { requireReportesModuleAccess } from "@/lib/reportes/reportes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { diasAtraso, hoyAsuncion } from "@/lib/reportes/calculo";
import type { ExtractoPayload, MovimientoExtracto } from "@/lib/reportes/types";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/**
 * GET /api/reportes/extracto?cliente_id=&desde=&hasta=
 *
 * Extracto de cuenta del cliente: cada factura emitida (debe) y cada pago
 * imputado (haber), en una sola línea de tiempo, con el saldo resultante.
 *
 * Hoy la unidad es la factura. Cuando exista el plan de cuotas (fase 2) cada
 * cuota emitirá su propia factura, así que este mismo extracto pasa a mostrar
 * cuotas sin cambiarle la forma.
 */
export async function GET(request: Request) {
  const auth = await requireReportesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  const url = new URL(request.url);
  const clienteId = (url.searchParams.get("cliente_id") ?? "").trim();
  const desde = url.searchParams.get("desde") ?? "";
  const hasta = url.searchParams.get("hasta") ?? "";

  if (!clienteId) {
    return NextResponse.json(errorResponse("Elegí un cliente"), { status: 400 });
  }

  try {
    const { sb, empresaId } = auth;

    const { data: cli, error: errCli } = await sb
      .from("clientes")
      .select("id, empresa, nombre_contacto, nombre, ruc, documento")
      .eq("id", clienteId)
      .eq("empresa_id", empresaId)
      .maybeSingle();
    if (errCli) throw new Error(errCli.message);
    if (!cli) return NextResponse.json(errorResponse("Cliente no encontrado"), { status: 404 });

    const c = cli as Record<string, string | null>;
    const label = (c.empresa || c.nombre_contacto || c.nombre || "").trim() || "Cliente sin nombre";

    let qf = sb
      .from("facturas")
      .select("id, numero_factura, fecha, fecha_vencimiento, monto, saldo, estado, tipo, moneda")
      .eq("empresa_id", empresaId)
      .eq("cliente_id", clienteId)
      .order("fecha");
    if (FECHA_RE.test(desde)) qf = qf.gte("fecha", desde);
    if (FECHA_RE.test(hasta)) qf = qf.lte("fecha", hasta);

    const { data: facData, error: errFac } = await qf;
    if (errFac) throw new Error(errFac.message);
    const facturas = (facData ?? []) as Record<string, unknown>[];

    // Los pagos se traen por factura del cliente: `pagos.cliente_id` puede venir
    // vacío en filas antiguas, pero `factura_id` siempre está.
    const facturaIds = facturas.map((f) => String(f.id));
    let pagos: Record<string, unknown>[] = [];
    if (facturaIds.length > 0) {
      const { data: pagData, error: errPag } = await sb
        .from("pagos")
        .select("id, factura_id, monto, fecha_pago, metodo_pago, referencia")
        .eq("empresa_id", empresaId)
        .in("factura_id", facturaIds)
        .order("fecha_pago");
      if (errPag) throw new Error(errPag.message);
      pagos = (pagData ?? []) as Record<string, unknown>[];
    }

    const numeroPorFactura = new Map(facturas.map((f) => [String(f.id), String(f.numero_factura ?? "—")]));
    const hoy = hoyAsuncion();

    const movimientos: MovimientoExtracto[] = [];

    for (const f of facturas) {
      const estado = String(f.estado ?? "");
      const venc = (f.fecha_vencimiento as string) ?? null;
      movimientos.push({
        tipo: "factura",
        fecha: String(f.fecha ?? ""),
        documento: String(f.numero_factura ?? "—"),
        detalle: `Factura ${String(f.tipo ?? "")}`.trim(),
        debe: Number(f.monto ?? 0),
        haber: 0,
        estado,
        vencimiento: venc,
        dias_atraso: estado === "Pendiente" ? diasAtraso(venc, hoy) : null,
      });
    }

    for (const p of pagos) {
      const ref = (p.referencia as string) ?? "";
      const metodo = (p.metodo_pago as string) ?? "";
      movimientos.push({
        tipo: "pago",
        fecha: String(p.fecha_pago ?? ""),
        documento: numeroPorFactura.get(String(p.factura_id)) ?? "—",
        detalle: [metodo, ref].filter(Boolean).join(" · ") || "Cobro",
        debe: 0,
        haber: Number(p.monto ?? 0),
        estado: null,
        vencimiento: null,
        dias_atraso: null,
      });
    }

    // Orden cronológico; a igual fecha, primero la factura y después su cobro.
    movimientos.sort(
      (a, b) => a.fecha.localeCompare(b.fecha) || (a.tipo === "factura" ? -1 : 1) - (b.tipo === "factura" ? -1 : 1)
    );

    const vivas = facturas.filter((f) => f.estado !== "Anulado" && f.estado !== "Corregida NC");
    const pendientes = vivas.filter((f) => f.estado === "Pendiente");
    const vencidas = pendientes.filter((f) => (diasAtraso((f.fecha_vencimiento as string) ?? null, hoy) ?? 0) > 0);

    const payload: ExtractoPayload = {
      cliente: { id: clienteId, label, ruc: c.ruc ?? null, documento: c.documento ?? null },
      movimientos,
      resumen: {
        facturado: vivas.reduce((a, f) => a + Number(f.monto ?? 0), 0),
        cobrado: pagos.reduce((a, p) => a + Number(p.monto ?? 0), 0),
        saldo: vivas.reduce((a, f) => a + Number(f.saldo ?? 0), 0),
        facturas_pendientes: pendientes.length,
        facturas_vencidas: vencidas.length,
        saldo_vencido: vencidas.reduce((a, f) => a + Number(f.saldo ?? 0), 0),
      },
      // El ERP factura en una sola moneda por documento; se informa la del primer
      // comprobante para rotular los importes sin inventar una conversión.
      moneda: String(facturas[0]?.moneda ?? "GS"),
    };

    return NextResponse.json(successResponse(payload));
  } catch (e) {
    console.error("[api/reportes/extracto GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
