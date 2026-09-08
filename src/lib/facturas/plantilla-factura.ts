import { guaraniesEnLetras } from "@/lib/contratos/numero-a-letras";
import type { LineaImpresa, TotalesFactura } from "./factura-fiscal";

/**
 * La factura de DYMA impresa por autoimpresor, en media hoja (8,5" x 5,5").
 *
 * Reproduce el talonario preimpreso que hoy se llena a mano: mismo membrete,
 * misma caja de timbrado, misma grilla con las tres columnas de venta y la
 * liquidación del IVA abajo. La diferencia es que acá lo imprime el sistema
 * sobre papel en blanco, incluido el número.
 *
 * Se imprimen tres ejemplares, uno por hoja, cada uno rotulado en el margen
 * derecho: original al cliente, duplicado al archivo tributario y triplicado sin
 * valor para crédito fiscal.
 *
 * La grilla tiene una cantidad fija de renglones aunque sobren: el formulario en
 * papel se ve así y el vacío es lo que impide que alguien agregue una línea a
 * mano después de impresa.
 *
 * Si los ítems no entran en una hoja, la factura sigue en la siguiente con el
 * mismo número, y los totales van solo en la última. Antes el sobrante quedaba
 * recortado por el alto fijo de la media hoja: la línea desaparecía del papel
 * pero seguía sumando en el total, que es la peor forma de fallar que puede
 * tener un documento fiscal.
 *
 * Función pura: recibe datos y devuelve HTML.
 */

const RENGLONES = 6;

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
  "ORIGINAL: CLIENTE",
  "DUPLICADO: ARCHIVO TRIBUTARIO",
  "TRIPLICADO: (NO VÁLIDO PARA CRÉDITO FISCAL)",
];

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Texto con saltos de línea reales, como la actividad económica o la dirección. */
function escLineas(v: unknown): string {
  return esc(v).replace(/\r?\n/g, "<br>");
}

function fmtFecha(ymd: string | null): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd ?? "").slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "";
}

/** Importes sin símbolo: la moneda ya está declarada en la cabecera. */
function num(n: number, moneda: string): string {
  const v = Number(n) || 0;
  if (v === 0) return "";
  return moneda === "USD" ? v.toLocaleString("en-US", { minimumFractionDigits: 2 }) : Math.round(v).toLocaleString("es-PY");
}

function enLetras(total: number, moneda: string): string {
  if (!(total > 0)) return "";
  const palabras = guaraniesEnLetras(Math.round(total));
  return `${palabras} ${moneda === "USD" ? "dólares americanos" : "guaraníes"}`;
}

function tilde(marcado: boolean): string {
  return `<span class="box">${marcado ? "X" : "&nbsp;"}</span>`;
}

/** Los ítems repartidos en hojas de `RENGLONES` renglones. Siempre al menos una. */
function paginar(lineas: LineaImpresa[]): LineaImpresa[][] {
  if (lineas.length === 0) return [[]];
  const paginas: LineaImpresa[][] = [];
  for (let i = 0; i < lineas.length; i += RENGLONES) paginas.push(lineas.slice(i, i + RENGLONES));
  return paginas;
}

