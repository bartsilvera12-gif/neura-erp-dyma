import { NextResponse } from "next/server";
import { leerLogoInstancia } from "@/lib/documentos/logo-instancia";

export const dynamic = "force-dynamic";

/**
 * GET /api/brand/logo — sirve el logo de la instancia, sea PNG o JPEG.
 *
 * El membrete lo consume desde un `<img>`, así que necesita una URL fija. Apuntar
 * a un nombre de archivo concreto obligaba a que la extensión coincidiera con lo
 * que el cliente hubiera guardado; acá el formato se resuelve en el servidor y la
 * URL no cambia nunca.
 *
 * Sin logo cargado devuelve 404 y el `<img>` simplemente no muestra nada.
 */
export async function GET() {
  const logo = leerLogoInstancia();
  if (!logo) {
    return new NextResponse(null, { status: 404 });
  }
  return new NextResponse(Buffer.from(logo.bytes), {
    headers: {
      "Content-Type": logo.tipo === "png" ? "image/png" : "image/jpeg",
      // El logo cambia solo cuando lo reemplazan a mano: se cachea corto para que
      // un cambio se vea sin tener que reiniciar nada.
      "Cache-Control": "public, max-age=300",
    },
  });
}
