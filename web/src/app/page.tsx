"use client";

import { Sheet } from "@/components/sheet";
import { useEffect, useRef, useState } from "react";
import Script from "next/script";
import Planner from "@/components/planner";
import { clearOfflineAccount, discardTaskConflict, expiredEvent, initializeOfflineAccount, offlineEvent, restoredOfflineAccount, syncOfflineTasks, type OfflineStatus, type OfflineUser } from "@/lib/offline";

type User = OfflineUser;
declare global {
  interface Window {
    google?: { accounts: { id: {
      initialize: (options: { client_id: string; callback: (response: { credential: string }) => void }) => void;
      renderButton: (element: HTMLElement, options: { theme: string; size: string; width: number }) => void;
      disableAutoSelect: () => void;
    }; oauth2: {
      initTokenClient: (options: {
        client_id: string;
        scope: string;
        callback: (response: { access_token?: string; expires_in?: number; scope?: string; error?: string }) => void;
        error_callback: (error: { type: string }) => void;
      }) => { requestAccessToken: (options: { prompt: string }) => void };
    } } };
  }
}

export default function Home() {
  const [user, setUser] = useState<User | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [googleReady, setGoogleReady] = useState(false);
  const [offline, setOffline] = useState<OfflineStatus>({ online: true, available: false, pending: 0, conflicts: [], error: "" });
  const [syncing, setSyncing] = useState(false);
  const sessionSequence = useRef(0);
  const [discardConflict, setDiscardConflict] = useState<{ id: string; title: string } | null>(null);
  const clientId = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID;

  async function acceptUser(value: User, sequence: number) {
    if (sequence !== sessionSequence.current) return false;
    try { await initializeOfflineAccount(value); }
    catch (e) { setOffline(status => ({ ...status, error: (e as Error).message })); }
    if (sequence !== sessionSequence.current) return false;
    setError("");
    setUser(value);
    return true;
  }
  async function retrySync() {
    setSyncing(true);
    try { await syncOfflineTasks(); }
    catch (e) { setOffline(status => ({ ...status, error: (e as Error).message })); }
    finally { setSyncing(false); }
  }
  async function loadSession(foreground = false) {
    const sequence = ++sessionSequence.current;
    if (!foreground) setLoading(true);
    setError("");
    try {
      const response = await fetch("/api/session", { cache: "no-store" });
      if (sequence !== sessionSequence.current) return false;
      if (response.ok) return await acceptUser(await response.json(), sequence);
      else if (response.status === 401) {
        setUser(null); await clearOfflineAccount();
        if (foreground) setError("Your session has expired. Sign in again. Pending task changes remain on this device for the same account.");
      }
      else if (response.status !== 401) throw new Error("Unable to reach the service. Please retry.");
    } catch (e) {
      if (sequence !== sessionSequence.current) return false;
      if (!foreground && !navigator.onLine) {
        try { const restored = await restoredOfflineAccount(); if (restored) { await acceptUser(restored, sequence); return false; } }
        catch { /* Keep the sign-in error if offline storage is inaccessible. */ }
      }
      setError((e as Error).message);
    }
    finally { if (sequence === sessionSequence.current) setLoading(false); }
    return false;
  }
  useEffect(() => {
    const status = (event: Event) => setOffline((event as CustomEvent<OfflineStatus>).detail);
    const expired = () => {
      sessionSequence.current++;
      setUser(null); setLoading(false); setError("Your session has expired. Sign in again. Pending task changes remain on this device for the same account.");
      void clearOfflineAccount().catch(() => {});
    };
    const foreground = () => {
      setOffline(status => ({ ...status, online: navigator.onLine }));
      if (document.visibilityState === "visible" && navigator.onLine) {
        void loadSession(true).then(valid => { if (valid) void retrySync(); });
      }
    };
    const disconnected = () => setOffline(status => ({ ...status, online: false }));
    window.addEventListener(offlineEvent, status);
    window.addEventListener(expiredEvent, expired);
    window.addEventListener("online", foreground);
    window.addEventListener("offline", disconnected);
    window.addEventListener("focus", foreground);
    document.addEventListener("visibilitychange", foreground);
    void loadSession().then(valid => { if (valid) void retrySync(); });
    if ("serviceWorker" in navigator && process.env.NODE_ENV === "production") {
      navigator.serviceWorker.register("/sw.js").catch(() => {});
    }
    return () => {
      window.removeEventListener(offlineEvent, status);
      window.removeEventListener(expiredEvent, expired);
      window.removeEventListener("online", foreground);
      window.removeEventListener("offline", disconnected);
      window.removeEventListener("focus", foreground);
      document.removeEventListener("visibilitychange", foreground);
    };
  }, []);

  useEffect(() => {
    const element = document.getElementById("google-sign-in");
    if (!googleReady || loading || user || !clientId || !element || !window.google) return;
    window.google.accounts.id.initialize({ client_id: clientId, callback: async ({ credential }) => {
      const sequence = ++sessionSequence.current;
      setError(""); setLoading(true);
      try {
        const response = await fetch("/api/session", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ id_token: credential }) });
        const data = await response.json();
        if (!response.ok) throw new Error(data.detail || "Unable to sign in.");
        if (await acceptUser(data, sequence)) void retrySync();
      } catch (e) { setError((e as Error).message); }
      finally { setLoading(false); }
    } });
    window.google.accounts.id.renderButton(element, { theme: "outline", size: "large", width: 280 });
  }, [googleReady, loading, user, clientId]);

  if (user) {
    const syncingPending = syncing && (offline.pending > 0 || !!offline.error);
    const needsAttention = !offline.online || offline.pending > 0 || !!offline.error || offline.conflicts.length > 0 || !offline.available || !!error || syncingPending;
    const pendingLabel = `${offline.pending} task change${offline.pending === 1 ? "" : "s"}`;
    const status = syncingPending
      ? "Syncing changes…"
      : offline.error
        ? "Couldn’t sync. Your changes are still saved on this device."
        : !offline.online
          ? offline.available
            ? offline.pending
              ? `Offline. ${pendingLabel} saved on this device; ${offline.pending === 1 ? "it" : "they"} will sync when you reconnect.`
              : "Offline. Keep editing tasks; changes will sync when you reconnect."
            : "Offline. Reconnect to download your tasks before editing."
          : offline.pending
            ? `${pendingLabel} waiting to sync.`
            : !offline.available
              ? "Online. Offline editing isn’t ready for this account yet."
              : "Task sync needs attention.";
    return <>
      {needsAttention ? <section className="sync-status" aria-label="Task sync status">
        <p role="status" aria-live="polite">{status}</p>
        {error && <p role="alert">{error}</p>}
        {offline.error && <p role="alert">{offline.error}</p>}
        {(offline.pending > 0 || offline.error) && <button disabled={!offline.online || syncing} onClick={() => void retrySync()}>{syncing ? "Syncing tasks..." : "Retry task sync"}</button>}
        {offline.conflicts.map(conflict => <div key={conflict.id} role="alert">
          <p>Task sync needs review: {conflict.title}. {conflict.detail} Local changes are kept and won’t overwrite the server.</p>
          <p>Discard the local changes, then refresh tasks to see the server version.</p>
          <button onClick={() => setDiscardConflict({ id: conflict.id, title: conflict.title })}>Discard local changes for {conflict.title}</button>
        </div>)}
      </section> : <section className="sr-only" aria-label="Task sync status"><p role="status" aria-live="polite">No pending task changes.</p></section>}
      {discardConflict && <Sheet title="Discard local changes" onClose={() => setDiscardConflict(null)}><p>Discard queued changes for {discardConflict.title} and keep the server version? This cannot be undone.</p><div className="row"><button autoFocus onClick={() => setDiscardConflict(null)}>Cancel</button><button className="danger" onClick={() => { const id = discardConflict.id; setDiscardConflict(null); void discardTaskConflict(id).then(retrySync).catch(e => setOffline(status => ({ ...status, error: (e as Error).message }))); }}>Discard changes</button></div></Sheet>}
      <Planner key={user.id} user={user} onLogout={async () => {
        const response = await fetch("/api/session", { method: "DELETE" });
        if (!response.ok) throw new Error("Unable to sign out. Please retry.");
        sessionSequence.current++;
        window.google?.accounts.id.disableAutoSelect();
        setUser(null);
        await clearOfflineAccount();
      }} /></>;
  }

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
