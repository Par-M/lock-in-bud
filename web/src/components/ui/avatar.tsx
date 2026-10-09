"use client";

import type { ComponentProps } from "react";
import * as AvatarPrimitive from "@radix-ui/react-avatar";

// Adapted from shadcn's avatar registry item; only fallback avatars are needed.
export function Avatar({ className = "", ...props }: ComponentProps<typeof AvatarPrimitive.Root>) {
  return <AvatarPrimitive.Root data-slot="avatar" className={`avatar ${className}`} {...props} />;
}

export function AvatarImage({ className = "", ...props }: ComponentProps<typeof AvatarPrimitive.Image>) {
  return <AvatarPrimitive.Image data-slot="avatar-image" className={`avatar-image ${className}`} {...props} />;
}

export function AvatarFallback({ className = "", ...props }: ComponentProps<typeof AvatarPrimitive.Fallback>) {
  return <AvatarPrimitive.Fallback data-slot="avatar-fallback" className={`avatar-fallback ${className}`} {...props} />;
}
