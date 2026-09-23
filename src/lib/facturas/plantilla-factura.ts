import { guaraniesEnLetras } from "@/lib/contratos/numero-a-letras";
import type { LineaImpresa, TotalesFactura } from "./factura-fiscal";

/**
 * Factura autoimpresor DYMA — 3 copias por hoja A4.
 *
 * La clienta imprime en talonario continuo donde entran 3 comprobantes por hoja
 * A4 (~9,6 cm de alto cada uno). Por eso las tres copias —Original, Duplicado y
 * Triplicado de la MISMA factura— se apilan en una sola A4, en vez de una copia
 * por hoja. La emisión fiscal y la impresión son actos separados: esta plantilla
 * no asigna números, solo representa la factura con el número ya emitido.
 *
 * Cada copia mide ~96 mm (≈9,6 cm) de alto; las tres suman ~290 mm y entran en
 * una hoja A4 (297 mm) al imprimir con márgenes en «Ninguno» (por eso el CSS usa
 * `@page{margin:0}`). Se conservan los datos fiscales exigidos: RUC, timbrado,
 * vigencia, establecimiento, punto de expedición, condición, desglose de IVA y
 * total. Con muchos ítems se pagina a más hojas A4 (3 copias por hoja).
 */

// Ítems que entran cómodos en el tercio de hoja. Con más, se pagina a otra A4.
const RENGLONES_POR_TERCIO = 5;

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

const COPIAS = ["ORIGINAL", "DUPLICADO", "TRIPLICADO"];

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

