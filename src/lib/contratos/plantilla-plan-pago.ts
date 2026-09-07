import { guaraniesEnLetras } from "./numero-a-letras";
import type { DatosContrato } from "./types";

/**
 * Plan de pago como documento suelto.
 *
 * El mismo cuadro va como anexo del contrato, pero el negocio también lo
 * necesita aparte: es lo que se le entrega al comprador para que se lleve sus
 * vencimientos, sin las diecisiete cláusulas encima.
 *
 * Marca las cuotas ya pagadas y el saldo, así sirve también como estado del
 * plan a la fecha, no solo como cronograma inicial.
 *
 * Función pura: recibe datos y devuelve HTML.
 */

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function gs(n: number): string {
  return `Gs. ${Math.round(Number(n) || 0).toLocaleString("es-PY")}`;
}

function fmtFecha(ymd: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd).slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "—";
}

/** Estado de cada cuota a la fecha, para que el cuadro sirva de estado de cuenta. */
export interface EstadoCuotaPlan {
  numero: number;
  saldo: number;
  pagada: boolean;
}

export function plantillaPlanPago(
  datos: DatosContrato,
  estados: EstadoCuotaPlan[],
  opciones?: { autoImprimir?: boolean; logoUrl?: string }
): string {
  const { config, comprador, conyuge, inmueble, operacion, cuotas } = datos;
  const logo = opciones?.logoUrl ?? datos.logoUrl;

  const porNumero = new Map(estados.map((e) => [e.numero, e]));
  const pagadas = cuotas.filter((c) => porNumero.get(c.numero)?.pagada).length;
  const saldoTotal = cuotas.reduce((a, c) => a + (porNumero.get(c.numero)?.saldo ?? c.total), 0);
  const cobrado = cuotas.reduce((a, c) => a + c.total, 0) - saldoTotal;

  const filas = cuotas
    .map((c) => {
      const e = porNumero.get(c.numero);
      const pagada = e?.pagada === true;
      const saldo = e?.saldo ?? c.total;
      const parcial = !pagada && saldo > 0 && saldo < c.total;
      return `<tr class="${pagada ? "pagada" : ""}">
        <td class="c">${c.numero}</td>
        <td class="c">${esc(fmtFecha(c.vencimiento))}</td>
        <td>${gs(c.capital)}</td>
        <td>${gs(c.interes)}</td>
        <td><strong>${gs(c.total)}</strong></td>
        <td>${gs(saldo)}</td>
        <td class="c">${pagada ? "Pagada" : parcial ? "Parcial" : "Pendiente"}</td>
      </tr>`;
    })
    .join("");

  const compradores = [comprador, ...(conyuge ? [conyuge] : [])]
    .map((p) => esc(p.nombre))
    .join(" y ");

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Plan de pago ${esc(operacion.numero_contrato)}</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:-apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#111827;background:#f3f4f6;font-size:11pt;line-height:1.45}
  .page{width:210mm;margin:0 auto;background:#fff;padding:18mm 20mm}
  .membrete{display:flex;justify-content:space-between;align-items:flex-start;gap:18px;border-bottom:2px solid #111827;padding-bottom:10px;margin-bottom:14px}
  .membrete .logo{max-width:180px;max-height:70px;object-fit:contain;display:block}
  .membrete .logo-txt{font-size:15pt;font-weight:800}
  .membrete-datos{text-align:right;font-size:9pt;color:#374151;line-height:1.4}
  .membrete-datos .razon{font-weight:800;color:#111827;font-size:10.5pt}
  h1{font-size:14pt;margin:0 0 2px}
  .sub{font-size:10pt;color:#6b7280;margin-bottom:14px}
  .datos{display:grid;grid-template-columns:repeat(3,1fr);gap:10px;margin-bottom:14px}
  .dato{border:1px solid #e5e7eb;border-radius:6px;padding:8px 10px}
  .dato .k{font-size:8.5pt;text-transform:uppercase;letter-spacing:.04em;color:#6b7280}
  .dato .v{font-size:11pt;font-weight:700;margin-top:1px}
  table{width:100%;border-collapse:collapse;font-size:9.5pt}
  th,td{border:1px solid #d1d5db;padding:4px 7px;text-align:right}
  th{background:#f3f4f6;font-weight:700;text-align:center;font-size:9pt;text-transform:uppercase;letter-spacing:.03em}
  td.c{text-align:center}
  tr.pagada{background:#f0fdf4;color:#166534}
  tfoot td{background:#f9fafb;font-weight:800}
  .pie{margin-top:22px;font-size:9pt;color:#6b7280}
  .firmas{display:flex;gap:40px;margin-top:40px}
  .firma{flex:1;text-align:center}
  .firma .linea{border-top:1px solid #111827;margin-bottom:5px}
  .firma .rol{font-size:9pt;font-weight:700}
  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer}
  @media print{
    body{background:#fff} .toolbar{display:none} .page{width:auto;padding:0;margin:0}
    thead{display:table-header-group} tr{break-inside:avoid}
    @page{size:A4;margin:14mm}
  }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
<div class="page">

<div class="membrete">
  ${logo ? `<img class="logo" src="${esc(logo)}" alt="${esc(config.razon_social)}" />` : `<div class="logo-txt">${esc(config.razon_social)}</div>`}
  <div class="membrete-datos">
    <div class="razon">${esc(config.razon_social)}</div>
    ${config.ruc ? `<div>RUC ${esc(config.ruc)}</div>` : ""}
    ${config.domicilio ? `<div>${esc(config.domicilio)}</div>` : ""}
  </div>
</div>

<h1>Plan de pago</h1>
<div class="sub">Contrato ${esc(operacion.numero_contrato)} · ${compradores}</div>

<div class="datos">
  <div class="dato"><div class="k">Lote</div><div class="v">${esc(
    [inmueble.lote ? `Lote ${inmueble.lote}` : null, inmueble.manzana ? `Mz. ${inmueble.manzana}` : null,
     inmueble.loteamiento].filter(Boolean).join(" · ") || "—"
  )}</div></div>
  <div class="dato"><div class="k">Precio total</div><div class="v">${gs(operacion.precio_total)}</div></div>
  <div class="dato"><div class="k">Entrega</div><div class="v">${gs(operacion.entrega_inicial)}</div></div>
  <div class="dato"><div class="k">Saldo financiado</div><div class="v">${gs(operacion.monto_financiado)}</div></div>
  <div class="dato"><div class="k">Cuotas</div><div class="v">${pagadas} / ${cuotas.length} pagadas</div></div>
  <div class="dato"><div class="k">Saldo a hoy</div><div class="v">${gs(saldoTotal)}</div></div>
</div>

<table>
  <thead>
    <tr><th>Cuota</th><th>Vence</th><th>Capital</th><th>Recargo</th><th>Importe</th><th>Saldo</th><th>Estado</th></tr>
  </thead>
  <tbody>${filas}</tbody>
  <tfoot>
    <tr>
      <td class="c" colspan="2">Totales</td>
      <td>${gs(cuotas.reduce((a, c) => a + c.capital, 0))}</td>
      <td>${gs(cuotas.reduce((a, c) => a + c.interes, 0))}</td>
      <td>${gs(cuotas.reduce((a, c) => a + c.total, 0))}</td>
      <td>${gs(saldoTotal)}</td>
      <td class="c">${gs(cobrado)} cobrado</td>
    </tr>
  </tfoot>
</table>

<p class="pie">Saldo pendiente a la fecha: <strong>${gs(saldoTotal)}</strong>
(Guaraníes ${esc(guaraniesEnLetras(saldoTotal))}). Los importes no incluyen la mora que pudiera
corresponder por cuotas vencidas, que se calcula al momento del cobro.</p>

<div class="firmas">
  <div class="firma"><div class="linea"></div><div class="rol">${esc(config.razon_social)}</div></div>
  <div class="firma"><div class="linea"></div><div class="rol">EL/LA COMPRADOR/A</div></div>
</div>

</div>
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
