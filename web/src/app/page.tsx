"use client";

import { useEffect, useState } from "react";
import Script from "next/script";
import Planner from "@/components/planner";

type User = { name: string | null; email: string | null };
declare global {
  interface Window {
    google?: { accounts: { id: {
      initialize: (options: { client_id: string; callback: (response: { credential: string }) => void }) => void;
      renderButton: (element: HTMLElement, options: { theme: string; size: string; width: number }) => void;
      disableAutoSelect: () => void;
    } } };
  }
}

export default function Home() {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [googleReady, setGoogleReady] = useState(false);
  const clientId = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID;

  async function loadSession() {
    setLoading(true); setError("");
    try {
      const response = await fetch("/api/session", { cache: "no-store" });
      if (response.ok) setUser(await response.json());
      else if (response.status !== 401) throw new Error("Unable to reach the service. Please retry.");
    } catch (e) { setError((e as Error).message); }
    finally { setLoading(false); }
  }
  useEffect(() => { void loadSession();
    if ("serviceWorker" in navigator && process.env.NODE_ENV === "production") {
      navigator.serviceWorker.register("/sw.js").catch(() => {});
    }
  }, []);

  useEffect(() => {
    const element = document.getElementById("google-sign-in");
    if (!googleReady || loading || user || !clientId || !element || !window.google) return;
    window.google.accounts.id.initialize({ client_id: clientId, callback: async ({ credential }) => {
      setError(""); setLoading(true);
      try {
        const response = await fetch("/api/session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id_token: credential }) });
        const data = await response.json();
        if (!response.ok) throw new Error(data.detail || "Unable to sign in.");
        setUser(data);
      } catch (e) { setError((e as Error).message); }
      finally { setLoading(false); }
    } });
    window.google.accounts.id.renderButton(element, { theme: "outline", size: "large", width: 280 });
  }, [googleReady, loading, user, clientId]);

  if (user) return <Planner user={user} onLogout={async () => {
    const response = await fetch("/api/session", { method: "DELETE" });
    if (!response.ok) throw new Error("Unable to sign out. Please retry.");
    window.google?.accounts.id.disableAutoSelect();
    setUser(null);
  }} />;

  return <main className="login-screen">
    <Script src="https://accounts.google.com/gsi/client" onReady={() => setGoogleReady(true)} onError={() => setError("Google sign-in could not load. Check your connection and reload.")} />
    <div className="login-card">
      <img src="/icon.svg" width="72" height="72" alt="" />
      <h1>Lock In Bud</h1>
      <p>Your schedule, tasks, habits, and focus.<br />The same account, on every screen.</p>
      {loading ? <p role="status">Connecting...</p> : <>
        <div id="google-sign-in" />
        {!clientId && <p role="status">Google sign-in is not configured yet. See the web setup guide.</p>}
        <p className="secondary">Sign in with the Google account you use in the app.</p>
      </>}
      {error && <div role="alert"><p>{error}</p><button onClick={() => void loadSession()}>Retry</button></div>}
      <details><summary>Use it like an app</summary><p>On iPhone, open in Safari, tap Share, then Add to Home Screen. On Android or desktop, use your browser&apos;s Install app option.</p></details>
    </div>
  </main>;
}