/** dd/mm/aa, para los datos fiscales que van apretados. */
function fmtFechaCorta(ymd: string | null): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd ?? "").slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1].slice(2)}` : "";
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
  for (let i = 0; i < lineas.length; i += RENGLONES_POR_TERCIO) {
    paginas.push(lineas.slice(i, i + RENGLONES_POR_TERCIO));
  }
  return paginas;
}

function filas(lineas: LineaImpresa[], moneda: string): string {
  const prefijo = monedaLabel(moneda);
  return lineas
    .map(
      (l, i) => `<tr>
        <td class="c">${i + 1}</td>
        <td class="desc">${esc(l.descripcion)}</td>
        <td class="c">${esc(l.cantidad)}</td>
        <td class="r">${prefijo} ${num(l.precio_unitario, moneda)}</td>
        <td class="c">${l.tasa}%</td>
        <td class="r b">${prefijo} ${num(l.importe, moneda)}</td>
      </tr>`
    )
    .join("");
}

/**
 * Un tercio de la A4: una copia completa de la factura, compacta.
 */
function copia(
  datos: DatosFactura,
  etiqueta: string,
  lineas: LineaImpresa[],
  pagina: number,
  paginas: number
): string {
  const { emisor, cliente, totales, moneda } = datos;
  const m = monedaLabel(moneda);
  const sinNumerar = !datos.numero;
  const ultima = pagina === paginas;
  const condicion = datos.condicion === "credito" ? "CRÉDITO" : "CONTADO";
  const totalIva = Number(totales.iva_5 || 0) + Number(totales.iva_10 || 0);

  return `<section class="copia">
    <div class="cab">
      <div class="marca">
        ${
          datos.logoUrl
            ? `<img class="logo" src="${esc(datos.logoUrl)}" alt="${esc(emisor.razon_social)}">`
            : `<div class="logo-txt">${esc(emisor.nombre_fantasia || emisor.razon_social)}</div>`
        }
        <div class="rs">${esc(emisor.razon_social)}</div>
        ${emisor.actividad ? `<div class="act">${escLineas(emisor.actividad)}</div>` : ""}
        ${emisor.direccion ? `<div class="dir">${escLineas(emisor.direccion)}</div>` : ""}
        ${emisor.telefono ? `<div class="dir">Cel.: ${esc(emisor.telefono)}</div>` : ""}
      </div>
      <div class="fisc">
        <div class="fr"><span>Timbrado N°</span><b>${esc(emisor.timbrado_numero ?? "—")}</b></div>
        <div class="fr"><span>Inicio vig.</span><b>${esc(fmtFechaCorta(emisor.timbrado_inicio)) || "—"}</b></div>
        <div class="fr"><span>Válido hasta</span><b>${esc(fmtFechaCorta(emisor.timbrado_fin)) || "—"}</b></div>
        <div class="fr"><span>RUC</span><b>${esc(emisor.ruc ?? "—")}</b></div>
        <div class="titulo">FACTURA</div>
        <div class="fnum${sinNumerar ? " sin" : ""}">N° ${esc(datos.numero ?? "SIN NUMERAR")}</div>
        <div class="tag">${esc(etiqueta)}${paginas > 1 ? ` · ${pagina}/${paginas}` : ""}</div>
      </div>
    </div>

    <div class="datos">
      <div class="d1"><span>Fecha de emisión:</span> <b>${esc(fmtFecha(datos.fecha))}</b></div>
      <div class="d2"><span>Cond. de venta:</span> <b>${condicion}</b></div>
      <div class="d3"><span>Nombre o Razón Social:</span> <b>${esc(cliente.nombre)}</b></div>
      <div class="d4"><span>RUC / C.I.:</span> <b>${esc(cliente.ruc ?? "—")}</b></div>
      <div class="d5"><span>Dirección:</span> <b>${esc(cliente.direccion ?? "—")}</b></div>
    </div>

    <table class="items">
      <colgroup><col style="width:6%"><col style="width:46%"><col style="width:8%"><col style="width:16%"><col style="width:8%"><col style="width:16%"></colgroup>
      <thead><tr><th class="c">#</th><th>Descripción</th><th class="c">Cant.</th><th class="r">P. Unit.</th><th class="c">IVA</th><th class="r">Importe</th></tr></thead>
      <tbody>
        ${filas(lineas, moneda)}
        ${lineas.length === 0 ? `<tr><td colspan="6" class="empty">Sin ítems</td></tr>` : ""}
      </tbody>
    </table>

    ${
      ultima
        ? `<div class="pie">
             <div class="letras"><span>Total en letras:</span> ${esc(enLetras(totales.total, moneda))}</div>
             <div class="montos">
               <div><span>Exentas</span><b>${m} ${num(totales.exentas, moneda)}</b></div>
               <div><span>Grav. 5%</span><b>${m} ${num(totales.gravado_5, moneda)}</b></div>
               <div><span>Grav. 10%</span><b>${m} ${num(totales.gravado_10, moneda)}</b></div>
               <div><span>IVA</span><b>${m} ${num(totalIva, moneda)}</b></div>
               <div class="gt"><span>TOTAL</span><b>${m} ${num(totales.total, moneda)}</b></div>
             </div>
           </div>`
        : `<div class="continua">Continúa en la hoja ${pagina + 1}/${paginas} — totales en la última.</div>`
    }
    <div class="etq">${esc(etiqueta)} · Documento emitido por sistema autoimpresor autorizado.</div>
  </section>`;
}

export function plantillaFactura(datos: DatosFactura, opciones?: { autoImprimir?: boolean }): string {
  const titulo = datos.numero ? `Factura ${datos.numero}` : "Factura sin numerar";
  const paginas = paginar(datos.lineas);
  // Cada página de ítems es una hoja A4 con las 3 copias apiladas.
  const hojas = paginas
    .map(
      (ls, i) => `<div class="a4">${COPIAS.map((et) => copia(datos, et, ls, i + 1, paginas.length)).join("")}</div>`
    )
    .join("\n");

  return `<!doctype html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(titulo)}</title>
