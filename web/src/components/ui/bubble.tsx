import type { ComponentProps } from "react";

// Adapted from shadcn's bubble registry item with the existing planner colors.
export function Bubble({ className = "", ...props }: ComponentProps<"div">) {
  return <div data-slot="bubble" className={`bubble ${className}`} {...props} />;
}

export function BubbleContent({ className = "", ...props }: ComponentProps<"div">) {
  return <div data-slot="bubble-content" className={`bubble-content ${className}`} {...props} />;
}
