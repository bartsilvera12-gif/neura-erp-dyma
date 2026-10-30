/**
 * Reporte de precios de lotes como documento imprimible.
 *
 * Hoja liviana para ver, descargar en PDF o imprimir la lista de precios de una
 * urbanización, ordenada por número de lote y con las dos monedas (Gs y USD).
 * Función pura: recibe datos y devuelve HTML listo para el navegador, igual que
 * la plantilla de simulación.
 */

export interface FilaReportePrecio {
  numero: string;
  manzana: string;
  superficie_m2: number | null;
  /** Precio de contado convertido a cada moneda (null si no se pudo convertir). */
  contado_gs: number | null;
  contado_usd: number | null;
  financiado_gs: number | null;
  financiado_usd: number | null;
  estado_label: string;
}

export interface DatosReportePrecioPdf {
  urbanizacion: string;
  /** Texto del recorte aplicado: fracción/manzana/rango. Vacío si es todo. */
  filtro?: string | null;
  /** Gs por 1 USD; 0 o nulo = no se muestran los USD. */
  cotizacion: number | null;
  emitida: string; // YYYY-MM-DD
  incluir_financiado: boolean;
  filas: FilaReportePrecio[];
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

const gs = (v: number | null): string =>
  v == null ? "—" : `Gs. ${Math.round(v).toLocaleString("es-PY")}`;
const usd = (v: number | null): string =>
  v == null ? "—" : `USD ${Number(v).toLocaleString("es-PY", { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const m2 = (v: number | null): string =>
  v == null ? "—" : `${Number(v).toLocaleString("es-PY", { maximumFractionDigits: 2 })} m²`;

export function plantillaReportePrecios(
  datos: DatosReportePrecioPdf,
  opciones?: { autoImprimir?: boolean }
): string {
  const cotizacion = datos.cotizacion && datos.cotizacion > 0 ? datos.cotizacion : null;
  const fin = datos.incluir_financiado;

  // Columnas: Lote, Manzana, Superficie, Contado Gs, Contado USD, [Financiado Gs, Financiado USD], Estado.
  const colspan = 4 + (cotizacion ? 1 : 0) + (fin ? (cotizacion ? 2 : 1) : 0);

  const thUsdContado = cotizacion ? `<th class="n">Contado USD</th>` : "";
  const thFinGs = fin ? `<th class="n">Financiado Gs</th>` : "";
  const thFinUsd = fin && cotizacion ? `<th class="n">Financiado USD</th>` : "";

  const filas = datos.filas
    .map((f) => {
      const tdUsdContado = cotizacion ? `<td class="n">${usd(f.contado_usd)}</td>` : "";
      const tdFinGs = fin ? `<td class="n">${gs(f.financiado_gs)}</td>` : "";
      const tdFinUsd = fin && cotizacion ? `<td class="n">${usd(f.financiado_usd)}</td>` : "";
      return `<tr>
      <td class="c b">${esc(f.numero)}</td>
      <td class="c">${esc(f.manzana || "—")}</td>
      <td class="n">${m2(f.superficie_m2)}</td>
      <td class="n b">${gs(f.contado_gs)}</td>
      ${tdUsdContado}
      ${tdFinGs}
      ${tdFinUsd}
      <td class="c">${esc(f.estado_label)}</td>
    </tr>`;
    })
    .join("");

  const cuerpo =
    datos.filas.length > 0
      ? filas
      : `<tr><td class="c" colspan="${colspan}" style="padding:18px;color:#9ca3af">No hay lotes para los filtros elegidos.</td></tr>`;

  const sub = [
    datos.filtro ? esc(datos.filtro) : "",
    `Emitido el ${esc(fmtFecha(datos.emitida))}`,
    `${datos.filas.length} lote${datos.filas.length === 1 ? "" : "s"}`,
  ]
    .filter(Boolean)
    .join(" · ");

  const avisoCotizacion = cotizacion
    ? `<div class="cot">Cotización usada: <b>Gs. ${Math.round(cotizacion).toLocaleString("es-PY")}</b> por 1 USD</div>`
    : `<div class="cot cot--off">Sin cotización cargada — se muestran solo los guaraníes</div>`;

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Lista de precios — ${esc(datos.urbanizacion)}</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#111827;background:#f3f4f6;font-size:11pt;line-height:1.45}
  .page{width:210mm;margin:0 auto;background:#fff;padding:16mm 18mm}
  h1{font-size:16pt;margin:0 0 2px}
  .sub{font-size:9.5pt;color:#6b7280;margin-bottom:10px}
  .cot{display:inline-block;margin-bottom:14px;border:1px solid #bae6fd;background:#f0f9ff;color:#075985;border-radius:8px;padding:4px 10px;font-size:9pt;font-weight:600}
  .cot--off{border-color:#fcd34d;background:#fffbeb;color:#92400e}
  table{width:100%;border-collapse:collapse;font-size:9.5pt}
  th,td{border:1px solid #d1d5db;padding:4px 7px;text-align:left}
  th{background:#166c74;color:#fff;font-weight:700;text-align:center;font-size:8.5pt;text-transform:uppercase;letter-spacing:.03em}
  th.n{text-align:right}
  td.c{text-align:center} td.n{text-align:right;font-variant-numeric:tabular-nums} td.b{font-weight:800}
  tbody tr:nth-child(even){background:#f9fafb}
  .pie{margin-top:14px;font-size:8.5pt;color:#9ca3af;border-top:1px solid #e5e7eb;padding-top:8px}
  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer}
  @media print{ body{background:#fff} .toolbar{display:none} .page{width:auto;padding:0;margin:0} @page{size:A4;margin:14mm} thead{display:table-header-group} tr{break-inside:avoid} }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
<div class="page">
  <h1>Lista de precios — ${esc(datos.urbanizacion)}</h1>
  <div class="sub">${sub}</div>
  ${avisoCotizacion}

  <table>
    <thead><tr>
      <th>Lote</th>
      <th>Manzana</th>
      <th class="n">Superficie</th>
      <th class="n">Contado Gs</th>
      ${thUsdContado}
      ${thFinGs}
      ${thFinUsd}
      <th>Estado</th>
    </tr></thead>
    <tbody>${cuerpo}</tbody>
  </table>

  <p class="pie">Lista de precios generada por el sistema${cotizacion ? ". Los valores en USD son una referencia calculada con la cotización indicada arriba" : ""}. Los precios pueden cambiar sin previo aviso.</p>
</div>
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