<style>
  *{box-sizing:border-box}
  html,body{margin:0;padding:0}
  body{background:#eef1f4;color:#18212f;font-family:Arial,Helvetica,sans-serif;line-height:1.2}
  .toolbar{width:210mm;margin:10px auto 0;display:flex;justify-content:flex-end}
  .toolbar button{border:0;border-radius:8px;background:#166c74;color:#fff;padding:9px 18px;font-size:13px;font-weight:700;cursor:pointer}
  .aviso{width:210mm;margin:8px auto 0;padding:9px 14px;border:1px solid #f1c76d;border-radius:8px;background:#fff7df;color:#6f5015;font-size:12px}

  /* Una hoja A4 = 3 copias apiladas (~9,5 cm cada una). Alto automático apenas
     menor que la A4 para que no desborde a una hoja en blanco al imprimir. */
  .a4{width:210mm;margin:10px auto;background:#fff;box-shadow:0 2px 18px rgba(15,23,42,.08);
      display:flex;flex-direction:column;padding:0.6mm 3mm}
  .copia{height:96mm;overflow:hidden;display:flex;flex-direction:column;
         border:1px solid #17323f;border-radius:2mm;padding:2.2mm 3mm;font-size:7.6pt}
  .copia + .copia{margin-top:0.6mm}

  .cab{display:flex;justify-content:space-between;gap:4mm;align-items:flex-start}
  .marca{flex:1;min-width:0}
  .logo{display:block;max-width:44mm;max-height:12mm;object-fit:contain;margin-bottom:1mm}
  .logo-txt{font-size:15pt;font-weight:800;letter-spacing:.02em}
  .rs{font-weight:800;font-size:8.6pt;color:#173a45}
  .act{color:#4b5763;font-size:6.5pt;font-weight:600;line-height:1.15;margin-top:.4mm}
  .dir{color:#5b6672;font-size:6.6pt;line-height:1.2}
  .fisc{width:56mm;flex:none;border:1px solid #17323f;border-radius:1.6mm;padding:1.4mm 2mm;text-align:right}
  .fr{display:flex;justify-content:space-between;gap:3mm;font-size:6.8pt;padding:.15mm 0}
  .fr span{color:#5b6672}
  .fr b{color:#132029}
  .titulo{font-size:13pt;font-weight:800;color:#166c74;letter-spacing:.06em;margin-top:.8mm;text-align:center}
  .fnum{font-size:9pt;font-weight:800;text-align:center;letter-spacing:.03em}
  .fnum.sin{color:#b42318}
  .tag{margin-top:.6mm;font-size:6.4pt;font-weight:800;letter-spacing:.08em;color:#6d7886;text-align:center;text-transform:uppercase}

  .datos{margin-top:1.6mm;display:grid;grid-template-columns:1fr 34mm;gap:.3mm 4mm;
         border-top:1px solid #17323f;border-bottom:1px solid #cfd8dd;padding:1.2mm 0;font-size:7pt}
  .datos span{color:#6a7581}
  .datos b{color:#182430}
  .datos .d1{grid-column:1} .datos .d2{grid-column:2;text-align:right}
  .datos .d3,.datos .d4,.datos .d5{grid-column:1 / -1}

  .items{width:100%;border-collapse:collapse;table-layout:fixed;margin-top:1.4mm}
  .items th{background:#166c74;color:#fff;padding:1mm 1.4mm;font-size:6.6pt;text-transform:uppercase;letter-spacing:.02em;text-align:left}
  .items td{padding:.9mm 1.4mm;border-bottom:1px solid #e8ecef;font-size:7pt;vertical-align:top}
  .items .c{text-align:center}
  .items .r{text-align:right}
  .items .b{font-weight:800}
  .items .desc{overflow-wrap:anywhere}
  .items .empty{text-align:center;color:#8a95a2;padding:4mm}

  .pie{margin-top:auto;display:flex;justify-content:space-between;gap:4mm;align-items:flex-end;padding-top:1.4mm}
  .letras{flex:1;font-size:6.8pt;color:#3a4652;line-height:1.25}
  .letras span{color:#6a7581;font-weight:700}
  .montos{flex:none;width:64mm;display:grid;grid-template-columns:1fr 1fr;gap:.4mm 3mm;font-size:6.8pt}
  .montos>div{display:flex;justify-content:space-between;gap:2mm}
  .montos span{color:#6a7581}
  .montos .gt{grid-column:1 / -1;background:#166c74;color:#fff;border-radius:1mm;padding:.8mm 2mm;font-size:8pt;font-weight:800;margin-top:.6mm}
  .montos .gt span,.montos .gt b{color:#fff}

  .continua{margin-top:auto;text-align:center;color:#65717d;font-size:6.6pt;border:1px dashed #b8c2ca;border-radius:1mm;padding:1.2mm}
  .etq{margin-top:1mm;text-align:center;color:#8a95a2;font-size:5.8pt;letter-spacing:.03em}

  @media print{
    body{background:#fff}
    .toolbar,.aviso{display:none}
    /* Salto SOLO entre hojas (no después de la última): evita la hoja en blanco. */
    .a4{margin:0;box-shadow:none;width:210mm}
    .a4 + .a4{page-break-before:always;break-before:page}
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
