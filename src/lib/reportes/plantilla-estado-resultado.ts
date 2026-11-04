import { BASES, type EstadoResultado } from "./estado-resultado";

/**
 * El estado de resultado impreso, con el formato del modelo que trajo el cliente.
 *
 * Mismo orden y mismos rótulos que el papel: la grilla de ventas con su
 * porcentaje de utilidad, los gastos abiertos por cuenta en Debe y Haber, y el
 * recuadro final con resultado bruto, costo de la empresa y resultado neto.
 *
 * Función pura: recibe el reporte ya calculado y devuelve HTML.
 */

export interface DatosImpresion {
  razon_social: string;
  ruc: string | null;
  logoUrl?: string;
  emitido: string;
  reporte: EstadoResultado;
}

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Guaraníes sin decimales. Vacío cuando es cero: el formulario en papel va en blanco. */
function gs(n: number, mostrarCero = false): string {
  const v = Math.round(Number(n) || 0);
  if (v === 0 && !mostrarCero) return "";
  return v.toLocaleString("es-PY");
}

function pct(v: number | null): string {
  return v == null ? "" : `${v.toLocaleString("es-PY", { maximumFractionDigits: 1 })}%`;
}

function fmtFecha(ymd: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd).slice(0, 10));
  return m ? `${Number(m[3])}/${Number(m[2])}/${m[1]}` : "";
}