function filas(lineas: LineaImpresa[], moneda: string): string {
  const html: string[] = [];
  for (let i = 0; i < RENGLONES; i++) {
    const l = lineas[i];
    if (!l) {
      html.push(`<tr class="vacia"><td></td><td></td><td></td><td></td><td></td><td></td></tr>`);
      continue;
    }
    html.push(`<tr>
      <td class="c">${esc(l.cantidad)}</td>
      <td class="desc">${esc(l.descripcion)}</td>
      <td class="n">${num(l.precio_unitario, moneda)}</td>
      <td class="n">${l.tasa === 0 ? num(l.importe, moneda) : ""}</td>
      <td class="n">${l.tasa === 5 ? num(l.importe, moneda) : ""}</td>
      <td class="n">${l.tasa === 10 ? num(l.importe, moneda) : ""}</td>
    </tr>`);
  }
  return html.join("");
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
  const rotulo = paginas > 1 ? `${copia} · Hoja ${pagina} de ${paginas}` : copia;

  return `<section class="hoja">
  <div class="lateral">${esc(rotulo)}</div>
  <div class="cuerpo">

    <div class="cabecera">
      <div class="emisor">
        ${
          datos.logoUrl
            ? `<img class="logo" src="${esc(datos.logoUrl)}" alt="${esc(emisor.razon_social)}">`
            : `<div class="logo-txt">${esc(emisor.nombre_fantasia || emisor.razon_social)}</div>`
        }
        <div class="razon">${esc(emisor.razon_social)}</div>
        ${emisor.actividad ? `<div class="actividad">${escLineas(emisor.actividad)}</div>` : ""}
        ${emisor.telefono ? `<div class="contacto">Cel.: ${esc(emisor.telefono)}</div>` : ""}
        ${emisor.direccion ? `<div class="contacto">${escLineas(emisor.direccion)}</div>` : ""}
      </div>

      <div class="timbrado">
        <div><strong>TIMBRADO N° ${esc(emisor.timbrado_numero ?? "—")}</strong></div>
        <div>Fecha Inicio Vigencia: ${esc(fmtFecha(emisor.timbrado_inicio)) || "—"}</div>
        <div>Válido hasta: ${esc(fmtFecha(emisor.timbrado_fin)) || "—"}</div>
        <div class="ruc">RUC: ${esc(emisor.ruc ?? "—")}</div>
        <div class="titulo">FACTURA</div>
        <div class="numero${sinNumerar ? " sin-numero" : ""}">N° ${esc(datos.numero ?? "SIN NUMERAR")}</div>
      </div>

      <div class="condicion">
        <div>${tilde(datos.condicion === "contado")} <span>CONTADO</span></div>
        <div>${tilde(datos.condicion === "credito")} <span>CRÉDITO</span></div>
      </div>
    </div>

    <table class="receptor">
      <tr>
        <td class="k">Fecha de Emisión:</td><td class="v">${esc(fmtFecha(datos.fecha))}</td>
        <td class="k">RUC:</td><td class="v">${esc(cliente.ruc ?? "")}</td>
      </tr>
      <tr>
        <td class="k">Señor(es):</td><td class="v">${esc(cliente.nombre)}</td>
        <td class="k">Tel.:</td><td class="v">${esc(cliente.telefono ?? "")}</td>
      </tr>
      <tr>
        <td class="k">Observación:</td><td class="v">${esc(cliente.observacion ?? "")}</td>
        <td class="k">Dirección:</td><td class="v">${esc(cliente.direccion ?? "")}</td>
      </tr>
    </table>

    <table class="detalle">
      <thead>
        <tr>
          <th rowspan="2" class="w-cant">Cantidad</th>
          <th rowspan="2">Clase de mercaderías y/o servicios</th>
          <th rowspan="2" class="w-pu">Precio<br>Unitario</th>
          <th colspan="3" class="ventas">V E N T A S</th>
        </tr>
        <tr>
          <th class="w-col">Exentas</th>
          <th class="w-col">5%</th>
          <th class="w-col">10%</th>
        </tr>
      </thead>
      <tbody>${filas(lineas, moneda)}</tbody>
      <tfoot>
        ${
          ultima
            ? `<tr>
          <td colspan="2" rowspan="2" class="letras">
            <span class="rot">TOTAL A PAGAR (en letras)</span>
            <span class="valor">${esc(enLetras(totales.total, moneda))}</span>
          </td>
          <td class="rot">SUB TOTALES</td>
          <td class="n">${num(totales.exentas, moneda)}</td>
          <td class="n">${num(totales.gravado_5, moneda)}</td>
          <td class="n">${num(totales.gravado_10, moneda)}</td>
        </tr>
        <tr>
          <td class="rot total">TOTAL</td>
          <td colspan="3" class="n total">${num(totales.total, moneda)}</td>
        </tr>`
            : `<tr>
          <td colspan="6" class="rot sigue">CONTINÚA EN LA HOJA ${pagina + 1} DE ${paginas} — LOS TOTALES VAN EN LA ÚLTIMA</td>
        </tr>`
        }
      </tfoot>
    </table>

    <div class="liquidacion">
      ${
        ultima
          ? `Liquidación del IVA: (5%) <u>&nbsp;${num(totales.iva_5, moneda) || "&nbsp;".repeat(8)}&nbsp;</u>
      &nbsp;&nbsp;(10%) <u>&nbsp;${num(totales.iva_10, moneda) || "&nbsp;".repeat(8)}&nbsp;</u>
      &nbsp;&nbsp;TOTAL: <u>&nbsp;${num(totales.iva_5 + totales.iva_10, moneda) || "&nbsp;".repeat(8)}&nbsp;</u>`
          : `Liquidación del IVA: se detalla en la hoja ${paginas} de ${paginas}.`
      }
    </div>

    <p class="mora">La falta de pago de esta factura a su vencimiento devengará un interés del ____ % mensual.
    El simple vencimiento establecerá la mora, autorizando la consulta como la inclusión a la Base de datos de
    Informaciones Comerciales, conforme a lo establecido en la ley 1682, como también para que se pueda proveer
    información a terceros interesados.</p>

    <div class="firmas">
      <div>C.I. N°: ______________________</div>
      <div>Firma: ______________________</div>
      <div>Aclaración de Firma: ______________________</div>
    </div>

  </div>
</section>`;
}

