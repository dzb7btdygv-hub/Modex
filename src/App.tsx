import { invoke } from "@tauri-apps/api/core";
import { FormEvent, useCallback, useEffect, useRef, useState } from "react";
import { CodexRpc } from "./codexRpc";

type CodexPhase = "stopped" | "starting" | "running";

type CodexStatus = {
  phase: CodexPhase;
  wsUrl: string | null;
  readyzUrl: string | null;
  healthzUrl: string | null;
  message: string | null;
};

type MessageRole = "user" | "assistant" | "system";

type ChatMessage = {
  id: string;
  role: MessageRole;
  text: string;
  pending?: boolean;
};

type ThreadStartResponse = {
  thread: {
    id: string;
  };
};

const isTauri = "__TAURI_INTERNALS__" in window;

function App() {
  const [messages, setMessages] = useState<ChatMessage[]>([]);
  const [draft, setDraft] = useState("");
  const [status, setStatus] = useState("Starting Codex.");
  const [ready, setReady] = useState(false);
  const [turnRunning, setTurnRunning] = useState(false);

  const rpcRef = useRef<CodexRpc | null>(null);
  const threadIdRef = useRef<string | null>(null);
  const messagesEndRef = useRef<HTMLDivElement | null>(null);

  const addSystemMessage = useCallback((text: string) => {
    setMessages((current) => [
      ...current,
      { id: `system-${crypto.randomUUID()}`, role: "system", text },
    ]);
  }, []);

  const handleNotification = useCallback(
    (method: string, params: unknown) => {
      const data = params as Record<string, unknown> | null;

      switch (method) {
        case "item/started": {
          const item = data?.item as Record<string, unknown> | undefined;
          if (item?.type === "agentMessage" && typeof item.id === "string") {
            const id = `assistant-${item.id}`;
            setMessages((current) =>
              current.some((message) => message.id === id)
                ? current
                : [...current, { id, role: "assistant", text: "", pending: true }],
            );
          }
          break;
        }
        case "item/agentMessage/delta": {
          if (!data || typeof data.itemId !== "string" || typeof data.delta !== "string") {
            break;
          }

          const id = `assistant-${data.itemId}`;
          const delta = data.delta;
          setMessages((current) => {
            const index = current.findIndex((message) => message.id === id);
            if (index === -1) {
              return [...current, { id, role: "assistant", text: delta, pending: true }];
            }

            return current.map((message, messageIndex) =>
              messageIndex === index
                ? { ...message, text: `${message.text}${delta}`, pending: true }
                : message,
            );
          });
          break;
        }
        case "item/completed": {
          const item = data?.item as Record<string, unknown> | undefined;
          if (item?.type === "agentMessage" && typeof item.id === "string") {
            const id = `assistant-${item.id}`;
            const text = typeof item.text === "string" ? item.text : "";
            setMessages((current) =>
              current.map((message) =>
                message.id === id ? { ...message, text, pending: false } : message,
              ),
            );
          }
          break;
        }
        case "turn/completed": {
          setTurnRunning(false);
          setStatus("Ready.");

          const turn = data?.turn as Record<string, unknown> | undefined;
          const error = turn?.error;
          if (error) addSystemMessage(formatError(error));
          break;
        }
        case "error": {
          setTurnRunning(false);
          setStatus("Codex returned an error.");
          addSystemMessage(formatError(data?.error ?? params));
          break;
        }
        default:
          break;
      }
    },
    [addSystemMessage],
  );

  useEffect(() => {
    messagesEndRef.current?.scrollIntoView({ block: "end" });
  }, [messages]);

  useEffect(() => {
    let cancelled = false;

    async function boot() {
      if (!isTauri) {
        setStatus("Open Modex as the desktop app to use chat.");
        return;
      }

      try {
        const codex = await ensureCodexRunning();
        if (cancelled) return;

        setStatus("Connecting to Codex.");
        const rpc = await CodexRpc.connect(
          codex.wsUrl,
          handleNotification,
          (reason) => {
            if (cancelled) return;
            rpcRef.current = null;
            threadIdRef.current = null;
            setReady(false);
            setTurnRunning(false);
            setStatus(reason);
          },
        );

        if (cancelled) {
          rpc.close();
          return;
        }

        rpcRef.current = rpc;

        await rpc.request("initialize", {
          clientInfo: { name: "modex", title: "Modex", version: "0.1.0" },
          capabilities: { experimentalApi: true, requestAttestation: false },
        });

        if (cancelled) return;

        setReady(true);
        setStatus("Ready.");
      } catch (error) {
        if (cancelled) return;
        const message = formatError(error);
        setReady(false);
        setStatus(message);
        addSystemMessage(message);
      }
    }

    boot();

    return () => {
      cancelled = true;
      rpcRef.current?.close();
      rpcRef.current = null;
    };
  }, [addSystemMessage, handleNotification]);

  async function submitMessage(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();

    const text = draft.trim();
    const rpc = rpcRef.current;

    if (!text || !rpc || turnRunning) return;

    setDraft("");
    setTurnRunning(true);
    setStatus(threadIdRef.current ? "Thinking." : "Starting chat.");
    setMessages((current) => [
      ...current,
      { id: `user-${crypto.randomUUID()}`, role: "user", text },
    ]);

    try {
      const threadId = await ensureThread(rpc, threadIdRef);
      setStatus("Thinking.");
      await rpc.request("turn/start", {
        threadId,
        input: [{ type: "text", text, text_elements: [] }],
      });
    } catch (error) {
      setTurnRunning(false);
      setStatus("Could not send message.");
      addSystemMessage(formatError(error));
    }
  }

  const canSend = ready && !turnRunning && draft.trim().length > 0;

  return (
    <main className="chatShell">
      <section className="conversation" aria-live="polite">
        {messages.length === 0 ? (
          <div className="emptyState">
            <h1>Modex</h1>
            <p>{status}</p>
          </div>
        ) : (
          messages.map((message) => (
            <article className={`message ${message.role}`} key={message.id}>
              <p>{message.text || (message.pending ? "Thinking..." : "")}</p>
            </article>
          ))
        )}
        <div ref={messagesEndRef} />
      </section>

      <form className="composer" onSubmit={submitMessage}>
        <input
          autoComplete="off"
          autoFocus
          disabled={!ready || turnRunning}
          onChange={(event) => setDraft(event.target.value)}
          placeholder={ready ? "Ask Codex anything." : status}
          value={draft}
        />
        <button disabled={!canSend} type="submit">
          Send
        </button>
      </form>
      <p className="statusLine">{status}</p>
    </main>
  );
}

