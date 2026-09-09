import { fechaEnLetras, guaraniesEnLetras } from "./numero-a-letras";
import type { DatosContrato, PersonaContrato } from "./types";

/**
 * Plantilla del CONTRATO DE COMPRAVENTA DE INMUEBLE A PLAZOS.
 *
 * El texto de las cláusulas es el que aprobó el cliente, transcripto tal cual.
 * Lo único adaptado es la Cláusula Tercera, que ahora contempla la entrega
 * inicial (el modelo en papel no la preveía), y la incorporación del cónyuge y
 * de los codeudores cuando el tipo de contrato los exige.
 *
 * Los datos que faltan NO se inventan: salen como una línea de puntos, igual
 * que en el formulario en papel, para completarse a mano antes de firmar.
 *
 * Función pura: recibe datos y devuelve HTML. Se prueba sin base ni red.
 */

function esc(v: unknown): string {
  return String(v ?? "")
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Dato faltante: raya para completar a mano, nunca un valor inventado. */
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

/** "el señor o señora NOMBRE, de nacionalidad X, con C.I. N° Y, estado civil Z, domicilio W". */
function fraseParte(p: PersonaContrato): string {
  return [
    `<strong>${d(p.nombre, 40)}</strong>`,
    `de nacionalidad ${d(p.nacionalidad || "paraguaya", 14)}`,
    `con Cédula de Identidad N°/RUC N° ${d(p.documento, 16)}`,
    `estado civil ${d(p.estado_civil, 14)}`,
    `con domicilio real en ${d(p.domicilio, 34)}`,
  ].join(", ");
}

function filaDato(label: string, valor: unknown): string {
  return `<tr><th>${esc(label)}</th><td>${d(valor, 18)}</td></tr>`;
}

export function plantillaCompraventaPlazos(datos: DatosContrato, opciones?: { autoImprimir?: boolean }): string {
  const { config, comprador, conyuge, codeudores, inmueble, operacion, cuotas } = datos;

  const compradores = [comprador, ...(conyuge ? [conyuge] : [])];
  const plural = compradores.length > 1;
  const COMPRADOR = plural ? "LOS/LAS COMPRADORES/AS" : "EL/LA COMPRADOR/A";

  const encabezadoPartes = compradores
    .map((p, i) => `${i === 0 ? "el señor o señora " : "y el señor o señora "}${fraseParte(p)}`)
    .join(" ");

  const codeudoresHtml =
    codeudores.length > 0
      ? codeudores
          .map(
            (p) =>
              `<p>Interviene además, en calidad de <strong>CODEUDOR/A SOLIDARIO/A</strong>, ${fraseParte(p)}.</p>`
          )
          .join("")
      : "";

  const clausulaCodeudor =
    codeudores.length > 0
      ? `<h3>CLÁUSULA ADICIONAL — CODEUDOR SOLIDARIO</h3>
         <p>${codeudores.length === 1 ? "El/La CODEUDOR/A" : "Los/Las CODEUDORES/AS"} que suscribe${
           codeudores.length === 1 ? "" : "n"
         } el presente contrato se constituye${
           codeudores.length === 1 ? "" : "n"
         } en deudor solidario, liso, llano y principal pagador de todas las obligaciones asumidas por ${COMPRADOR},
         con renuncia expresa a los beneficios de excusión y división, y responde${
           codeudores.length === 1 ? "" : "n"
         } por el saldo de precio, sus intereses moratorios y punitorios, y los gastos y costas que la gestión de cobro
         irrogare, hasta la total cancelación del precio. Esta obligación subsiste aun en caso de prórroga, refinanciación
         o cesión consentida por LA VENDEDORA.</p>`
      : "";

  const entregaHtml =
    operacion.entrega_inicial > 0
      ? `De dicho precio, ${COMPRADOR} abona en este acto la suma de <strong>${gs(
          operacion.entrega_inicial
        )}</strong> (Guaraníes ${esc(
          guaraniesEnLetras(operacion.entrega_inicial)
        )}) en concepto de entrega inicial, sirviendo el presente de suficiente recibo, y el saldo de
        <strong>${gs(operacion.monto_financiado)}</strong> (Guaraníes ${esc(
          guaraniesEnLetras(operacion.monto_financiado)
        )}) será abonado`
      : `Dicho precio será abonado`;

  const firmas = [
    { titulo: `LA VENDEDORA — ${config.razon_social}`, pie: config.representante_nombre ?? "" },
    { titulo: plural ? "EL/LA COMPRADOR/A TITULAR" : "EL/LA COMPRADOR/A", pie: comprador.nombre },
    ...(conyuge ? [{ titulo: "CÓNYUGE", pie: conyuge.nombre }] : []),
    ...codeudores.map((c) => ({ titulo: "CODEUDOR/A SOLIDARIO/A", pie: c.nombre })),
  ];

  const firmasHtml = firmas
    .map(
      (f) => `<div class="firma">
        <div class="linea"></div>
        <div class="rol">${esc(f.titulo)}</div>
        <div class="pie">${esc(f.pie)}</div>
      </div>`
    )
    .join("");

  /**
   * Anexo con el plan de pago. Va como parte del contrato, con su propia firma:
   * es el detalle de lo que la Cláusula Tercera enuncia en una sola línea, y el
   * comprador se lleva el cuadro de vencimientos que firmó.
   */
  const anexoCuotas =
    cuotas.length === 0
      ? ""
      : `<div class="anexo">
  <h3>Anexo — Plan de pago</h3>
  <p>Detalle de las ${cuotas.length} cuotas pactadas en la Cláusula Tercera. Forma parte del presente contrato.</p>
  <table class="cuotas">
    <thead>
      <tr>
        <th>Cuota</th><th>Vencimiento</th><th>Capital</th><th>Recargo</th><th>Importe</th>
      </tr>
    </thead>
    <tbody>
      ${cuotas
        .map(
          (c) => `<tr>
        <td class="c">${c.numero}</td>
        <td class="c">${fmtFecha(c.vencimiento)}</td>
        <td>${gs(c.capital)}</td>
        <td>${gs(c.interes)}</td>
        <td>${gs(c.total)}</td>
      </tr>`
        )
        .join("")}
    </tbody>
    <tfoot>
      <tr>
        <td class="c" colspan="2">Total</td>
        <td>${gs(cuotas.reduce((a, c) => a + c.capital, 0))}</td>
        <td>${gs(cuotas.reduce((a, c) => a + c.interes, 0))}</td>
        <td>${gs(cuotas.reduce((a, c) => a + c.total, 0))}</td>
      </tr>
    </tfoot>
  </table>
  <div class="firmas">${firmasHtml}</div>
</div>`;


  return `<!doctype html>
<html lang="es"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(operacion.numero_contrato)} — Contrato de compraventa</title>
<style>
  *{box-sizing:border-box} html,body{margin:0;padding:0}
  body{font-family:"Times New Roman",Georgia,serif;color:#111827;background:#f3f4f6;font-size:12pt;line-height:1.5}
  .page{width:210mm;margin:0 auto;background:#fff;padding:20mm 22mm}
  h1{font-size:15pt;text-align:center;letter-spacing:.02em;margin:0 0 4px}
  .contrato-num{text-align:center;font-size:10pt;color:#6b7280;margin-bottom:18px}
  h3{font-size:12pt;margin:18px 0 6px;text-transform:uppercase;letter-spacing:.01em}
  p{margin:0 0 10px;text-align:justify}
  table.datos{width:100%;border-collapse:collapse;margin:12px 0 6px;font-size:10pt}
  table.datos th,table.datos td{border:1px solid #9ca3af;padding:5px 7px;text-align:left;vertical-align:top}
  table.datos th{background:#f3f4f6;font-weight:700;width:26%;white-space:nowrap}
  .firmas{display:flex;flex-wrap:wrap;gap:28px;margin-top:44px}
  .firma{flex:1 1 40%;min-width:200px;text-align:center}
  .firma .linea{border-top:1px solid #111827;margin-bottom:6px}
  .firma .rol{font-size:9.5pt;font-weight:700}
  .firma .pie{font-size:9.5pt;color:#4b5563}
  .membrete{display:flex;justify-content:space-between;align-items:flex-start;gap:18px;border-bottom:2px solid #111827;padding-bottom:10px;margin-bottom:16px}
  .membrete .logo{max-width:200px;max-height:80px;width:auto;height:auto;object-fit:contain;display:block}
  .membrete .logo-txt{font-size:16pt;font-weight:700;letter-spacing:.02em}
  .membrete-datos{text-align:right;font-size:9.5pt;line-height:1.45;color:#374151}
  .membrete-datos .razon{font-weight:700;color:#111827}
  .anexo{margin-top:34px}
  .anexo h3{margin-top:0}
  table.cuotas{width:100%;border-collapse:collapse;font-size:9.5pt}
  table.cuotas th,table.cuotas td{border:1px solid #9ca3af;padding:4px 6px}
  table.cuotas th{background:#f3f4f6;font-weight:700;text-align:center}
  table.cuotas td{text-align:right}
  table.cuotas td.c{text-align:center}
  table.cuotas tfoot td{background:#f9fafb;font-weight:700}
  table.cuotas tr{break-inside:avoid}
  .toolbar{max-width:210mm;margin:12px auto;text-align:right}
  .toolbar button{font-family:system-ui,sans-serif;font-size:13px;padding:8px 16px;border-radius:8px;border:1px solid #0EA5E9;background:#0EA5E9;color:#fff;cursor:pointer}
  @media print{
    body{background:#fff} .toolbar{display:none} .page{width:auto;padding:0;margin:0}
    .anexo{break-before:page}
    thead{display:table-header-group}
    @page{size:A4;margin:18mm}
  }
</style></head><body>
<div class="toolbar"><button onclick="window.print()">Imprimir / Guardar PDF</button></div>
<div class="page">

<div class="membrete">
  ${datos.logoUrl ? `<img class="logo" src="${esc(datos.logoUrl)}" alt="${esc(config.razon_social)}" />` : `<div class="logo-txt">${esc(config.razon_social)}</div>`}
  <div class="membrete-datos">
    <div class="razon">${esc(config.razon_social)}</div>
    ${config.ruc ? `<div>RUC ${esc(config.ruc)}</div>` : ""}
    ${config.domicilio ? `<div>${esc(config.domicilio)}</div>` : ""}
    ${config.ciudad_firma ? `<div>${esc(config.ciudad_firma)}${config.departamento ? `, ${esc(config.departamento)}` : ""}</div>` : ""}
  </div>
</div>

<h1>Contrato de Compraventa de Inmueble a Plazos</h1>
<div class="contrato-num">${esc(operacion.numero_contrato)}${
    datos.tipo ? ` · ${esc(datos.tipo.nombre)}` : ""
  }</div>

<p>En la ciudad de ${d(config.ciudad_firma, 20)}, Departamento de ${d(
    config.departamento,
    16
  )}, República del Paraguay, el día ${esc(
    fechaEnLetras(operacion.fecha_venta) || "____ de ____________ de ____"
  )}, se reúnen la empresa <strong>${esc(config.razon_social)}</strong>, con RUC N° ${d(
    config.ruc,
    14
  )}, representada por ${d(config.representante_nombre, 26)}, con domicilio en ${d(
    config.domicilio,
    30
  )}, quien actúa en nombre de "<strong>LA VENDEDORA</strong>", y ${encabezadoPartes}, quien${
    plural ? "es actúan" : " actúa"
  } en nombre de "<strong>${COMPRADOR}</strong>". Ambas partes tienen capacidad legal suficiente para firmar este contrato y obligarse.</p>

${codeudoresHtml}

<p>Acuerdan celebrar el presente <strong>CONTRATO DE COMPRAVENTA A PLAZOS</strong>, con las siguientes cláusulas:</p>

<h3>Datos del Loteamiento</h3>
<table class="datos">
  ${filaDato("Loteamiento", inmueble.loteamiento)}
  ${filaDato("Fracción", inmueble.fraccion)}
  ${filaDato("Manzana", inmueble.manzana)}
  ${filaDato("Lote", inmueble.lote)}
  ${filaDato("Superficie (m²)", inmueble.superficie_m2 ? `${inmueble.superficie_m2}` : "")}
  ${filaDato("Frente (m)", inmueble.frente_m ? `${inmueble.frente_m}` : "")}
  ${filaDato("Fondo (m)", inmueble.fondo_m ? `${inmueble.fondo_m}` : "")}
  ${filaDato("Finca Matriz", inmueble.finca_matriz)}
  ${filaDato("N°/Finca/Matrícula/CUICR", inmueble.matricula)}
  ${filaDato("Cta. Cte. Catastral / Padrón", [inmueble.cuenta_corriente_catastral, inmueble.padron].filter(Boolean).join(" / "))}
  ${filaDato("Departamento", inmueble.departamento)}
  ${filaDato("Distrito", inmueble.distrito)}
  ${filaDato("Resolución Municipal de aprobación N°", inmueble.resolucion_municipal)}
  ${filaDato("Aprobado RUN N° Exp.", inmueble.run_expediente)}
  ${filaDato("Linda al Norte", inmueble.linda_norte)}
  ${filaDato("Linda al Sur", inmueble.linda_sur)}
  ${filaDato("Linda al Este", inmueble.linda_este)}
  ${filaDato("Linda al Oeste", inmueble.linda_oeste)}
</table>

<h3>Cláusula Primera — Objeto</h3>
<p>LA VENDEDORA vende, y ${COMPRADOR} compra, el lote de terreno identificado en el apartado "Datos del Loteamiento"
que antecede (en adelante, "el Lote"), conforme a la superficie, medidas y linderos allí consignados y al plano de
fraccionamiento aprobado por la Municipalidad, libre de gravámenes y ocupantes, salvo la reserva de dominio pactada
en la Cláusula Séptima. El precio se pacta por el Lote como cuerpo cierto, sin derecho a reclamo por diferencias de
superficie.</p>

<h3>Cláusula Segunda — Conformidad del comprador</h3>
<p>${COMPRADOR} declara que, con anterioridad a la firma del presente instrumento, verificó personalmente en el lugar
del loteamiento la ubicación, dimensiones y linderos del Lote, conforme al plano de fraccionamiento aprobado por la
Municipalidad, manifestando su plena conformidad con el mismo.</p>

<h3>Cláusula Tercera — Precio y forma de pago</h3>
<p>El precio total de venta del Lote es de <strong>${gs(operacion.precio_total)}</strong> (Guaraníes ${esc(
    guaraniesEnLetras(operacion.precio_total)
  )}), IVA incluido. ${entregaHtml} en <strong>${operacion.cantidad_cuotas}</strong>
(${esc(guaraniesEnLetras(operacion.cantidad_cuotas).toLowerCase())}) cuotas mensuales, iguales y consecutivas, de
<strong>${gs(operacion.cuota)}</strong> (Guaraníes ${esc(
    guaraniesEnLetras(operacion.cuota)
  )}) cada una, con vencimiento de la primera el día ${esc(
    fmtFecha(operacion.primer_vencimiento)
  )}, y las siguientes en igual fecha de cada mes subsiguiente, hasta la total cancelación del precio.</p>

<p>Los pagos deberán ser realizados por mensualidades adelantadas, del día ${config.dia_pago_desde} al
${config.dia_pago_hasta} de cada mes, en las oficinas de LA VENDEDORA, sitas en ${d(
    config.lugar_pago || config.domicilio,
    30
  )}, o en el lugar que ésta indique por escrito. LA VENDEDORA emitirá factura legal por cada pago recibido.</p>

<p>La falta de pago de cualquiera de las cuotas adeudadas habilita a LA VENDEDORA a exigir su cobro por la vía
ejecutiva, sirviendo el presente contrato y los comprobantes de pago de suficiente título ejecutivo, todo ello sin
perjuicio de lo establecido en la Cláusula Octava.</p>

<h3>Cláusula Cuarta — Actualización del saldo</h3>
<p>El precio del Lote y el importe de las cuotas permanecerán fijos e inalterables mientras la variación del Índice de
Precios al Consumidor (IPC) publicado por el Banco Central del Paraguay no supere el veinte por ciento (20%) en los
doce (12) meses inmediatamente anteriores a cada vencimiento. De superarse dicho porcentaje, el saldo impago del
precio y las cuotas se corregirán únicamente en la proporción que exceda el veinte por ciento (20%), aplicándose igual
criterio en forma proporcional cuando la variación se produjera en un lapso inferior a doce (12) meses. Esta cláusula
no afecta las cuotas ya abonadas.</p>

<h3>Cláusula Quinta — Mora e intereses</h3>
<p>El mero vencimiento de los plazos fijados para el pago de las cuotas constituirá en mora automática a ${COMPRADOR},
sin necesidad de interpelación judicial ni extrajudicial de ninguna especie. Las cuotas atrasadas devengarán, desde la
fecha de su vencimiento: (a) un interés moratorio mensual equivalente a la tasa máxima vigente fijada periódicamente
por el Banco Central del Paraguay para operaciones de esta naturaleza; y (b) un interés punitorio adicional, que en
ningún caso podrá exceder el treinta por ciento (30%) de la tasa moratoria antes indicada, calculado exclusivamente
sobre el saldo de la cuota en mora — todo ello en un todo de acuerdo con el artículo 475 del Código Civil y la
normativa vigente del Banco Central del Paraguay sobre límites a las tasas usurarias. En caso de que el cobro de las
cuotas atrasadas deba tramitarse por vía prejudicial y/o judicial, los gastos y costas razonables de dicha gestión
serán a cargo de ${COMPRADOR}.</p>

<h3>Cláusula Sexta — Posesión</h3>
<p>En este mismo acto, LA VENDEDORA hace entrega a ${COMPRADOR} de la posesión del Lote, a título precario y en nombre
de LA VENDEDORA, conforme al artículo 780 del Código Civil, hasta tanto se cancele la totalidad del precio pactado.
Desde la toma de posesión, ${COMPRADOR} asume la responsabilidad por la limpieza, conservación y mantenimiento del
Lote, así como por los hechos que en él ocurrieran. Cualquier obra o mejora que ${COMPRADOR} decida realizar deberá
mantenerse dentro de los límites del Lote. Si ${COMPRADOR} no mantuviera limpio el terreno, LA VENDEDORA podrá
realizar la limpieza y trasladarle el costo correspondiente.</p>

<h3>Cláusula Séptima — Reserva de dominio y escrituración</h3>
<p>La venta se realiza con reserva de dominio a favor de LA VENDEDORA (art. 780, Código Civil) hasta la cancelación
total del precio. Abonado al menos el 25% del precio, ${COMPRADOR} podrá exigir la Escritura Pública de Transferencia,
quedando el Lote gravado con hipoteca en primer grado por el saldo pendiente (art. 255 inc. b, Ley N° 3.966/2010,
modif. Ley N° 5.346/2014).</p>
<p>Cancelado el precio en su totalidad, LA VENDEDORA otorgará la Escritura Pública dentro de los noventa (90) días
siguientes, ante el Escribano que designe, siendo los gastos e impuestos de la escritura por cuenta de ${COMPRADOR}.</p>
<p>LA VENDEDORA inscribirá el presente contrato y el proyecto de loteamiento ante el Registro Unificado Nacional (RUN),
conforme al art. 250 de la Ley N° 3.966/2010.</p>

<h3>Cláusula Octava — Incumplimiento y resolución</h3>
<p>Conforme al art. 255 inc. c) de la Ley N° 3.966/2010 (modif. Ley N° 5.346/2014) y al art. 782 del Código Civil:</p>
<p>a) <strong>Hasta el 25% abonado:</strong> LA VENDEDORA podrá resolver el contrato con seis (6) o más cuotas
consecutivas impagas, previa comunicación fehaciente, sin requerimiento judicial. Resuelto el contrato, ${COMPRADOR}
deberá desocupar el Lote en diez (10) días. Las sumas abonadas se imputarán a indemnización por uso y gastos
administrativos, sin perjuicio del derecho a retirar mejoras, salvo imposibilidad material sin desmedro apreciable.</p>
<p>b) <strong>Más del 25% abonado:</strong> no procede la resolución (art. 782, Código Civil). LA VENDEDORA solo podrá
exigir el cobro ejecutivo del saldo —con todas las cuotas vencidas y exigibles— ante diez (10) o más cuotas
consecutivas impagas, con los intereses de la Cláusula Quinta.</p>
<p>Toda estipulación incompatible con esta cláusula se tendrá por no escrita.</p>

<h3>Cláusula Novena — Servicios y obras</h3>
<p>El precio pactado corresponde al Lote en su estado actual, sin empedrado, vereda ni muralla. La conexión de los
servicios de energía eléctrica, agua corriente, alcantarillado, desagüe pluvial y telefonía, así como cualquier obra que
la Municipalidad exigiera ejecutar a LA VENDEDORA por no mediar aún escritura de transferencia, serán por cuenta
exclusiva de ${COMPRADOR}; de ser afrontados por LA VENDEDORA, su importe, con más los intereses correspondientes, se
adicionará al saldo de precio.</p>

<h3>Cláusula Décima — Impuestos y tasas</h3>
<p>A partir de la fecha del presente contrato, todos los impuestos, tasas y contribuciones, existentes o a crearse, que
graven al Lote, correrán por cuenta exclusiva de ${COMPRADOR}, conforme a los artículos 1.808 y 1.812 del Código Civil.
LA VENDEDORA podrá, sin obligación de hacerlo, abonar dichos tributos por cuenta de ${COMPRADOR}, quien deberá
reembolsarle su importe con más los recargos financieros que correspondan.</p>

<h3>Cláusula Undécima — Cesión</h3>
<p>${COMPRADOR} no podrá ceder ni transferir los derechos emergentes del presente contrato sin el consentimiento previo
y por escrito de LA VENDEDORA, ni sin el previo pago de los gastos administrativos que la cesión genere. Asimismo,
deberá acreditar estar al día con el pago del impuesto inmobiliario para cualquier gestión ante LA VENDEDORA.</p>

<h3>Cláusula Duodécima — Normativa ambiental y de uso</h3>
<p>${COMPRADOR} se obliga a observar la Ley N° 294/1993 "De Evaluación de Impacto Ambiental" y la Ley N° 716/1996 "Que
sanciona los delitos contra el medio ambiente", quedando prohibida la poda, tala o quema de árboles ubicados en el
perímetro del Lote, salvo que resulte indispensable para una construcción autorizada y siempre que ${COMPRADOR} cuente
con el plano de obra aprobado y el permiso correspondiente del organismo municipal de medio ambiente, y haya abonado
como mínimo el 25% del precio del Lote. El loteamiento tiene destino habitacional (residencial); queda prohibida la
instalación de talleres, lavaderos, depósitos de reciclaje o construcciones precarias. El incumplimiento de esta
cláusula facultará a LA VENDEDORA a resolver el contrato conforme a la Cláusula Octava, debiendo ${COMPRADOR} retirar
sus mejoras.</p>

<h3>Cláusula Décimo Tercera — Protección de datos personales crediticios</h3>
<p>${COMPRADOR} autoriza expresamente a LA VENDEDORA a obtener, verificar y utilizar sus datos personales y crediticios
derivados de la presente relación comercial, en un todo de acuerdo con la Ley N° 6.534/2020 "De Protección de Datos
Personales Crediticios". Dicha autorización comprende: a) los datos de identificación personal (nombre, cédula de
identidad, RUC, fecha de nacimiento, domicilio, teléfono, correo electrónico); y b) los datos relativos al cumplimiento
del presente contrato (monto, cuotas, saldo, vencimientos, mora), pudiendo LA VENDEDORA remitir esta información a
Sociedades de Información Crediticia y consultarla ante éstas, con las medidas de seguridad y confidencialidad exigidas
por la Ley. Esta autorización no habilita el uso de los datos para fines distintos de los previstos en la citada norma,
ni para prospección comercial o de marketing, salvo consentimiento adicional y específico de ${COMPRADOR}.</p>

<h3>Cláusula Décimo Cuarta — Protección al consumidor</h3>
<p>El presente contrato se sujeta, en cuanto corresponda, a la Ley N° 1.334/1998 "De Defensa del Consumidor y del
Usuario" y sus modificaciones. Ninguna cláusula de este instrumento podrá interpretarse en sentido que prive a
${COMPRADOR} de los derechos irrenunciables que dicha ley y las demás normas de orden público citadas en este contrato
le reconocen; en caso de duda o de conflicto entre cláusulas, prevalecerá la interpretación más favorable a
${COMPRADOR}.</p>

<h3>Cláusula Décimo Quinta — Domicilios y notificaciones</h3>
<p>Las partes constituyen domicilio especial, a los efectos del presente contrato, en los indicados en el
encabezamiento, donde se tendrán por válidas todas las notificaciones y comunicaciones, aun cuando no coincidan con el
domicilio real. Todo cambio de domicilio deberá comunicarse por escrito y de manera fehaciente a la otra parte.</p>

<h3>Cláusula Décimo Sexta — Solución de controversias</h3>
<p>Ante cualquier divergencia relativa a la interpretación o ejecución del presente contrato, las partes acuerdan
someterse, en primer término, a la conciliación amistosa y a la mediación del Centro de Mediación. De no alcanzarse un
acuerdo, las partes se someten a la competencia de los tribunales ordinarios con jurisdicción en el lugar de ubicación
del Lote, pudiéndose prorrogar según corresponda.</p>

${clausulaCodeudor}

<h3>Cláusula Final — Ejemplares</h3>
<p>En prueba de conformidad y aceptación, las partes firman el presente contrato en ${config.ejemplares}
(${esc(guaraniesEnLetras(config.ejemplares).toLowerCase())}) ejemplares de un mismo tenor y a un solo efecto, en el
lugar y fecha indicados en el encabezamiento, quedando un ejemplar en poder de cada parte.</p>

<div class="firmas">${firmasHtml}</div>

${anexoCuotas}

</div>
<script>try{ if (${opciones?.autoImprimir ? "true" : "false"}) window.print(); }catch(e){}</script>
</body></html>`;
}
