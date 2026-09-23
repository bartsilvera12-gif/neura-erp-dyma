import "server-only";
import { fechaMasDiasCalendario } from "@/lib/fechas/calendario";
import {
  montosFacturaItemParaInsert,
  tasaIvaDesdeIvaTipo,
  type TasaIvaItem,
} from "@/lib/facturacion/factura-item-montos";

/** Una línea de factura con su tasa, para facturas de varios renglones (p.ej. el 70/30 de la cuota de lote). */
export interface LineaFacturaSimple {
  descripcion: string;
  /** Total de la línea con IVA incluido. */
  total: number;
  tasa: TasaIvaItem;
}
import { obtenerSiguienteNumeroFacturaEmpresa } from "@/lib/facturacion/factura-suscripcion-servidor";
import type { AppSupabaseClient } from "@/lib/supabase/schema";
export type MonedaFactura = "GS" | "USD";
export type TipoFacturaSimple = "contado" | "credito";

/**
 * Emite una factura puntual de una sola línea contra un cliente.
 *
 * La usan los módulos que registran un hecho y lo facturan en el acto: el
 * servicio de limpieza y el cobro de una cuota de lote. Se repite acá la
 * secuencia de  (cabecera + ítem + rollback) en vez de
 * llamar a esa ruta por HTTP, para que el hecho y su factura ocurran en el
 * mismo request, con la misma sesión y el mismo cliente de schema.
 */
export async function emitirFacturaSimple(
  supabase: AppSupabaseClient,
  input: {
    empresaId: string;
    clienteId: string;
    fecha: string; // YYYY-MM-DD
    importe: number;
    moneda: MonedaFactura;
    tipo: TipoFacturaSimple;
    ivaTipo?: string;
    descripcion: string;
    /**
     * Desglose en varias líneas (suma = importe). Si se pasa, la factura sale con
     * un renglón por línea, cada uno con su tasa; si no, sale la línea única con
     * `descripcion`/`ivaTipo`. Lo usa la cuota de lote para el 70% exento + 30% al 5%.
     */
    lineas?: LineaFacturaSimple[];
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

  // Una sola línea, o varias si se pasó `lineas` (p.ej. el 70/30 de la cuota).
  const desglose: LineaFacturaSimple[] =
    input.lineas && input.lineas.length > 0
      ? input.lineas
      : [{ descripcion: input.descripcion, total: input.importe, tasa: tasaIvaDesdeIvaTipo(input.ivaTipo) }];

  const items = desglose.map((l) => {
    const montos = montosFacturaItemParaInsert({
      totalLinea: l.total,
      moneda: input.moneda,
      cantidad: 1,
      precioUnitario: l.total,
      tasaIva: l.tasa,
    });
    return {
      factura_id: data.id,
      empresa_id: input.empresaId,
      descripcion: l.descripcion,
      cantidad: 1,
      precio_unitario: montos.precio_unitario,
      subtotal: montos.subtotal,
      iva: montos.iva,
      total: montos.total,
    };
  });

  const { error: errItem } = await supabase.from("factura_items").insert(items);

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

/** ¿La factura ya recibió algún cobro? Con cobros, su importe no se puede reescribir. */
export async function facturaTieneCobros(
  supabase: AppSupabaseClient,
  empresaId: string,
  facturaId: string
): Promise<boolean> {
  const { data, error } = await supabase
    .from("pagos")
    .select("id")
    .eq("empresa_id", empresaId)
    .eq("factura_id", facturaId)
    .limit(1);
  if (error) throw new Error(error.message);
  return (data ?? []).length > 0;
}

/**
 * Reescribe la factura de una línea que emitió `emitirFacturaSimple`, cuando se
 * corrige el hecho que la originó.
 *
 * Solo para facturas sin cobros: el saldo se reescribe entero, así que un pago
 * previo quedaría colgado. Quien llama debe verificarlo con `facturaTieneCobros`.
 * El número de factura no se toca — es la identidad del documento.
 */
export async function actualizarFacturaSimple(
  supabase: AppSupabaseClient,
  input: {
    empresaId: string;
    facturaId: string;
    clienteId: string;
    fecha: string; // YYYY-MM-DD
    importe: number;
    moneda: MonedaFactura;
    tipo: TipoFacturaSimple;
    ivaTipo?: string;
    descripcion: string;
  }
): Promise<{ fecha_vencimiento: string }> {
  let fechaVenc = input.fecha;
  if (input.tipo === "credito") {
    const dias = Number(process.env.FACTURA_DIAS_CREDITO_DEFAULT ?? 30);
    fechaVenc = fechaMasDiasCalendario(input.fecha, Number.isFinite(dias) ? dias : 30);
  }

  const { error: errFac } = await supabase
    .from("facturas")
    .update({
      cliente_id: input.clienteId,
      fecha: input.fecha,
      fecha_vencimiento: fechaVenc,
      monto: input.importe,
      saldo: input.importe,
      estado: "Pendiente",
      tipo: input.tipo,
      moneda: input.moneda,
    })
    .eq("id", input.facturaId)
    .eq("empresa_id", input.empresaId);
  if (errFac) throw new Error(`No se pudo actualizar la factura: ${errFac.message}`);

  const linea = montosFacturaItemParaInsert({
    totalLinea: input.importe,
    moneda: input.moneda,
    cantidad: 1,
    precioUnitario: input.importe,
    tasaIva: tasaIvaDesdeIvaTipo(input.ivaTipo),
  });

  // La factura simple tiene una sola línea: se reescribe en bloque.
  const { error: errItem } = await supabase
    .from("factura_items")
    .update({
      descripcion: input.descripcion,
      cantidad: 1,
      precio_unitario: linea.precio_unitario,
      subtotal: linea.subtotal,
      iva: linea.iva,
      total: linea.total,
    })
    .eq("factura_id", input.facturaId)
    .eq("empresa_id", input.empresaId);
  if (errItem) throw new Error(`No se pudo actualizar el detalle de la factura: ${errItem.message}`);

  return { fecha_vencimiento: fechaVenc };
}

/**
 * Borra la factura de un servicio que se está anulando.
 * Solo procede si no tiene cobros registrados; si los tiene, devuelve `false` y
 * la factura queda intacta (hay que anularla desde el circuito de Facturas).
 */
export async function borrarFacturaSiNoTienePagos(
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
