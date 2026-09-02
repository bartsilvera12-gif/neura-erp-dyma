import "server-only";
import { fechaMasDiasCalendario } from "@/lib/fechas/calendario";
import { montosFacturaItemParaInsert, tasaIvaDesdeIvaTipo } from "@/lib/facturacion/factura-item-montos";
import { obtenerSiguienteNumeroFacturaEmpresa } from "@/lib/facturacion/factura-suscripcion-servidor";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
import type { MonedaLimpieza, TipoFacturaLimpieza } from "@/lib/limpieza/types";

/**
 * Emisión de la factura que respalda un servicio de limpieza.
 *
 * Se repite acá la secuencia de `POST /api/facturas` (cabecera + ítem + rollback)
 * en vez de llamar a esa ruta por HTTP: así el alta del servicio y su factura
 * ocurren en el mismo request, con la misma sesión y el mismo cliente de schema.
 */
export async function emitirFacturaLimpieza(
  supabase: AppSupabaseClient,
  input: {
    empresaId: string;
    clienteId: string;
    fecha: string; // YYYY-MM-DD
    importe: number;
    moneda: MonedaLimpieza;
    tipo: TipoFacturaLimpieza;
    ivaTipo?: string;
    descripcion: string;
  }
): Promise<{ id: string; numero_factura: string; fecha_vencimiento: string }> {
  // Contado vence el mismo día; crédito sigue el default de la instancia.
  let fechaVenc = input.fecha;
  if (input.tipo === "credito") {
    const dias = Number(process.env.FACTURA_DIAS_CREDITO_DEFAULT ?? 30);
    fechaVenc = fechaMasDiasCalendario(input.fecha, Number.isFinite(dias) ? dias : 30);
  }

  const numeroFactura = await obtenerSiguienteNumeroFacturaEmpresa(supabase, input.empresaId);

  const { data, error } = await supabase
    .from("facturas")
    .insert([
      {
        empresa_id: input.empresaId,
        cliente_id: input.clienteId,
        numero_factura: numeroFactura,
        fecha: input.fecha,
        fecha_vencimiento: fechaVenc,
        monto: input.importe,
        saldo: input.importe,
        estado: "Pendiente",
        tipo: input.tipo,
        moneda: input.moneda,
      },
    ])
    .select()
    .single();

  if (error || !data?.id) {
    throw new Error(error?.message ?? "No se pudo emitir la factura del servicio");
  }

  const linea = montosFacturaItemParaInsert({
    totalLinea: input.importe,
    moneda: input.moneda,
    cantidad: 1,
    precioUnitario: input.importe,
    tasaIva: tasaIvaDesdeIvaTipo(input.ivaTipo),
  });

  const { error: errItem } = await supabase.from("factura_items").insert({
    factura_id: data.id,
    empresa_id: input.empresaId,
    descripcion: input.descripcion,
    cantidad: 1,
    precio_unitario: linea.precio_unitario,
    subtotal: linea.subtotal,
    iva: linea.iva,
    total: linea.total,
  });

  if (errItem) {
    // Sin ítem la factura queda inconsistente: se deshace la cabecera.
    await supabase.from("facturas").delete().eq("id", data.id).eq("empresa_id", input.empresaId);
    throw new Error(`No se pudo registrar el detalle de la factura: ${errItem.message}`);
  }

  return {
    id: String(data.id),
    numero_factura: numeroFactura,
    fecha_vencimiento: fechaVenc,
  };
}

/**
 * Borra la factura de un servicio que se está anulando.
 * Solo procede si no tiene cobros registrados; si los tiene, devuelve `false` y
 * la factura queda intacta (hay que anularla desde el circuito de Facturas).
 */
export async function borrarFacturaLimpiezaSiNoTienePagos(
  supabase: AppSupabaseClient,
  empresaId: string,
  facturaId: string
): Promise<boolean> {
  const { data: pagos, error: errPagos } = await supabase
    .from("pagos")
    .select("id")
    .eq("empresa_id", empresaId)
    .eq("factura_id", facturaId)
    .limit(1);
  if (errPagos) throw new Error(errPagos.message);
  if ((pagos ?? []).length > 0) return false;

  await supabase.from("factura_items").delete().eq("factura_id", facturaId).eq("empresa_id", empresaId);
  const { error } = await supabase.from("facturas").delete().eq("id", facturaId).eq("empresa_id", empresaId);
  if (error) throw new Error(error.message);
  return true;
}