export function plantillaFactura(datos: DatosFactura, opciones?: { autoImprimir?: boolean }): string {
  const titulo = datos.numero ? `Factura ${datos.numero}` : "Factura sin numerar";

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(titulo)}</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{background:#e5e7eb;font-family:Arial,Helvetica,sans-serif;color:#000;font-size:7.5pt;line-height:1.2}

  /* Media hoja apaisada: 8,5" de ancho por 5,5" de alto. */
  .hoja{width:8.5in;height:5.5in;background:#fff;margin:10px auto;padding:.18in;display:flex;gap:.06in;overflow:hidden}
  .cuerpo{flex:1;display:flex;flex-direction:column;min-width:0}

  /* El rótulo del ejemplar, en vertical contra el margen derecho. */
  .lateral{order:2;width:.16in;font-size:5.2pt;letter-spacing:.04em;font-weight:700;
    writing-mode:vertical-rl;text-orientation:mixed;transform:rotate(180deg);
    display:flex;align-items:center;justify-content:center;white-space:nowrap;color:#111}

  .cabecera{display:flex;border:1.2px solid #000;min-height:.86in}
  .emisor{flex:1.55;padding:3px 6px;border-right:1.2px solid #000;min-width:0}
  .emisor .logo{max-height:.34in;max-width:1.7in;object-fit:contain;display:block;margin-bottom:1px}
  .emisor .logo-txt{font-size:13pt;font-weight:800;letter-spacing:.02em}
  .emisor .razon{font-size:8.5pt;font-weight:800}
  .emisor .actividad{font-size:6pt;font-weight:700;margin-top:1px}
  .emisor .contacto{font-size:6pt;margin-top:1px}

  .timbrado{flex:1;padding:3px 6px;border-right:1.2px solid #000;text-align:center;font-size:7pt}
  .timbrado .ruc{font-weight:800;font-style:italic;margin-top:1px}
  .timbrado .titulo{font-size:12pt;font-weight:800;font-style:italic;letter-spacing:.02em}
  .timbrado .numero{font-size:9.5pt;font-weight:800}
  .timbrado .sin-numero{color:#b91c1c}

  .condicion{width:1.25in;padding:6px;display:flex;flex-direction:column;justify-content:center;gap:9px;font-size:9pt;font-weight:700}
  .condicion div{display:flex;align-items:center;gap:5px}
  .box{display:inline-block;width:13px;height:13px;border:1.2px solid #000;text-align:center;line-height:11px;font-size:9pt;font-weight:800}

  .receptor{width:100%;border-collapse:collapse;border:1.2px solid #000;border-top:0;table-layout:fixed}
  .receptor td{border:.6px solid #000;padding:2px 5px;height:.19in;font-size:7.5pt}
  .receptor .k{width:1.05in;font-weight:600;border-right:0}
  .receptor .v{border-left:0}

  .detalle{width:100%;border-collapse:collapse;border:1.2px solid #000;border-top:0;table-layout:fixed;flex:1}
  .detalle th,.detalle td{border:.6px solid #000;padding:1px 4px;font-size:7.5pt;vertical-align:top}
  .detalle th{text-align:center;font-weight:700;font-size:7pt;background:#fff}
  .detalle .ventas{letter-spacing:.28em;font-weight:800}
  .detalle .w-cant{width:.72in} .detalle .w-pu{width:.86in} .detalle .w-col{width:.86in}
  .detalle td.c{text-align:center} .detalle td.n{text-align:right}
  .detalle tr.vacia td{height:.27in}
  /* Dos líneas como máximo: una descripción larguísima no puede empujar el
     renglón siguiente fuera de la media hoja. */
  .detalle .desc{display:-webkit-box;-webkit-line-clamp:2;-webkit-box-orient:vertical;overflow:hidden;word-break:break-word}
  .detalle .sigue{font-style:italic;letter-spacing:.04em}
  .detalle tfoot td{height:.22in;font-weight:700}
  .detalle .rot{font-size:7pt;font-weight:700;text-align:center}
  .detalle .letras{vertical-align:top}
  .detalle .letras .rot{display:block;text-align:left;font-size:6.5pt}
  .detalle .letras .valor{display:block;font-weight:400;font-size:7.5pt;margin-top:1px}
  .detalle .total{font-size:9pt;font-weight:800}

  .liquidacion{border:1.2px solid #000;border-top:0;padding:2px 5px;font-size:7pt;font-weight:600}
  .mora{margin:2px 0 0;font-size:5.6pt;line-height:1.25;text-align:justify}
  .firmas{display:flex;justify-content:space-between;gap:10px;margin-top:auto;padding-top:4px;font-size:6.5pt}

  .toolbar{max-width:8.5in;margin:10px auto 0;text-align:right}
  .toolbar button{font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer;font-family:inherit}
  .aviso{max-width:8.5in;margin:8px auto 0;padding:8px 12px;border-radius:8px;background:#fef3c7;border:1px solid #fbbf24;font-size:11px;line-height:1.4}

  @media print{
    body{background:#fff}
    .toolbar,.aviso{display:none}
    .hoja{margin:0;box-shadow:none;break-after:page}
    .hoja:last-of-type{break-after:auto}
    @page{size:8.5in 5.5in;margin:0}
  }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir factura</button></div>
${
  datos.numero
    ? ""
    : `<div class="aviso"><strong>Todavía sin numerar.</strong> Esta hoja es una vista previa: no lleva número fiscal y no se puede entregar al cliente. Volvé a la factura y usá <em>Emitir e imprimir</em> para asignarle el número del timbrado.</div>`
}
${(() => {
  const paginas = paginar(datos.lineas);
  return COPIAS.map((c) => paginas.map((ls, i) => hoja(datos, c, ls, i + 1, paginas.length)).join("\n")).join("\n");
})()}
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
