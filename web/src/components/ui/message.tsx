import type { ComponentProps } from "react";

// Adapted from shadcn's message registry item for the planner's plain CSS.
export function Message({ align = "start", className = "", ...props }: ComponentProps<"div"> & { align?: "start" | "end" }) {
  return <div data-slot="message" data-align={align} className={`message ${className}`} {...props} />;
}

export function MessageAvatar({ className = "", ...props }: ComponentProps<"div">) {
  return <div data-slot="message-avatar" className={`message-avatar ${className}`} {...props} />;
}

export function MessageContent({ className = "", ...props }: ComponentProps<"div">) {
  return <div data-slot="message-content" className={`message-content ${className}`} {...props} />;
}
