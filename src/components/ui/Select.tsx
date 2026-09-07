"use client";

import { ChevronDown } from "lucide-react";

/**
 * Select con el mismo lenguaje visual que el resto de los campos.
 *
 * Es un `<select>` nativo a propósito: en el celular abre la rueda del sistema,
 * se navega con teclado y no hay lista flotante que quede tapada dentro de un
 * modal. Lo único que se reemplaza es la flecha del navegador, que cambia de
 * forma en cada sistema y se veía fuera de lugar.
 */
export default function Select({
  className = "",
  children,
  ...rest
}: React.SelectHTMLAttributes<HTMLSelectElement>) {
  return (
    <div className="relative">
      <select
        {...rest}
        className={`w-full appearance-none rounded-xl border border-slate-200 bg-white py-2.5 pl-3.5 pr-10 text-sm text-slate-800 shadow-sm outline-none transition-colors hover:border-slate-300 focus:border-[#0EA5E9] focus:ring-2 focus:ring-[#0EA5E9]/25 disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-slate-400 ${className}`}
      >
        {children}
      </select>
      <ChevronDown
        className={`pointer-events-none absolute right-3 top-1/2 h-4 w-4 -translate-y-1/2 ${
          rest.disabled ? "text-slate-300" : "text-slate-400"
        }`}
        aria-hidden
      />
    </div>
  );
}
