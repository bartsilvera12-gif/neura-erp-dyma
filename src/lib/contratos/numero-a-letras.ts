/**
 * Números a letras en castellano, para los importes escritos del contrato
 * ("Gs. 100.000.000 (Guaraníes cien millones)").
 *
 * Función pura y sin dependencias: la aritmética del dinero escrito se prueba
 * sola. Cubre hasta billones, que es de sobra para un precio en guaraníes.
 */

const UNIDADES = [
  "cero", "uno", "dos", "tres", "cuatro", "cinco", "seis", "siete", "ocho", "nueve",
  "diez", "once", "doce", "trece", "catorce", "quince", "dieciséis", "diecisiete",
  "dieciocho", "diecinueve", "veinte", "veintiuno", "veintidós", "veintitrés",
  "veinticuatro", "veinticinco", "veintiséis", "veintisiete", "veintiocho", "veintinueve",
];

const DECENAS = ["", "", "", "treinta", "cuarenta", "cincuenta", "sesenta", "setenta", "ochenta", "noventa"];

const CENTENAS = [
  "", "ciento", "doscientos", "trescientos", "cuatrocientos", "quinientos",
  "seiscientos", "setecientos", "ochocientos", "novecientos",
];

/** 0–999. `apocope` convierte "uno" en "un" (mil un, veintiún mil). */
function hasta999(n: number, apocope: boolean): string {
  if (n === 0) return "";
  if (n === 100) return "cien";

  const c = Math.floor(n / 100);
  const resto = n % 100;
  const partes: string[] = [];
  if (c > 0) partes.push(CENTENAS[c]!);

  if (resto > 0) {
    if (resto < 30) {
      let txt = UNIDADES[resto]!;
      // "veintiuno" pierde la o y gana tilde delante de sustantivo: veintiún mil.
      if (apocope && resto === 1) txt = "un";
      else if (apocope && resto === 21) txt = "veintiún";
      partes.push(txt);
    } else {
      const d = Math.floor(resto / 10);
      const u = resto % 10;
      if (u === 0) partes.push(DECENAS[d]!);
      else partes.push(`${DECENAS[d]} y ${apocope && u === 1 ? "un" : UNIDADES[u]}`);
    }
  }
  return partes.join(" ");
}

/**
 * Apócope delante de sustantivo: "veintiún mil", "treinta y un millones".
 * Se aplica sobre el texto ya formado porque el "uno" a corregir puede estar al
 * final de una frase larga ("ciento treinta y uno" → "ciento treinta y un mil").
 */
function apocopar(txt: string): string {
  return txt.replace(/\bveintiuno\b/g, "veintiún").replace(/\buno\b/g, "un");
}

/** Escalas largas del castellano: millón, billón. El millar no lleva plural propio. */
const ESCALAS: { valor: number; singular: string; plural: string }[] = [
  { valor: 1e12, singular: "billón", plural: "billones" },
  { valor: 1e6, singular: "millón", plural: "millones" },
  { valor: 1e3, singular: "mil", plural: "mil" },
];

/**
 * Entero a palabras. Devuelve minúsculas y sin la moneda: quien llama arma la
 * frase ("Guaraníes " + texto).
 */
export function numeroALetras(valor: number): string {
  const n = Math.trunc(Math.abs(Number(valor) || 0));
  if (n === 0) return "cero";
  if (n < 1000) return hasta999(n, false);

  const signo = Number(valor) < 0 ? "menos " : "";

  for (const esc of ESCALAS) {
    if (n < esc.valor) continue;
    const cuantos = Math.floor(n / esc.valor);
    const resto = n % esc.valor;

    let cabeza: string;
    if (esc.valor === 1e3) {
      // "mil", no "un mil"; pero sí "dos mil", "veintiún mil".
      cabeza = cuantos === 1 ? "mil" : `${apocopar(numeroALetras(cuantos))} mil`;
    } else {
      cabeza =
        cuantos === 1
          ? `un ${esc.singular}`
          : `${apocopar(numeroALetras(cuantos))} ${esc.plural}`;
    }

    return `${signo}${cabeza}${resto > 0 ? ` ${numeroALetras(resto)}` : ""}`.trim();
  }

  return `${signo}${hasta999(n, false)}`;
}

/** Importe en guaraníes escrito como lo pide el contrato. */
export function guaraniesEnLetras(valor: number): string {
  const txt = numeroALetras(valor);
  return txt.charAt(0).toUpperCase() + txt.slice(1);
}

const MESES = [
  "enero", "febrero", "marzo", "abril", "mayo", "junio",
  "julio", "agosto", "septiembre", "octubre", "noviembre", "diciembre",
];

/** "3 de septiembre de dos mil veintiséis", como se escribe en el encabezado. */
export function fechaEnLetras(ymd: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(ymd).slice(0, 10));
  if (!m) return "";
  const [, y, mes, d] = m;
  return `${Number(d)} de ${MESES[Number(mes) - 1]} de ${numeroALetras(Number(y))}`;
}
