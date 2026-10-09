"use client";

import type { ComponentProps } from "react";
import { MessageScroller as MessageScrollerPrimitive } from "@shadcn/react/message-scroller";

// Official shadcn scroller primitive with plain CSS instead of registry utilities.
export const MessageScrollerProvider = MessageScrollerPrimitive.Provider;

export function MessageScroller({ className = "", ...props }: ComponentProps<typeof MessageScrollerPrimitive.Root>) {
  return <MessageScrollerPrimitive.Root data-slot="message-scroller" className={`message-scroller ${className}`} {...props} />;
}

export function MessageScrollerViewport({ className = "", ...props }: ComponentProps<typeof MessageScrollerPrimitive.Viewport>) {
  return <MessageScrollerPrimitive.Viewport data-slot="message-scroller-viewport" className={`chat-history ${className}`} {...props} />;
}

export function MessageScrollerContent({ className = "", ...props }: ComponentProps<typeof MessageScrollerPrimitive.Content>) {
  return <MessageScrollerPrimitive.Content data-slot="message-scroller-content" className={`message-scroller-content ${className}`} {...props} />;
}

export function MessageScrollerItem(props: ComponentProps<typeof MessageScrollerPrimitive.Item>) {
  return <MessageScrollerPrimitive.Item data-slot="message-scroller-item" {...props} />;
}
