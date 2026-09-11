import { fechaEnLetras, guaraniesEnLetras } from "./numero-a-letras";
import type { Pagare } from "./pagares";
import type { DatosContrato } from "./types";

/**
 * Pagarés a la orden del contrato, uno por hoja.
 *
 * Documento aparte del contrato porque se firma aparte y a veces se guarda en
 * otro lado: el contrato queda en la carpeta del cliente y los pagarés en la
 * caja fuerte, que es como trabaja el negocio.
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

function d(v: unknown, largo = 24): string {
  const s = String(v ?? "").trim();
  return s ? esc(s) : "_".repeat(largo);
}

function gs(n: number): string {
  return `Gs. ${Math.round(Number(n) || 0).toLocaleString("es-PY")}`;
}

function fmtFecha(ymd: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd).slice(0, 10));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : "____/____/______";
}

export function plantillaPagares(
  datos: DatosContrato,
  pagares: Pagare[],
  opciones?: { autoImprimir?: boolean; titulo?: string }
): string {
  const { config, comprador, conyuge, codeudores, operacion, inmueble } = datos;

  const deudores = [comprador, ...(conyuge ? [conyuge] : [])];
  const plural = deudores.length > 1;

  const nombresDeudores = deudores
    .map((p) => `<strong>${d(p.nombre, 34)}</strong>, con C.I. N°/RUC N° ${d(p.documento, 14)}`)
    .join(" y ");

  const avales =
    codeudores.length > 0
      ? `<p class="aval">Avala${codeudores.length === 1 ? "" : "n"} solidariamente esta obligación, con renuncia a los
         beneficios de excusión y división: ${codeudores
           .map((c) => `<strong>${d(c.nombre, 30)}</strong> (C.I. N°/RUC N° ${d(c.documento, 14)})`)
           .join(", ")}.</p>`
      : "";

  const firmasDe = [
    { rol: plural ? "DEUDOR/A TITULAR" : "EL/LA DEUDOR/A", pie: comprador.nombre },
    ...(conyuge ? [{ rol: "CÓNYUGE CODEUDOR/A", pie: conyuge.nombre }] : []),
    ...codeudores.map((c) => ({ rol: "AVALISTA SOLIDARIO/A", pie: c.nombre })),
  ];

  const hojas = pagares
    .map((p) => {
      const cuotasTxt =
        p.cuotas.length === 1
          ? `la cuota N° ${p.cuotas[0]}`
          : `las cuotas N° ${p.cuotas[0]} a ${p.cuotas[p.cuotas.length - 1]} (${p.cuotas.length} cuotas)`;

      const firmas = firmasDe
        .map(
          (f) => `<div class="firma">
          <div class="linea"></div>
          <div class="rol">${esc(f.rol)}</div>
          <div class="pie">${esc(f.pie)}</div>
        </div>`
        )
        .join("");

      // El sello va impreso: es la marca que dice que este papel se devuelve.
      // El avance de un pagaré en curso, en cambio, es solo para la pantalla:
      // no corresponde agregarle anotaciones a un título que el deudor firmó.
      const sello =
        p.estado === "cancelado"
          ? `<div class="sello" aria-hidden="true">CANCELADO</div>
  <p class="nota-cancelado">Cancelado${
            p.cancelado_el ? ` el ${esc(fmtFecha(p.cancelado_el))}` : ""
          }: todas sus cuotas están pagadas. Corresponde devolverlo al deudor.</p>`
          : p.estado === "anulado"
            ? `<div class="sello anulado" aria-hidden="true">ANULADO</div>
  <p class="nota-cancelado">Sus cuotas fueron anuladas: no queda nada por cobrar con este pagaré.</p>`
            : p.estado === "parcial"
              ? `<p class="avance">En curso: pagadas ${p.cuotas_pagadas} de ${p.cuotas.length} cuota${
                  p.cuotas.length === 1 ? "" : "s"
                }. Resta ${gs(p.saldo)}.</p>`
              : "";

      return `<section class="pagare pagare-${p.estado}">
  ${sello}
  <div class="cab">
    <div>
      <div class="tipo">Pagaré a la orden</div>
      <div class="num">N° ${esc(p.numero)}</div>
    </div>
    <div class="importe">
      <div class="lbl">Importe</div>
      <div class="val">${gs(p.monto)}</div>
    </div>
  </div>

  <p>En ${d(config.ciudad_firma, 18)}, ${esc(fechaEnLetras(operacion.fecha_venta) || "____ de ____________ de ____")},
  ${plural ? "los abajo firmantes se obligan" : "el/la abajo firmante se obliga"} a pagar incondicionalmente
  a la orden de <strong>${esc(config.razon_social)}</strong>${config.ruc ? `, RUC N° ${esc(config.ruc)}` : ""},
  o a su orden, la suma de <strong>${gs(p.monto)}</strong>
  (Guaraníes ${esc(guaraniesEnLetras(p.monto))}), pagadera el
  <strong>${esc(fmtFecha(p.vencimiento))}</strong>, sin protesto.</p>

  <p>${plural ? "Deudores" : "Deudor"}: ${nombresDeudores}.</p>

  ${avales}

  <table class="ref">
    <tr><th>Contrato</th><td>${esc(operacion.numero_contrato)}</td>
        <th>Período</th><td>${esc(fmtFecha(p.desde))} — ${esc(fmtFecha(p.vencimiento))}</td></tr>
    <tr><th>Concepto</th><td colspan="3">Saldo de precio del ${
        inmueble.lote ? `Lote ${esc(inmueble.lote)}` : "lote"
      }${inmueble.manzana ? `, Manzana ${esc(inmueble.manzana)}` : ""}${
        inmueble.loteamiento ? `, ${esc(inmueble.loteamiento)}` : ""
      } — ${esc(cuotasTxt)}</td></tr>
  </table>

  <p class="mora">La falta de pago a su vencimiento constituye en mora de pleno derecho, sin necesidad de
  interpelación alguna, y devengará los intereses moratorios y punitorios pactados en la Cláusula Quinta del
  contrato ${esc(operacion.numero_contrato)}. Este pagaré es título ejecutivo y no requiere protesto.</p>

  <div class="firmas">${firmas}</div>
</section>`;
    })
    .join("");

  const cuenta = (e: Pagare["estado"]) => pagares.filter((p) => p.estado === e).length;
  const cancelados = cuenta("cancelado");
  const parciales = cuenta("parcial");
  const vigentes = cuenta("vigente");
  const anulados = cuenta("anulado");
  const resumenHtml = `<div class="resumen">
  <h1>${esc(opciones?.titulo ?? "Pagarés")} · ${esc(operacion.numero_contrato)}</h1>
  <span>${pagares.length} pagaré${pagares.length === 1 ? "" : "s"}</span>
  ${cancelados ? `<span class="chip cancelado">${cancelados} cancelado${cancelados === 1 ? "" : "s"} — para devolver</span>` : ""}
  ${parciales ? `<span class="chip parcial">${parciales} en curso</span>` : ""}
  ${vigentes ? `<span class="chip">${vigentes} vigente${vigentes === 1 ? "" : "s"}</span>` : ""}
  ${anulados ? `<span class="chip">${anulados} anulado${anulados === 1 ? "" : "s"}</span>` : ""}
</div>`;

  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(opciones?.titulo ?? "Pagarés")} ${esc(operacion.numero_contrato)}</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:"Times New Roman",Georgia,serif;color:#111827;background:#f3f4f6;font-size:11.5pt;line-height:1.5}
  .hoja{width:210mm;margin:0 auto 14px;background:#fff;padding:18mm 20mm}
  .pagare{position:relative;border:2px solid #111827;border-radius:6px;padding:16px 18px;margin-bottom:16px}
  /* Sello de goma: doble borde, girado, que se lee aunque se fotocopie. */
  .sello{position:absolute;top:38%;left:50%;transform:translate(-50%,-50%) rotate(-16deg);
    border:5px double #b91c1c;color:#b91c1c;font-family:Arial,Helvetica,sans-serif;font-weight:800;
    font-size:38pt;letter-spacing:.14em;padding:4px 22px;opacity:.82;pointer-events:none;white-space:nowrap}
  .sello.anulado{border-color:#6b7280;color:#6b7280}
  .nota-cancelado{font-family:Arial,Helvetica,sans-serif;font-size:9.5pt;font-weight:700;color:#b91c1c;
    border:1px solid #fca5a5;background:#fef2f2;padding:6px 10px;border-radius:4px;margin-bottom:12px}
  .pagare-anulado .nota-cancelado{color:#4b5563;border-color:#d1d5db;background:#f9fafb}
  .avance{font-family:system-ui,sans-serif;font-size:9.5pt;color:#92400e;background:#fffbeb;
    border:1px solid #fde68a;padding:6px 10px;border-radius:4px;margin-bottom:12px}
  .resumen{max-width:210mm;margin:0 auto 12px;font-family:system-ui,sans-serif;font-size:13px;color:#374151;
    display:flex;flex-wrap:wrap;gap:8px 18px;align-items:baseline}
  .resumen h1{font-size:17px;margin:0;color:#111827}
  .resumen .chip{font-weight:600}
  .resumen .chip.cancelado{color:#b91c1c}
  .resumen .chip.parcial{color:#92400e}
  .cab{display:flex;justify-content:space-between;align-items:flex-start;border-bottom:1px solid #9ca3af;padding-bottom:10px;margin-bottom:12px}
  .tipo{font-size:14pt;font-weight:700;text-transform:uppercase;letter-spacing:.06em}
  .num{font-size:10pt;color:#4b5563;margin-top:2px}
  .importe{text-align:right}
  .importe .lbl{font-size:9pt;text-transform:uppercase;color:#6b7280;letter-spacing:.05em}
  .importe .val{font-size:17pt;font-weight:700}
  p{margin:0 0 9px;text-align:justify}
  p.aval,p.mora{font-size:10pt}
  p.mora{color:#374151;margin-top:10px}
  table.ref{width:100%;border-collapse:collapse;font-size:10pt;margin:10px 0}
  table.ref th,table.ref td{border:1px solid #9ca3af;padding:4px 7px;text-align:left;vertical-align:top}
  table.ref th{background:#f3f4f6;font-weight:700;white-space:nowrap;width:14%}
  .firmas{display:flex;flex-wrap:wrap;gap:24px;margin-top:34px}
  .firma{flex:1 1 40%;min-width:180px;text-align:center}
  .firma .linea{border-top:1px solid #111827;margin-bottom:5px}
  .firma .rol{font-size:9pt;font-weight:700}
  .firma .pie{font-size:9pt;color:#4b5563}
  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-family:system-ui,sans-serif;font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer}
  .vacio{max-width:210mm;margin:24px auto;padding:20px;background:#fff;text-align:center;color:#6b7280;font-family:system-ui,sans-serif}
  @media print{
    body{background:#fff} .toolbar,.resumen,.avance{display:none} .hoja{width:auto;padding:0;margin:0}
    /* Un pagaré por hoja: se firman y se archivan sueltos. */
    .pagare{break-after:page;break-inside:avoid;margin-bottom:0}
    .pagare:last-child{break-after:auto}
    @page{size:A4;margin:16mm}
  }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
${pagares.length === 0 ? "" : resumenHtml}
${
  pagares.length === 0
    ? `<div class="vacio">Este contrato no tiene cuotas, así que no genera pagarés.</div>`
    : `<div class="hoja">${hojas}</div>`
}
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
