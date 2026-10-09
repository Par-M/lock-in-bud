"use client";
import { useEffect, useRef, type ReactNode } from "react";
import { X } from "lucide-react";
export function Sheet({ title, onClose, children, sidePanel = false }: { sidePanel?: boolean; title: string; onClose: () => void; children: ReactNode }) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = ref.current;
    const previous = document.activeElement as HTMLElement | null;
    const media = window.matchMedia("(min-width: 1100px)");
    const show = () => {
      dialog?.close();
      if (sidePanel && media.matches) { dialog?.show(); if (dialog) dialog.dataset.modal = "false"; }
      else { dialog?.showModal(); if (dialog) dialog.dataset.modal = "true"; }
    };
    show(); media.addEventListener("change", show);
    return () => { media.removeEventListener("change", show); dialog?.close(); previous?.focus(); };
  }, [sidePanel]);
  return (
    <dialog
      ref={ref}
      className={`sheet${sidePanel ? " assistant-panel" : ""}`}
      onKeyDown={event => { if (event.key === "Escape") { event.preventDefault(); onClose(); } }}
      aria-label={title}
      onCancel={(event) => {
        event.preventDefault();
        onClose();
      }}
      onClick={(event) => {
        if (event.target === event.currentTarget) {
          const box = event.currentTarget.getBoundingClientRect();
          if (event.clientX < box.left || event.clientX > box.right || event.clientY < box.top || event.clientY > box.bottom) onClose();
        }
      }}
    >
      <div className="sheet-heading">
        <h2>{title}</h2>
        <button type="button" className="icon-button" aria-label={`Close ${title}`} onClick={onClose}>
          <X />
        </button>
      </div>
      {children}
    </dialog>
  );
}

