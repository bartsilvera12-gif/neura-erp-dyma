import { guaraniesEnLetras } from "@/lib/contratos/numero-a-letras";
import type { LineaImpresa, TotalesFactura } from "./factura-fiscal";

/**
 * Factura autoimpresor DYMA — modelo provisional Neura, A4 vertical.
 *
 * La emisión fiscal y la impresión son actos separados. Esta plantilla no
 * asigna números: solo representa la factura con el número ya emitido.
 *
 * El diseño prioriza lectura y jerarquía visual, manteniendo los datos fiscales
 * exigidos para el autoimpresor: RUC, timbrado, vigencia, establecimiento,
 * punto de expedición, condición, desglose de IVA y total en letras.
 */

const RENGLONES_POR_PAGINA = 16;

export interface EmisorFactura {
  razon_social: string;
  nombre_fantasia: string | null;
  actividad: string | null;
  ruc: string | null;
  direccion: string | null;
  telefono: string | null;
  timbrado_numero: string | null;
  timbrado_inicio: string | null;
  timbrado_fin: string | null;
  establecimiento: string | null;
  punto_expedicion: string | null;
}

export interface ClienteFactura {
  nombre: string;
  ruc: string | null;
  telefono: string | null;
  direccion: string | null;
  observacion: string | null;
}

export interface DatosFactura {
  emisor: EmisorFactura;
  logoUrl?: string;
  /** Número fiscal ya asignado, o null si todavía no se emitió. */
  numero: string | null;
  fecha: string;
  condicion: "contado" | "credito";
  moneda: string;
  cliente: ClienteFactura;
  lineas: LineaImpresa[];
  totales: TotalesFactura;
}

const COPIAS = [
  "ORIGINAL · CLIENTE",
  "DUPLICADO · ARCHIVO TRIBUTARIO",
  "TRIPLICADO · CONTABILIDAD",
];

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function escLineas(v: unknown): string {
  return esc(v).replace(/\r?\n/g, "<br>");
}

function fmtFecha(ymd: string | null): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd ?? "").slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "";
}

