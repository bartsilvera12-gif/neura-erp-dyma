/**
 * Plan de pago SIMULADO como documento imprimible.
 *
 * Es una hoja liviana para ver/descargar antes de aceptar la venta: no necesita
 * cliente, lote ni configuración cargada (a diferencia del plan de pago del
 * contrato). Función pura: recibe datos y devuelve HTML listo para imprimir o
 * guardar como PDF desde el navegador.
 */

export interface CuotaSimuladaPdf {
  numero: number;
  vencimiento: string;
  capital: number;
  interes: number;
  total: number;
  es_cancelacion?: boolean;
}

export interface DatosSimulacionPdf {
  cliente?: string | null;
  lote?: string | null;
  moneda?: string;
  emitida: string; // YYYY-MM-DD
  precio_contado: number;
  entrega_inicial: number;
  capital: number;
  interes_total: number;
  monto_financiado: number;
  total_operacion: number;
  cantidad_cuotas: number;
  cuota: number;
  frecuencia?: string;
  recargo_pct?: number;
  es_personalizada?: boolean;
  cuotas: CuotaSimuladaPdf[];
}

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function fmtFecha(ymd: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd).slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "—";
}

export function plantillaSimulacion(datos: DatosSimulacionPdf, opciones?: { autoImprimir?: boolean }): string {
  const moneda = (datos.moneda ?? "GS").toUpperCase();
  const money = (v: number) =>
    moneda === "USD"
      ? `USD ${Number(v).toLocaleString("es-PY", { minimumFractionDigits: 2 })}`
      : `Gs. ${Math.round(Number(v) || 0).toLocaleString("es-PY")}`;

  const recargoTxt =
    datos.recargo_pct != null && datos.recargo_pct > 0
      ? `${(datos.recargo_pct * 100).toFixed(2).replace(/\.?0+$/, "")}% anual`
      : "sin recargo";

  const filas = datos.cuotas
    .map(
      (c) => `<tr>
      <td class="c">${c.numero}${c.es_cancelacion ? " — Cancelación" : ""}</td>
      <td class="c">${esc(fmtFecha(c.vencimiento))}</td>
      <td class="n">${money(c.capital)}</td>
      <td class="n">${money(c.interes)}</td>
      <td class="n b">${money(c.total)}</td>
    </tr>`
    )
    .join("");

  const totalCuotas = datos.cuotas.reduce((a, c) => a + c.total, 0);

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plan de pago — Simulación</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#111827;background:#f3f4f6;font-size:11pt;line-height:1.45}
  .page{width:210mm;margin:0 auto;background:#fff;padding:16mm 18mm}
  h1{font-size:16pt;margin:0 0 2px}
  .sub{font-size:9.5pt;color:#6b7280;margin-bottom:14px}
  .aviso{display:inline-block;margin-bottom:14px;border:1px solid #fcd34d;background:#fffbeb;color:#92400e;border-radius:8px;padding:4px 10px;font-size:9pt;font-weight:600}
  .resumen{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin-bottom:14px}
  .kpi{border:1px solid #e5e7eb;border-radius:8px;padding:8px 10px}
  .kpi .k{font-size:8pt;text-transform:uppercase;letter-spacing:.04em;color:#6b7280}
  .kpi .v{font-size:12pt;font-weight:800;margin-top:2px}
  .kpi.dest .v{color:#166c74}
  table{width:100%;border-collapse:collapse;font-size:9.5pt}
  th,td{border:1px solid #d1d5db;padding:4px 7px;text-align:left}
  th{background:#166c74;color:#fff;font-weight:700;text-align:center;font-size:8.5pt;text-transform:uppercase;letter-spacing:.03em}
  td.c{text-align:center} td.n{text-align:right} td.b{font-weight:800}
  tfoot td{background:#f3f4f6;font-weight:800}
  .pie{margin-top:14px;font-size:8.5pt;color:#9ca3af;border-top:1px solid #e5e7eb;padding-top:8px}
  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer}
  @media print{ body{background:#fff} .toolbar{display:none} .page{width:auto;padding:0;margin:0} @page{size:A4;margin:14mm} }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
<div class="page">
  <h1>Plan de pago — Simulación</h1>
  <div class="sub">${datos.cliente ? `Cliente: ${esc(datos.cliente)} · ` : ""}${datos.lote ? `${esc(datos.lote)} · ` : ""}Emitida el ${esc(fmtFecha(datos.emitida))}</div>
  <div class="aviso">Simulación — sin valor contractual</div>

  <div class="resumen">
    <div class="kpi"><div class="k">Precio de contado</div><div class="v">${money(datos.precio_contado)}</div></div>
    <div class="kpi"><div class="k">Entrega inicial</div><div class="v">${money(datos.entrega_inicial)}</div></div>
    <div class="kpi"><div class="k">Saldo a financiar</div><div class="v">${money(datos.capital)}</div></div>
    <div class="kpi"><div class="k">Total a pagar</div><div class="v">${money(datos.entrega_inicial + datos.monto_financiado)}</div></div>
    <div class="kpi"><div class="k">${datos.es_personalizada ? "Cuotas" : "Cantidad de cuotas"}</div><div class="v">${datos.cantidad_cuotas}${datos.frecuencia && !datos.es_personalizada ? ` · ${esc(datos.frecuencia)}` : ""}</div></div>
    <div class="kpi"><div class="k">${datos.es_personalizada ? "Recargo" : "Recargo (financiación)"}</div><div class="v">${esc(recargoTxt)}</div></div>
    <div class="kpi"><div class="k">Total intereses</div><div class="v">${money(datos.interes_total)}</div></div>
    <div class="kpi dest"><div class="k">${datos.es_personalizada ? "Total financiado" : "Cuota fija"}</div><div class="v">${money(datos.es_personalizada ? datos.monto_financiado : datos.cuota)}</div></div>
  </div>

  <table>
    <thead><tr><th>Cuota</th><th>Vence</th><th>Capital</th><th>Interés</th><th>Total</th></tr></thead>
    <tbody>${filas}</tbody>
    <tfoot><tr><td class="c" colspan="2">Totales</td><td class="n">${money(datos.capital)}</td><td class="n">${money(datos.interes_total)}</td><td class="n">${money(totalCuotas)}</td></tr></tfoot>
  </table>

  <p class="pie">Documento de simulación generado por el sistema. No reemplaza al contrato ni al plan de pago definitivo.</p>
</div>
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
