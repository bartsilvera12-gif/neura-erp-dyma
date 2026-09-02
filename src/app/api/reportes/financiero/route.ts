import { NextResponse } from "next/server";
import { requireReportesModuleAccess } from "@/lib/reportes/reportes-auth";
import { errorResponse, successResponse } from "@/lib/api/response";
import { claveProyeccion, diasEntre, hoyAsuncion, tramoDeMora } from "@/lib/reportes/calculo";
import type { FilaMora, FinancieroPayload, MesFlujo, TramoProyeccion } from "@/lib/reportes/types";

export const dynamic = "force-dynamic";

const FECHA_RE = /^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/;

/**
 * GET /api/reportes/financiero?desde=&hasta=
 *
 * Tres cosas en una sola pasada, porque comparten las mismas tablas:
 *   - Flujo de caja: cobros reales (`pagos`) contra egresos (`gastos`), por mes.
 *   - Proyección de cobros: facturas pendientes agrupadas por cuándo vencen.
 *   - Cartera en mora: facturas pendientes ya vencidas, por tramo de atraso.
 *
 * El rango de fechas acota SOLO el flujo. La proyección y la mora son una foto de
 * hoy: filtrarlas por período daría un número que no significa nada.
 */
export async function GET(request: Request) {
  const auth = await requireReportesModuleAccess(request);
  if (!auth.ok) return NextResponse.json(errorResponse(auth.message), { status: auth.status });

  try {
    const { sb, empresaId } = auth;
    const url = new URL(request.url);
    const desde = url.searchParams.get("desde") ?? "";
    const hasta = url.searchParams.get("hasta") ?? "";
    const hoy = hoyAsuncion();

    let qPagos = sb.from("pagos").select("monto, fecha_pago").eq("empresa_id", empresaId);
    if (FECHA_RE.test(desde)) qPagos = qPagos.gte("fecha_pago", desde);
    if (FECHA_RE.test(hasta)) qPagos = qPagos.lte("fecha_pago", hasta);

    let qGastos = sb.from("gastos").select("monto, fecha").eq("empresa_id", empresaId);
    if (FECHA_RE.test(desde)) qGastos = qGastos.gte("fecha", desde);
    if (FECHA_RE.test(hasta)) qGastos = qGastos.lte("fecha", hasta);

    const [pagosRes, gastosRes, pendRes] = await Promise.all([
      qPagos,
      qGastos,
      sb
        .from("facturas")
        .select("id, numero_factura, cliente_id, fecha_vencimiento, monto, saldo")
        .eq("empresa_id", empresaId)
        .eq("estado", "Pendiente"),
    ]);
    if (pagosRes.error) throw new Error(pagosRes.error.message);
    if (pendRes.error) throw new Error(pendRes.error.message);
    // `gastos` puede fallar si el módulo nunca se provisionó: el flujo sigue con egresos en cero.
    const egresosDisponibles = !gastosRes.error;

    // ── Flujo de caja por mes ────────────────────────────────────────────────
    const meses = new Map<string, MesFlujo>();
    const acumula = (fecha: string, campo: "cobrado" | "egresos", monto: number) => {
      const mes = fecha.slice(0, 7);
      if (!mes) return;
      const actual = meses.get(mes) ?? { mes, cobrado: 0, egresos: 0, neto: 0 };
      actual[campo] += monto;
      meses.set(mes, actual);
    };
    for (const p of (pagosRes.data ?? []) as Record<string, unknown>[]) {
      acumula(String(p.fecha_pago ?? ""), "cobrado", Number(p.monto ?? 0));
    }
    if (egresosDisponibles) {
      for (const g of (gastosRes.data ?? []) as Record<string, unknown>[]) {
        acumula(String(g.fecha ?? ""), "egresos", Number(g.monto ?? 0));
      }
    }
    const flujo = [...meses.values()]
      .map((m) => ({ ...m, neto: m.cobrado - m.egresos }))
      .sort((a, b) => a.mes.localeCompare(b.mes));

    // ── Proyección de cobros y cartera en mora ───────────────────────────────
    const pendientes = (pendRes.data ?? []) as Record<string, unknown>[];
    const clienteIds = [
      ...new Set(pendientes.map((f) => f.cliente_id).filter((v): v is string => typeof v === "string")),
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

    const tramos: TramoProyeccion[] = [
      { clave: "vencido", label: "Ya vencido", facturas: 0, monto: 0 },
      { clave: "7", label: "Próximos 7 días", facturas: 0, monto: 0 },
      { clave: "30", label: "8 a 30 días", facturas: 0, monto: 0 },
      { clave: "60", label: "31 a 60 días", facturas: 0, monto: 0 },
      { clave: "mas", label: "Más de 60 días", facturas: 0, monto: 0 },
      { clave: "sin_fecha", label: "Sin vencimiento", facturas: 0, monto: 0 },
    ];
    const porClave = new Map(tramos.map((t) => [t.clave, t]));
    const mora: FilaMora[] = [];

    for (const f of pendientes) {
      const saldo = Number(f.saldo ?? 0);
      if (saldo <= 0) continue;
      const venc = (f.fecha_vencimiento as string) ?? null;

      if (!venc) {
        const t = porClave.get("sin_fecha")!;
        t.facturas += 1;
        t.monto += saldo;
        continue;
      }

      const dias = diasEntre(hoy, venc); // > 0 = vence en el futuro
      const clave = claveProyeccion(venc, hoy);
      const t = porClave.get(clave)!;
      t.facturas += 1;
      t.monto += saldo;

      if (dias < 0) {
        const atraso = -dias;
        mora.push({
          factura_id: String(f.id),
          numero_factura: String(f.numero_factura ?? "—"),
          cliente_id: String(f.cliente_id ?? ""),
          cliente: etiquetas[String(f.cliente_id)] ?? "Cliente sin nombre",
          fecha_vencimiento: venc,
          dias_atraso: atraso,
          monto: Number(f.monto ?? 0),
          saldo,
          tramo: tramoDeMora(atraso),
        });
      }
    }

    mora.sort((a, b) => b.dias_atraso - a.dias_atraso || b.saldo - a.saldo);

    const payload: FinancieroPayload = {
      flujo,
      proyeccion: tramos,
      mora,
      resumen: {
        cobrado_periodo: flujo.reduce((a, m) => a + m.cobrado, 0),
        egresos_periodo: flujo.reduce((a, m) => a + m.egresos, 0),
        por_cobrar_total: tramos.reduce((a, t) => a + t.monto, 0),
        en_mora_total: mora.reduce((a, m) => a + m.saldo, 0),
        clientes_en_mora: new Set(mora.map((m) => m.cliente_id)).size,
      },
      egresos_disponibles: egresosDisponibles,
    };

    return NextResponse.json(successResponse(payload));
  } catch (e) {
    console.error("[api/reportes/financiero GET]", e instanceof Error ? e.message : e);
    return NextResponse.json(errorResponse(e instanceof Error ? e.message : "Error"), { status: 500 });
  }
}
