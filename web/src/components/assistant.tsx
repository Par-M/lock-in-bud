"use client";

import { useEffect, useRef, useState } from "react";
import { Plus, RefreshCw, Copy, Mic } from "lucide-react";
import { api } from "@/lib/api";
import { cacheAssistantHistory, readAssistantHistory, removeAssistantHistory, expiredEvent } from "@/lib/offline";
import { Sheet } from "./sheet";
import { Avatar, AvatarFallback } from "./ui/avatar";
import { Bubble, BubbleContent } from "./ui/bubble";
import { Message, MessageAvatar, MessageContent } from "./ui/message";
import { MessageScroller, MessageScrollerProvider, MessageScrollerViewport, MessageScrollerContent, MessageScrollerItem } from "./ui/message-scroller";

type Action = { action_id: string; name: string; args: Record<string, unknown>; status: string; result?: { client_action?: string; task_id?: string } };
type ChatMessage = { id: string; role: string; content: string | null; created_at?: string; tool_result?: { citations?: { id: string; title: string }[] } };
type Conversation = { id: string; title: string | null; messages?: ChatMessage[] | null; actions?: Action[] };
type SendResult = { conversation_id: string; message: ChatMessage; assistant_message: ChatMessage; actions?: Action[] };
const suggestions = ["What's my plan today?", "What's overdue?", "What can I focus on right now?"];
const request = (method: string, body?: unknown): RequestInit => ({ method, ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
const errorText = (error: unknown) => error instanceof Error ? error.message : "Please try again.";

// React escapes all strings. Only bold and allowlisted task links are parsed;
// HTML and arbitrary URLs never become executable markup.
function Formatted({ text, citations, onTask }: { text: string; citations: { id: string; title: string }[]; onTask: (id: string) => void }) {
  const inline = (line: string) => line.split(/(\*\*[^*]+\*\*|\[[^\]]+\]\(task:[a-fA-F0-9-]{36}\))/g).map((part, i) => {
    if (part.startsWith("**") && part.endsWith("**")) return <strong key={i}>{part.slice(2, -2)}</strong>;
    const match = /^\[([^\]]+)\]\(task:([a-fA-F0-9-]{36})\)$/.exec(part);
    if (match && citations.some(c => c.id === match[2])) return <button className="chat-task-link" key={i} onClick={() => onTask(match[2])}>{match[1]}</button>;
    return part;
  });
  return <>{text.split("\n").map((line, i) => <span key={i}>{inline(line)}{i < text.split("\n").length - 1 ? "\n" : ""}</span>)}</>;
}

