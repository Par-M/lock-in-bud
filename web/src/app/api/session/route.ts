import { NextRequest, NextResponse } from "next/server";
import { cookies } from "next/headers";
import { authorizedFetch, backend, clearTokens, refreshCookie, sameOrigin, saveTokens } from "@/lib/server";

export async function GET() {
  try {
    const response = await authorizedFetch("/auth/me");
    return new Response(await response.text(), { status: response.status, headers: { "Content-Type": "application/json", "Cache-Control": "no-store" } });
  } catch {
    return NextResponse.json({ detail: "Unable to reach the service. Please retry." }, { status: 502 });
  }
}

export async function POST(request: NextRequest) {
  if (!sameOrigin(request)) return NextResponse.json({ detail: "Invalid request origin" }, { status: 403 });
  try {
    const { id_token } = await request.json();
    if (typeof id_token !== "string" || id_token.length > 16_384) return NextResponse.json({ detail: "Invalid credential" }, { status: 400 });
    const response = await fetch(backend + "/auth/google", {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ id_token }), cache: "no-store", signal: AbortSignal.timeout(20_000),
    });
    if (!response.ok) {
      if (response.status >= 500) {
        return NextResponse.json({ detail: "The app's backend is unavailable. Sign-in cannot finish until the service is restored." }, { status: 502 });
      }
      if (response.status === 401) {
        return NextResponse.json({ detail: "The server could not verify your Google sign-in. Try again; if it continues, check that the website's OAuth client ID is accepted by the backend." }, { status: 401 });
      }
      return NextResponse.json({ detail: "Sign-in could not finish. Please try again." }, { status: response.status });
    }
    const tokens = await response.json();
    await saveTokens(tokens);
    return NextResponse.json(tokens.user);
  } catch {
    return NextResponse.json({ detail: "Unable to sign in. Please retry." }, { status: 502 });
  }
}

export async function DELETE(request: NextRequest) {
  if (!sameOrigin(request)) return NextResponse.json({ detail: "Invalid request origin" }, { status: 403 });
  try {
    // Refresh before capturing the token to revoke, not during the logout POST.
    const session = await authorizedFetch("/auth/me");
    if (session.status === 401) {
      await clearTokens();
      return NextResponse.json({ message: "Signed out" });
    }
    if (!session.ok) return NextResponse.json({ detail: "Unable to sign out. Please retry." }, { status: 502 });
    const token = (await cookies()).get(refreshCookie)?.value;
    const response = await authorizedFetch("/auth/logout", {
      method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ refresh_token: token }),
    });
    if (!response.ok && response.status !== 401) return NextResponse.json({ detail: "Unable to sign out. Please retry." }, { status: 502 });
    await clearTokens();
    return NextResponse.json({ message: "Signed out" });
  } catch {
    return NextResponse.json({ detail: "Unable to sign out. Please retry." }, { status: 502 });
  }
}
