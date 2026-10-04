import { NextRequest, NextResponse } from "next/server";
import { authorizedFetch, sameOrigin } from "@/lib/server";

export const maxDuration = 120;
export async function GET(request: NextRequest, context: { params: Promise<{ path: string[] }> }) {
  const { path } = await context.params;
  // Authentication tokens never pass through this browser-facing proxy.
  const allowed = ["tasks", "habits", "calendar", "focus", "chat", "preferences", "notifications", "recommendations", "schedule"];
  if (!allowed.includes(path[0]) || path.some(part => !/^[a-zA-Z0-9_-]+$/.test(part))) {
    return NextResponse.json({ detail: "Not found" }, { status: 404 });
  }
  if (request.method !== "GET" && !sameOrigin(request)) {
    return NextResponse.json({ detail: "Invalid request origin" }, { status: 403 });
  }
  try {
    const response = await authorizedFetch("/" + path.join("/") + request.nextUrl.search, {
      method: request.method,
      headers: { "Content-Type": "application/json" },
      ...(request.method !== "GET" ? { body: await request.text() } : {}),
    });
    return new Response(await response.text(), {
      status: response.status,
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    });
  } catch {
    return NextResponse.json({ detail: "The service is unavailable. Please try again shortly." }, { status: 502 });
  }
}
export const POST = GET;
export const PATCH = GET;
export const PUT = GET;
export const DELETE = GET;