async function ensureThread(
  rpc: CodexRpc,
  threadIdRef: { current: string | null },
): Promise<string> {
  if (threadIdRef.current) return threadIdRef.current;

  const thread = await rpc.request<ThreadStartResponse>("thread/start", {
    approvalPolicy: "never",
    sandbox: "read-only",
    ephemeral: true,
  });

  threadIdRef.current = thread.thread.id;
  return thread.thread.id;
}

async function ensureCodexRunning(): Promise<CodexStatus & { wsUrl: string }> {
  let status = await invoke<CodexStatus>("codex_status");
  let startError: unknown = null;

  if (status.phase === "stopped") {
    try {
      status = await invoke<CodexStatus>("start_codex");
    } catch (error) {
      startError = error;
      status = await invoke<CodexStatus>("codex_status");
    }
  }

  for (let attempt = 0; attempt < 24; attempt += 1) {
    if (status.phase === "running" && status.wsUrl) {
      return status as CodexStatus & { wsUrl: string };
    }

    await delay(500);
    status = await invoke<CodexStatus>("codex_status");
  }

  if (startError) throw startError;
  throw new Error(status.message ?? "Codex did not expose a WebSocket endpoint.");
}

function delay(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}

function formatError(error: unknown): string {
  if (typeof error === "string") return error;
  if (!error || typeof error !== "object") return "Unknown error.";

  const value = error as { message?: unknown; data?: unknown; error?: unknown };
  if (typeof value.message === "string") return value.message;
  if (value.error) return formatError(value.error);

  try {
    return JSON.stringify(value.data ?? value);
  } catch {
    return "Unknown error.";
  }
}

export default App;
