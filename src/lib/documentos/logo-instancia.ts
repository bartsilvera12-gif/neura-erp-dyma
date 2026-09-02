import "server-only";
import fs from "fs";
import path from "path";

/**
 * Logo de la instancia para los documentos impresos (membrete, presupuestos, KuDE).
 *
 * Se aceptan varios nombres y formatos a propósito: el logo lo deja el cliente y
 * puede venir en PNG (con transparencia) o JPEG. El formato se detecta por los
 * bytes, no por la extensión, porque un PNG guardado como `.jpeg` haría fallar el
 * `embedJpg` de pdf-lib con un error que no dice nada útil.
 */
const CANDIDATOS = ["dyma-logo.png", "dyma-logo.jpeg", "dyma-logo.jpg"];

/** Firma PNG: los 8 primeros bytes son siempre 89 50 4E 47 0D 0A 1A 0A. */
function esPng(b: Uint8Array): boolean {
  return b.length > 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47;
}

/** Firma JPEG: empieza con FF D8 FF. */
function esJpg(b: Uint8Array): boolean {
  return b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;
}

export type LogoInstancia = { bytes: Uint8Array; tipo: "png" | "jpg"; archivo: string };

/** Bytes y formato real del logo, o `null` si todavía no se cargó ninguno. */
export function leerLogoInstancia(): LogoInstancia | null {
  for (const archivo of CANDIDATOS) {
    try {
      const p = path.join(process.cwd(), "public", "brand", archivo);
      if (!fs.existsSync(p)) continue;
      const bytes = new Uint8Array(fs.readFileSync(p));
      if (esPng(bytes)) return { bytes, tipo: "png", archivo };
      if (esJpg(bytes)) return { bytes, tipo: "jpg", archivo };
      // Existe pero no es una imagen que sepamos embeber: se ignora en vez de romper.
    } catch {
      /* probamos el siguiente candidato */
    }
  }
  return null;
}

/** Ruta pública del logo para usar en HTML (`<img src>`), o `null` si no hay. */
export function rutaPublicaLogoInstancia(): string | null {
  const logo = leerLogoInstancia();
  return logo ? `/brand/${logo.archivo}` : null;
}