export function plantillaEstadoResultado(datos: DatosImpresion, opciones?: { autoImprimir?: boolean }): string {
  const { reporte: r } = datos;
  const neg = (n: number) => (n < 0 ? " neg" : "");

  const filasVentas = r.ventas
    .map(
      (v) => `<tr>
      <td class="cuenta">${esc(v.concepto)}</td>
      <td class="n">${gs(v.ingreso)}</td>
      <td class="n">${gs(v.costo)}</td>
      <td class="n${neg(v.utilidad)}">${gs(v.utilidad)}</td>
      <td class="n">${esc(pct(v.pct))}</td>
    </tr>`
    )
    .join("");

  const filasGastos = r.gastos
    .map(
      (g) => `<tr>
      <td class="cuenta" colspan="2">${esc(g.cuenta)}</td>
      <td class="n">${gs(g.debe)}</td>
      <td class="n">${gs(g.haber)}</td>
      <td></td>
    </tr>`
    )
    .join("");

  const sinMovimiento = r.ventas.length === 0 && r.gastos.length === 0;

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Estado de resultado ${esc(fmtFecha(r.desde))} a ${esc(fmtFecha(r.hasta))}</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:Arial,Helvetica,sans-serif;color:#111827;background:#e5e7eb;font-size:10.5pt;line-height:1.35}
  .hoja{width:210mm;margin:10px auto;background:#fff;padding:14mm 14mm 18mm}

  .membrete{display:flex;justify-content:space-between;align-items:flex-start;gap:16px;
    border-bottom:2px solid #111827;padding-bottom:8px}
  .membrete .logo{max-height:.5in;max-width:2in;object-fit:contain;display:block}
  .membrete .razon{font-size:13pt;font-weight:800}
  .membrete .ruc{font-size:9pt;color:#374151}
  .membrete .emitido{font-size:8.5pt;color:#6b7280;text-align:right}

  .titulo{text-align:center;margin:12px 0 2px;font-size:12pt;font-weight:700}
  .rango{text-align:center;font-size:10pt;margin-bottom:2px}
  .criterio{text-align:center;font-size:8.5pt;color:#6b7280;margin-bottom:12px}

  table{width:100%;border-collapse:collapse;table-layout:fixed}
  th,td{border:1px solid #9ca3af;padding:3px 7px;font-size:9.5pt;vertical-align:top}
  th{background:#f3f4f6;font-weight:700;text-align:center;font-size:9pt}
  td.cuenta{word-break:break-word}
  td.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
  td.n.neg{color:#b91c1c}
  /* El modelo resalta en amarillo los renglones de total. */
  tr.total td{background:#fef9c3;font-weight:700}
  tr.total-fuerte td{background:#fde68a;font-weight:800;font-size:10.5pt}
  tr.sub th{background:#fff;border-top:0;text-align:center}
  .vacio{border:1px dashed #9ca3af;padding:14px;text-align:center;color:#6b7280;font-size:10pt;margin-top:10px}

  .cierre{margin-top:16px;display:flex;justify-content:flex-end}
  .cierre table{width:auto;min-width:74mm}
  .cierre td{border:1px solid #111827;padding:5px 10px;font-size:10pt}
  .cierre td.k{font-weight:600}
  .cierre tr.neto td{background:#fde68a;font-weight:800;font-size:11.5pt}

  .aviso{margin-top:14px;border-left:3px solid #b45309;background:#fffbeb;padding:8px 11px;font-size:9pt;color:#7c2d12}
  .pie{margin-top:18px;border-top:1px solid #d1d5db;padding-top:7px;font-size:8pt;color:#6b7280}

  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;
    background:#0EA5E9;color:#fff;cursor:pointer;font-family:inherit}

  @media print{
    body{background:#fff}
    .toolbar{display:none}
    .hoja{width:auto;margin:0;padding:0}
    thead{display:table-header-group} tr{break-inside:avoid}
    @page{size:A4;margin:14mm}
  }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
<div class="hoja">

  <div class="membrete">
    <div>
      ${datos.logoUrl ? `<img class="logo" src="${esc(datos.logoUrl)}" alt="${esc(datos.razon_social)}">` : ""}
      <div class="razon">${esc(datos.razon_social)}</div>
      ${datos.ruc ? `<div class="ruc">RUC ${esc(datos.ruc)}</div>` : ""}
    </div>
    <div class="emitido">Emitido el ${esc(fmtFecha(datos.emitido))}</div>
  </div>

  <div class="titulo">Estado de resultado · Moneda Guaraníes</div>
  <div class="rango">Rango: ${esc(fmtFecha(r.desde))} a ${esc(fmtFecha(r.hasta))}</div>
  <div class="criterio">${esc(BASES[r.base].label)} — ${esc(BASES[r.base].detalle)}</div>

  ${
    sinMovimiento
      ? `<p class="vacio">En este período no hay ventas cobradas ni gastos cargados.</p>`
      : `<table>
    <colgroup><col style="width:38%"><col style="width:16%"><col style="width:16%"><col style="width:16%"><col style="width:14%"></colgroup>
    <thead>
      <tr><th>Cuentas</th><th>Ingreso</th><th>Costo</th><th>Utilidad</th><th>%</th></tr>
    </thead>
    <tbody>
      ${filasVentas || `<tr><td class="cuenta" colspan="5">Sin ventas en el período.</td></tr>`}
      <tr class="total">
        <td>TOTAL VENTAS DEL PERÍODO</td>
        <td class="n">${gs(r.total_ventas.ingreso, true)}</td>
        <td class="n">${gs(r.total_ventas.costo, true)}</td>
        <td class="n${neg(r.total_ventas.utilidad)}">${gs(r.total_ventas.utilidad, true)}</td>
        <td class="n">${esc(pct(r.total_ventas.pct))}</td>
      </tr>
      <tr class="sub"><th colspan="2"></th><th>Debe</th><th>Haber</th><th></th></tr>
      ${filasGastos || `<tr><td class="cuenta" colspan="5">Sin gastos cargados en el período.</td></tr>`}
      <tr class="total">
        <td colspan="2">TOTAL GASTOS OPERATIVOS</td>
        <td class="n">${gs(r.total_gastos.debe, true)}</td>
        <td class="n">${gs(r.total_gastos.haber, true)}</td>
        <td></td>
      </tr>
      <tr class="total-fuerte">
        <td>GANANCIA NETA DEL PERÍODO</td>
        <td class="n">${gs(r.total_ventas.ingreso, true)}</td>
        <td class="n">${gs(r.total_ventas.costo + r.gastos_operativos, true)}</td>
        <td class="n${neg(r.resultado_neto)}">${gs(r.resultado_neto, true)}</td>
        <td class="n">${esc(pct(r.total_ventas.ingreso ? Math.round((r.resultado_neto / r.total_ventas.ingreso) * 1000) / 10 : null))}</td>
      </tr>
    </tbody>
  </table>`
  }

  <div class="cierre">
    <table>
      <tr><td class="k">Resultado bruto</td><td class="n${neg(r.resultado_bruto)}">${gs(r.resultado_bruto, true)}</td></tr>
      <tr><td class="k">Costo de la empresa</td><td class="n">${gs(r.gastos_operativos, true)}</td></tr>
      <tr class="neto"><td class="k">Resultado neto</td><td class="n${neg(r.resultado_neto)}">${gs(r.resultado_neto, true)}</td></tr>
    </table>
  </div>

  ${
    r.ventas_sin_costo > 0
      ? `<p class="aviso"><strong>El margen de este período está inflado.</strong> Hay ${r.ventas_sin_costo}
         contrato${r.ventas_sin_costo === 1 ? "" : "s"} con ventas en el período cuyo lote no tiene cargado el costo de
         adquisición, así que esas ventas figuran sin costo. Cargalo en la ficha del lote para que la utilidad sea real.</p>`
      : ""
  }

  <p class="pie">Documento interno de gestión, no contable ni fiscal. Las columnas Debe y Haber reflejan los gastos
  cargados y sus correcciones; el sistema no lleva partida doble.</p>

</div>
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