type SpeechRecognition = { start(): void; stop(): void; onresult: ((event: { results: { [index: number]: { [index: number]: { transcript: string } } } }) => void) | null; onerror: (() => void) | null; onend: (() => void) | null };
export function Assistant({ userId, onClose, onTask, onChanged, onStartFocus }: {
  userId: string; onClose: () => void; onTask: (id: string) => void; onChanged: () => void; onStartFocus: (id?: string) => void;
}) {
  const [conversations, setConversations] = useState<Conversation[]>([]);
  const [current, setCurrent] = useState<Conversation | null>(null);
  const [content, setContent] = useState("");
  const [busy, setBusy] = useState(false);
  const [sending, setSending] = useState(false);
  const [partial, setPartial] = useState("");
  const [error, setError] = useState("");
  const [retryable, setRetryable] = useState(false);
  const [online, setOnline] = useState(true);
  const [memory, setMemory] = useState<string[]>([]);
  const [older, setOlder] = useState(false);
  const [voiceAvailable, setVoiceAvailable] = useState(false);
  const [listening, setListening] = useState(false);
  const sequence = useRef(0);
  const mounted = useRef(true);
  const inFlight = useRef(false);
  const controller = useRef<AbortController | null>(null);
  const pending = useRef<{ id: string; text: string; conversation: string } | null>(null);
  const drafts = useRef<Record<string, string>>({});
  const recognition = useRef<SpeechRecognition | null>(null);

  async function remember(conv: Conversation) {
    // Drop provider-only metadata from the browser history cache.
    await cacheAssistantHistory(userId, { ...conv, messages: conv.messages?.map(m => ({ id: m.id, role: m.role, content: m.content, created_at: m.created_at, tool_result: { citations: m.tool_result?.citations } })) }).catch(() => {});
  }
  async function select(id: string) {
    if (inFlight.current) return;
    const token = ++sequence.current;
    if (current) drafts.current[current.id] = content;
    setBusy(true); setError(""); setRetryable(false);
    try {
      const conv = await api<Conversation>(`/chat/conversations/${id}`);
      if (mounted.current && token === sequence.current) { setCurrent(conv); setContent(drafts.current[id] || ""); setOlder((conv.messages?.length || 0) >= 100); pending.current = null; await remember(conv); }
    } catch (e) { if (mounted.current && token === sequence.current) setError(errorText(e)); }
    finally { if (mounted.current && token === sequence.current) setBusy(false); }
  }
  async function load() {
    setBusy(true);
    try {
      const list = await api<Conversation[]>("/chat/conversations");
      if (!mounted.current) return;
      setConversations(list);
      if (list[0] && !current) await select(list[0].id);
      const prefs = await api<{ facts: string[] }>("/chat/memory");
      if (mounted.current) setMemory(prefs.facts || []);
    } catch (e) { if (mounted.current) setError(errorText(e)); }
    finally { if (mounted.current) setBusy(false); }
  }
  useEffect(() => {
    mounted.current = true;
    const status = () => { setOnline(navigator.onLine); };
    status(); window.addEventListener("online", status); window.addEventListener("offline", status);
    const speech = window as unknown as { SpeechRecognition?: unknown; webkitSpeechRecognition?: unknown };
    setVoiceAvailable(!!(speech.SpeechRecognition || speech.webkitSpeechRecognition));
    if (navigator.onLine) void load();
    else void readAssistantHistory<Conversation>(userId).then(c => { if (mounted.current && c) { setCurrent(c); setConversations([c]); } });
    return () => { mounted.current = false; sequence.current++; controller.current?.abort(); recognition.current?.stop(); window.removeEventListener("online", status); window.removeEventListener("offline", status); };
    // Account switches unmount this component; cleanup aborts the old stream.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [userId]);

  async function create(): Promise<Conversation | null> {
    const conv = await api<Conversation>("/chat/conversations", request("POST", {}));
    if (!mounted.current) return null;
    if (current) drafts.current[current.id] = content;
    setConversations(v => [conv, ...v]); setCurrent({ ...conv, messages: [] }); setContent(""); setOlder(false); pending.current = null;
    return conv;
  }
  async function send() {
    if (!content.trim() || inFlight.current || !online) return;
    inFlight.current = true; setBusy(true); setSending(true); setPartial(""); setError(""); setRetryable(false);
    const text = content.trim();
    try {
      const conv = current || await create();
      if (!conv) return;
      if (!pending.current || pending.current.text !== text || pending.current.conversation !== conv.id) pending.current = { id: crypto.randomUUID(), text, conversation: conv.id };
      controller.current = new AbortController();
      const response = await fetch(`/api/backend/chat/conversations/${conv.id}/messages`, {
        ...request("POST", { content: text, timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, request_id: pending.current.id }),
        headers: { "Content-Type": "application/json", "Accept": "text/event-stream" }, signal: controller.current.signal,
      });
      if (response.status === 401) window.dispatchEvent(new Event(expiredEvent));
      if (!response.ok) { const body = await response.json().catch(() => null); throw new Error(body?.detail || `Request failed (${response.status})`); }
      let result: SendResult | null = null;
      if (response.headers.get("Content-Type")?.includes("text/event-stream")) {
        const reader = response.body!.getReader(), decoder = new TextDecoder(); let buffer = "";
        for (;;) {
          const { done, value } = await reader.read();
          buffer += decoder.decode(value, { stream: !done });
          const lines = buffer.split("\n"); buffer = lines.pop() || "";
          for (const line of lines) if (line.startsWith("data:")) {
            const event = JSON.parse(line.slice(5));
            if (event.type === "delta" && mounted.current) setPartial(v => v + event.text);
            if (event.type === "tool_status" && mounted.current) setPartial("");
            if (event.type === "complete") result = event.result;
            if (event.type === "error") throw new Error(event.detail);
          }
          if (done) break;
        }
        if (!result) throw new Error("The connection ended before the reply was saved.");
      } else result = await response.json();
      if (!mounted.current || !result) return;
      const next = { ...conv, messages: [...(conv.messages || []), result.message, result.assistant_message], actions: result.actions || [] };
      setCurrent(next); setContent(""); drafts.current[conv.id] = ""; pending.current = null; await remember(next);
      // A failed history-list refresh must not turn a committed send into a
      // new retry with a different ID.
      await api<Conversation[]>("/chat/conversations").then(list => { if (mounted.current) setConversations(list); }).catch(() => {});
    } catch (e) { if (mounted.current) { setContent(text); setError(`Message not sent — your draft was kept. ${errorText(e)}`); setRetryable(true); } }
    finally { inFlight.current = false; if (mounted.current) { setBusy(false); setSending(false); setPartial(""); } }
  }
  async function decide(action: Action, confirm: boolean) {
    if (!current || inFlight.current || !online) return;
    inFlight.current = true; setBusy(true); setError("");
    try {
      const result = await api<Action>(`/chat/conversations/${current.id}/actions/${action.action_id}/${confirm ? "confirm" : "cancel"}`, request("POST", {}));
      if (!mounted.current) return;
      const next = { ...current, actions: current.actions?.map(a => a.action_id === result.action_id ? result : a) };
      setCurrent(next); await remember(next);
      if (result.status === "confirmed") {
        onChanged();
        if (confirm && result.result?.client_action === "start_focus_session") {
          const key = `assistant.focus:${userId}:${result.action_id}`;
          if (!localStorage.getItem(key)) { localStorage.setItem(key, "started"); onStartFocus(result.result.task_id); }
        }
        if (result.name === "remember_fact") setMemory((await api<{ facts: string[] }>("/chat/memory")).facts);
      }
    } catch (e) { if (mounted.current) setError(errorText(e)); }
    finally { inFlight.current = false; if (mounted.current) setBusy(false); }
  }
  async function manage(kind: "rename" | "delete") {
    if (!current) return;
    let title: string | null = null;
    if (kind === "rename") { title = window.prompt("Conversation title", current.title || ""); if (!title?.trim()) return; }
    else if (!window.confirm("Delete this conversation and its history?")) return;
    setBusy(true);
    try {
      await api(`/chat/conversations/${current.id}`, request(kind === "rename" ? "PATCH" : "DELETE", kind === "rename" ? { title } : undefined));
      if (kind === "rename") setCurrent({ ...current, title });
      else { setCurrent(null); setContent(""); pending.current = null; await removeAssistantHistory(userId); }
      setConversations(await api<Conversation[]>("/chat/conversations"));
    } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  }
  async function loadOlder() {
    if (!current) return;
    setBusy(true);
    try {
      const anchor = current.messages?.[0]?.id;
      if (!anchor) { setOlder(false); return; }
      const page = await api<ChatMessage[]>(`/chat/conversations/${current.id}/messages?limit=100&before=${anchor}`);
      setCurrent({ ...current, messages: [...page, ...(current.messages || [])] }); setOlder(page.length === 100);
    } catch (e) { setError(errorText(e)); } finally { setBusy(false); }
  }
  function voice() {
    if (listening) { recognition.current?.stop(); return; }
    const surface = window as unknown as { SpeechRecognition?: new () => SpeechRecognition; webkitSpeechRecognition?: new () => SpeechRecognition };
    const Type = surface.SpeechRecognition || surface.webkitSpeechRecognition;
    if (!Type) return;
    const engine = new Type(); recognition.current = engine;
    engine.onresult = event => setContent(v => (v + " " + event.results[0][0].transcript).trim());
    engine.onerror = () => { setListening(false); setError("Voice input is unavailable. You can type your message."); };
    engine.onend = () => setListening(false);
    engine.start(); setListening(true);
  }
  return <Sheet title="Planner assistant" onClose={onClose}><div className="stack">
    <p className="muted">Ask about your planner. Review and confirm proposed changes before they are applied.</p>
    <div className="row"><label className="grow">Conversation<select value={current?.id || ""} disabled={busy || !online} onChange={e => void select(e.target.value)}><option value="">Choose a conversation</option>{conversations.map(c => <option key={c.id} value={c.id}>{c.title || "Untitled conversation"}</option>)}</select></label>
      <button disabled={busy || !online} onClick={() => { setBusy(true); void create().catch(e => setError(errorText(e))).finally(() => setBusy(false)); }}><Plus /> New</button></div>
    {conversations.length > 0 && conversations.length % 50 === 0 && <button disabled={busy || !online} onClick={() => {
      setBusy(true); void api<Conversation[]>(`/chat/conversations?offset=${conversations.length}`).then(list => setConversations(v => [...v, ...list])).catch(e => setError(errorText(e))).finally(() => setBusy(false));
    }}>Load older conversations</button>}
    {current && <div className="row"><button disabled={busy || !online} onClick={() => void manage("rename")}>Rename</button><button disabled={busy || !online} onClick={() => void manage("delete")}>Delete conversation</button></div>}
    {!online && <p role="status">The assistant needs a connection. Saved history is readable.</p>}
    {error && <div className="error" role="alert">{error}{retryable && <button disabled={busy || !online} onClick={() => void send()}>Retry</button>}</div>}
    <MessageScrollerProvider key={current?.id || "empty"} defaultScrollPosition="end"><MessageScroller><MessageScrollerViewport aria-label="Conversation messages"><MessageScrollerContent aria-live="polite">
      {older && <button disabled={busy || !online} onClick={() => void loadOlder()}>Load older messages</button>}
      {!current?.messages?.length && <div className="empty"><p>Ask the assistant about your day.</p>{suggestions.map(s => <button key={s} onClick={() => setContent(s)}>{s}</button>)}</div>}
      {current?.messages?.filter(m => m.content && (m.role === "user" || m.role === "assistant")).map(m => <MessageScrollerItem key={m.id} messageId={m.id}><Message align={m.role === "user" ? "end" : "start"} role="article" aria-label={m.role === "user" ? "You" : "Assistant"}>
        <MessageAvatar aria-hidden="true"><Avatar><AvatarFallback>{m.role === "user" ? "Y" : "A"}</AvatarFallback></Avatar></MessageAvatar><MessageContent><Bubble><BubbleContent><Formatted text={m.content || ""} citations={m.tool_result?.citations || []} onTask={onTask} /></BubbleContent></Bubble>
          <div className="chat-meta">{m.created_at && <time dateTime={m.created_at}>{new Date(m.created_at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })}</time>}<button aria-label="Copy message" onClick={() => void navigator.clipboard.writeText(m.content || "").catch(() => setError("Copy is unavailable in this browser."))}><Copy size={14} /></button></div>
        </MessageContent></Message></MessageScrollerItem>)}
      {sending && <div role="status">{partial || "Assistant is thinking…"}</div>}
    </MessageScrollerContent></MessageScrollerViewport></MessageScroller></MessageScrollerProvider>
    {current?.actions?.map(a => <section className="chat-action" key={a.action_id} aria-label="Proposed action"><strong>{a.name.replaceAll("_", " ")}</strong><pre>{JSON.stringify(a.args, null, 2)}</pre>{a.status === "pending" ? <div className="row"><button disabled={busy || !online} onClick={() => void decide(a, true)}>Confirm</button><button disabled={busy || !online} onClick={() => void decide(a, false)}>Cancel</button></div> : <p>{a.status}</p>}</section>)}
    <form className="stack compact" onSubmit={e => { e.preventDefault(); void send(); }}><label>Message<textarea value={content} onChange={e => setContent(e.target.value)} maxLength={8000} rows={3} placeholder="Help me plan my day..." disabled={sending} /></label><div className="row">
      <button type="button" disabled={busy || !online} onClick={() => current ? void select(current.id) : void load()}><RefreshCw /> Refresh history</button>
      {voiceAvailable && <button type="button" disabled={busy || !online} onClick={voice}><Mic />{listening ? "Stop dictation" : "Dictate"}</button>}
      <button className="primary" disabled={busy || !content.trim() || !online}>{sending ? "Working..." : "Send message"}</button>
    </div></form>
    <details><summary>Assistant memory</summary>{memory.length ? <ul>{memory.map(f => <li key={f}>{f}</li>)}</ul> : <p>No remembered preferences.</p>}<button disabled={busy || !online || !memory.length} onClick={() => { void api("/chat/memory", request("DELETE")).then(() => setMemory([])).catch(e => setError(errorText(e))); }}>Clear remembered preferences</button></details>
  </div></Sheet>;
}