function num(n: number, moneda: string): string {
  const v = Number(n) || 0;
  if (moneda === "USD") {
    return v.toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  return Math.round(v).toLocaleString("es-PY");
}

function monedaLabel(moneda: string): string {
  return moneda === "USD" ? "USD" : "Gs.";
}

function enLetras(total: number, moneda: string): string {
  if (!(total > 0)) return "";
  const palabras = guaraniesEnLetras(Math.round(total));
  return `${palabras} ${moneda === "USD" ? "dólares americanos" : "guaraníes"}`;
}

function paginar(lineas: LineaImpresa[]): LineaImpresa[][] {
  if (lineas.length === 0) return [[]];
  const paginas: LineaImpresa[][] = [];
  for (let i = 0; i < lineas.length; i += RENGLONES_POR_PAGINA) {
    paginas.push(lineas.slice(i, i + RENGLONES_POR_PAGINA));
  }
  return paginas;
}

function filas(lineas: LineaImpresa[], moneda: string): string {
  const prefijo = monedaLabel(moneda);
  return lineas
    .map(
      (l, i) => `<tr>
        <td class="center">${i + 1}</td>
        <td class="desc">${esc(l.descripcion)}</td>
        <td class="center">${esc(l.cantidad)}</td>
        <td class="right">${prefijo} ${num(l.precio_unitario, moneda)}</td>
        <td class="center">${l.tasa}%</td>
        <td class="right strong">${prefijo} ${num(l.importe, moneda)}</td>
      </tr>`
    )
    .join("");
}

function bloqueTotales(t: TotalesFactura, moneda: string): string {
  const m = monedaLabel(moneda);
  const totalIva = Number(t.iva_5 || 0) + Number(t.iva_10 || 0);
  return `<div class="totales-wrap">
    <div class="total-letras">
      <div class="label">TOTAL A PAGAR EN LETRAS</div>
      <div class="words">${esc(enLetras(t.total, moneda))}</div>
      <div class="iva-resumen">
        <span>IVA 5%: <strong>${m} ${num(t.iva_5, moneda)}</strong></span>
        <span>IVA 10%: <strong>${m} ${num(t.iva_10, moneda)}</strong></span>
        <span>Total IVA: <strong>${m} ${num(totalIva, moneda)}</strong></span>
      </div>
    </div>
    <div class="totales">
      <div><span>Exentas</span><strong>${m} ${num(t.exentas, moneda)}</strong></div>
      <div><span>Gravadas 5%</span><strong>${m} ${num(t.gravado_5, moneda)}</strong></div>
      <div><span>Gravadas 10%</span><strong>${m} ${num(t.gravado_10, moneda)}</strong></div>
      <div class="gran-total"><span>TOTAL</span><strong>${m} ${num(t.total, moneda)}</strong></div>
    </div>
  </div>`;
}

function hoja(
  datos: DatosFactura,
  copia: string,
  lineas: LineaImpresa[],
  pagina: number,
  paginas: number
): string {
  const { emisor, cliente, totales, moneda } = datos;
  const sinNumerar = !datos.numero;
  const ultima = pagina === paginas;
  const condicion = datos.condicion === "credito" ? "CRÉDITO" : "CONTADO";

  return `<section class="hoja">
    <header class="top">
      <div class="brand">
        ${
          datos.logoUrl
            ? `<img class="logo" src="${esc(datos.logoUrl)}" alt="${esc(emisor.razon_social)}">`
            : `<div class="logo-text">${esc(emisor.nombre_fantasia || emisor.razon_social)}</div>`
        }
        <div class="emisor-name">${esc(emisor.razon_social)}</div>
        ${emisor.actividad ? `<div class="muted activity">${escLineas(emisor.actividad)}</div>` : ""}
        ${emisor.direccion ? `<div class="muted">${escLineas(emisor.direccion)}</div>` : ""}
        ${emisor.telefono ? `<div class="muted">Tel.: ${esc(emisor.telefono)}</div>` : ""}
      </div>

      <div class="doc">
        <div class="copy">${esc(copia)}${paginas > 1 ? ` · HOJA ${pagina}/${paginas}` : ""}</div>
        <h1>FACTURA</h1>
        <div class="numero${sinNumerar ? " sin-numero" : ""}">N° ${esc(datos.numero ?? "SIN NUMERAR")}</div>
        <div class="fiscal">
          <div><span>RUC</span><strong>${esc(emisor.ruc ?? "—")}</strong></div>
          <div><span>Timbrado</span><strong>${esc(emisor.timbrado_numero ?? "—")}</strong></div>
          <div><span>Vigencia</span><strong>${esc(fmtFecha(emisor.timbrado_inicio)) || "—"} al ${esc(fmtFecha(emisor.timbrado_fin)) || "—"}</strong></div>
          <div><span>Est. / P. Exp.</span><strong>${esc(emisor.establecimiento ?? "—")} / ${esc(emisor.punto_expedicion ?? "—")}</strong></div>
        </div>
      </div>
    </header>

    <div class="rule"></div>

    <section class="meta">
      <div class="meta-left">
        <div class="field"><span>Cliente</span><strong>${esc(cliente.nombre)}</strong></div>
        <div class="field"><span>RUC / C.I.</span><strong>${esc(cliente.ruc ?? "—")}</strong></div>
        <div class="field"><span>Dirección</span><strong>${esc(cliente.direccion ?? "—")}</strong></div>
        ${cliente.telefono ? `<div class="field"><span>Teléfono</span><strong>${esc(cliente.telefono)}</strong></div>` : ""}
      </div>
      <div class="meta-right">
        <div class="field"><span>Fecha de emisión</span><strong>${esc(fmtFecha(datos.fecha))}</strong></div>
        <div class="field"><span>Condición de venta</span><strong>${condicion}</strong></div>
        <div class="field"><span>Moneda</span><strong>${esc(moneda === "USD" ? "Dólares americanos" : "Guaraníes")}</strong></div>
        ${cliente.observacion ? `<div class="field"><span>Observación</span><strong>${esc(cliente.observacion)}</strong></div>` : ""}
      </div>
    </section>

    <table class="items">
      <colgroup>
        <col style="width:7%">
        <col style="width:42%">
        <col style="width:10%">
        <col style="width:16%">
        <col style="width:9%">
        <col style="width:16%">
      </colgroup>
      <thead>
        <tr>
          <th>#</th>
          <th>Descripción</th>
          <th>Cant.</th>
          <th>Precio unitario</th>
          <th>IVA</th>
          <th>Importe</th>
        </tr>
      </thead>
      <tbody>
        ${filas(lineas, moneda)}
        ${lineas.length === 0 ? `<tr><td colspan="6" class="empty">Sin ítems</td></tr>` : ""}
      </tbody>
    </table>

    ${
      ultima
        ? bloqueTotales(totales, moneda)
        : `<div class="continua">Continúa en la hoja ${pagina + 1} de ${paginas}. Los totales se muestran en la última hoja.</div>`
    }

    <footer>
      <div>Documento emitido por sistema autoimpresor autorizado.</div>
      <div class="footer-copy">${esc(copia)}</div>
    </footer>
  </section>`;
}

export function plantillaFactura(datos: DatosFactura, opciones?: { autoImprimir?: boolean }): string {
  const titulo = datos.numero ? `Factura ${datos.numero}` : "Factura sin numerar";
  const paginas = paginar(datos.lineas);
  const hojas = COPIAS.map((copia) =>
    paginas.map((ls, i) => hoja(datos, copia, ls, i + 1, paginas.length)).join("\n")
  ).join("\n");

  return `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(titulo)}</title>
<style>
  *{box-sizing:border-box}
  html,body{margin:0;padding:0}
  body{background:#eef1f4;color:#18212f;font-family:Arial,Helvetica,sans-serif;font-size:10.5pt;line-height:1.35}
  .toolbar{width:210mm;margin:12px auto 0;display:flex;justify-content:flex-end}
  .toolbar button{border:0;border-radius:8px;background:#166c74;color:#fff;padding:9px 18px;font-size:13px;font-weight:700;cursor:pointer}
  .aviso{width:210mm;margin:8px auto 0;padding:10px 14px;border:1px solid #f1c76d;border-radius:8px;background:#fff7df;color:#6f5015;font-size:12px}

  .hoja{width:210mm;min-height:297mm;margin:12px auto;background:#fff;padding:17mm 16mm 14mm;display:flex;flex-direction:column;box-shadow:0 2px 18px rgba(15,23,42,.08);break-after:page}
  .hoja:last-of-type{break-after:auto}
  .top{display:flex;justify-content:space-between;gap:22mm;align-items:flex-start}
  .brand{flex:1;min-width:0}
  .logo{display:block;max-width:58mm;max-height:21mm;object-fit:contain;margin-bottom:5mm}
  .logo-text{font-size:24pt;font-weight:800;letter-spacing:.02em;margin-bottom:4mm}
  .emisor-name{font-weight:800;font-size:11pt;margin-bottom:2mm}
  .muted{color:#637081;font-size:8.5pt;line-height:1.35}
  .activity{font-weight:600;margin-bottom:1mm}

  .doc{width:76mm;text-align:right}
  .copy{font-size:7.5pt;font-weight:700;letter-spacing:.07em;color:#6d7886;text-transform:uppercase;margin-bottom:2mm}
  .doc h1{margin:0;color:#166c74;font-size:28pt;letter-spacing:.04em;line-height:1}
  .numero{margin-top:2mm;font-size:13pt;font-weight:800;letter-spacing:.04em}
  .sin-numero{color:#b42318}
  .fiscal{margin-top:5mm;border:1px solid #d9e0e5;border-radius:8px;padding:3mm 4mm;text-align:left;background:#fafcfc}
  .fiscal div{display:flex;justify-content:space-between;gap:5mm;padding:1.2mm 0;font-size:8.3pt;border-bottom:1px solid #edf1f3}
  .fiscal div:last-child{border-bottom:0}
  .fiscal span{color:#697684}
  .fiscal strong{text-align:right;color:#1b2633}

  .rule{height:2px;background:#166c74;margin:8mm 0 6mm}
  .meta{display:grid;grid-template-columns:1.35fr 1fr;gap:18mm;margin-bottom:7mm}
  .field{display:grid;grid-template-columns:31mm 1fr;gap:3mm;padding:1.5mm 0;border-bottom:1px solid #edf0f2}
  .field span{color:#778290;font-size:8.6pt}
  .field strong{font-size:9pt;font-weight:700;color:#222d3a;overflow-wrap:anywhere}

  .items{width:100%;border-collapse:collapse;table-layout:fixed}
  .items thead th{background:#166c74;color:#fff;padding:3.3mm 2.2mm;font-size:8.4pt;text-transform:uppercase;letter-spacing:.03em;text-align:left}
  .items thead th:first-child{border-radius:6px 0 0 0}
  .items thead th:last-child{border-radius:0 6px 0 0;text-align:right}
  .items thead th:nth-child(1),.items thead th:nth-child(3),.items thead th:nth-child(5){text-align:center}
  .items thead th:nth-child(4){text-align:right}
  .items td{padding:3.2mm 2.2mm;border-bottom:1px solid #e8ecef;font-size:9pt;vertical-align:top}
  .items .center{text-align:center}
  .items .right{text-align:right}
  .items .strong{font-weight:800}
  .items .desc{overflow-wrap:anywhere}
  .items .empty{text-align:center;color:#8a95a2;padding:12mm}

  .totales-wrap{margin-top:auto;padding-top:8mm;display:grid;grid-template-columns:1fr 65mm;gap:14mm;align-items:start}
  .total-letras{border-top:2px solid #166c74;padding-top:4mm}
  .total-letras .label{font-size:7.5pt;font-weight:800;color:#62707e;letter-spacing:.05em}
  .total-letras .words{font-size:10pt;font-weight:700;margin-top:2mm;text-transform:uppercase;line-height:1.45}
  .iva-resumen{display:flex;flex-wrap:wrap;gap:3mm 8mm;margin-top:5mm;color:#697684;font-size:8.2pt}
  .iva-resumen strong{color:#1d2835}
  .totales{border:1px solid #dce2e6;border-radius:8px;overflow:hidden}
  .totales>div{display:flex;justify-content:space-between;gap:5mm;padding:2.7mm 4mm;border-bottom:1px solid #e6eaed;font-size:9pt}
  .totales>div:last-child{border-bottom:0}
  .totales span{color:#667381}
  .gran-total{background:#166c74;color:#fff!important;padding:4mm!important;font-size:12pt!important}
  .gran-total span,.gran-total strong{color:#fff!important}

  .continua{margin-top:auto;padding:5mm;border:1px dashed #b8c2ca;border-radius:6px;text-align:center;color:#65717d;font-size:9pt}
  footer{margin-top:10mm;padding-top:4mm;border-top:1px solid #e3e7ea;display:flex;justify-content:space-between;color:#7a8692;font-size:7.5pt}
  .footer-copy{font-weight:700;text-transform:uppercase}

  @media print{
    body{background:#fff}
    .toolbar,.aviso{display:none}
    .hoja{margin:0;box-shadow:none;width:210mm;min-height:297mm;page-break-after:always}
    .hoja:last-of-type{page-break-after:auto}
    @page{size:A4 portrait;margin:0}
  }
</style>
</head>
<body>
<div class="toolbar"><button onclick="window.print()">Imprimir factura</button></div>
${
  datos.numero
    ? ""
    : `<div class="aviso"><strong>Vista previa sin numerar.</strong> Esta factura todavía no tiene número fiscal. Para emitirla, volvé al detalle y usá <em>Emitir e imprimir</em>.</div>`
}
${hojas}
<script>try{if(${opciones?.autoImprimir ? "true" : "false"}) window.print()}catch(e){}</script>
</body>
</html>`;
}
