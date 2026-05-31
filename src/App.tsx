import { invoke } from "@tauri-apps/api/core";
import {
  Activity,
  AppWindow,
  CheckCircle2,
  Command,
  FolderOpen,
  Loader2,
  Play,
  Search,
  Settings,
  ShieldCheck,
  Square,
  Terminal,
} from "lucide-react";
import { useEffect, useMemo, useState } from "react";
import brand from "../assets/brand/modex-wordmark.png";

type CodexPhase = "stopped" | "starting" | "running";

type CodexStatus = {
  phase: CodexPhase;
  wsUrl: string | null;
  readyzUrl: string | null;
  healthzUrl: string | null;
  message: string | null;
};

const stoppedStatus: CodexStatus = {
  phase: "stopped",
  wsUrl: null,
  readyzUrl: null,
  healthzUrl: null,
  message: null,
};

const statusLabel: Record<CodexPhase, string> = {
  stopped: "Stopped",
  starting: "Starting",
  running: "Running",
};

function App() {
  const isTauri = "__TAURI_INTERNALS__" in window;
  const [status, setStatus] = useState<CodexStatus>(stoppedStatus);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const canStop = status.phase === "running";
  const isRunning = status.phase === "running";

  async function refreshStatus() {
    if (!isTauri) return;
    try {
      setStatus(await invoke<CodexStatus>("codex_status"));
    } catch (err) {
      setError(String(err));
    }
  }

  async function startCodex() {
    if (!isTauri) return;
    setBusy(true);
    setError(null);
    try {
      setStatus(await invoke<CodexStatus>("start_codex"));
    } catch (err) {
      setError(String(err));
    } finally {
      setBusy(false);
    }
  }

  async function stopCodex() {
    if (!isTauri) return;
    setBusy(true);
    setError(null);
    try {
      setStatus(await invoke<CodexStatus>("stop_codex"));
    } catch (err) {
      setError(String(err));
    } finally {
      setBusy(false);
    }
  }

  useEffect(() => {
    refreshStatus();
    const interval = window.setInterval(refreshStatus, 5000);
    return () => window.clearInterval(interval);
  }, []);

  const healthText = useMemo(() => {
    if (error) return error;
    if (status.message) return status.message;
    if (status.wsUrl) return status.wsUrl;
    if (!isTauri) return "Open Modex as the desktop app to control the Codex engine.";
    return "Codex app-server is ready to be started.";
  }, [error, isTauri, status.message, status.wsUrl]);

  return (
    <main className="shell">
      <aside className="sidebar">
        <img className="brand" src={brand} alt="Modex" />

        <nav className="nav" aria-label="Primary">
          <button className="navItem active" type="button">
            <Terminal size={17} />
            Sessions
          </button>
          <button className="navItem" type="button">
            <Search size={17} />
            Search
          </button>
          <button className="navItem" type="button">
            <Command size={17} />
            Palette
          </button>
          <button className="navItem" type="button">
            <FolderOpen size={17} />
            Projects
          </button>
        </nav>

        <div className="sidebarFooter">
          <button className="navItem" type="button">
            <Settings size={17} />
            Settings
          </button>
        </div>
      </aside>

      <section className="content">
        <header className="topbar">
          <div>
            <p className="eyebrow">Modex v0.1</p>
            <h1>Codex engine, Modex workspace.</h1>
          </div>
          <div className={`status ${status.phase}`}>
            <span />
            {statusLabel[status.phase]}
          </div>
        </header>

        <section className="heroPanel">
          <div className="heroCopy">
            <div className="heroIcon">
              <AppWindow size={24} />
            </div>
            <h2>Start the local Codex app-server.</h2>
            <p>
              Modex launches Codex as a managed sidecar, tracks its process,
              and keeps the UI ready for sessions, approvals, diffs, and
              project tools.
            </p>

            <div className="actions">
              <button className="primary" disabled={!isTauri || busy || isRunning} onClick={startCodex} type="button">
                {busy && !canStop ? <Loader2 className="spin" size={18} /> : <Play size={18} />}
                Start Codex
              </button>
              <button className="secondary" disabled={!isTauri || busy || !canStop} onClick={stopCodex} type="button">
                {busy && canStop ? <Loader2 className="spin" size={18} /> : <Square size={16} />}
                Stop
              </button>
            </div>
          </div>

          <div className="healthCard">
            <div className="metricHeader">
              <Activity size={18} />
              Engine health
            </div>
            <p className={error ? "errorText" : ""}>{healthText}</p>
            <dl>
              <div>
                <dt>Transport</dt>
                <dd>{status.wsUrl ? "WebSocket" : "Not connected"}</dd>
              </div>
              <div>
                <dt>Ready</dt>
                <dd>{status.readyzUrl ? "Endpoint captured" : "Waiting"}</dd>
              </div>
              <div>
                <dt>Health</dt>
                <dd>{status.healthzUrl ? "Process watched" : "Idle"}</dd>
              </div>
            </dl>
          </div>
        </section>

        <section className="grid">
          <article>
            <ShieldCheck size={20} />
            <h3>Release-first foundation</h3>
            <p>DMG packaging, pinned Codex sidecar preparation, and clean public repo structure.</p>
          </article>
          <article>
            <CheckCircle2 size={20} />
            <h3>Thin engine boundary</h3>
            <p>Codex runs unmodified behind a small supervisor so upstream updates stay manageable.</p>
          </article>
          <article>
            <Command size={20} />
            <h3>Ready for the pro UI</h3>
            <p>Sessions, command palette, snippets, and approvals can build on the same bridge.</p>
          </article>
        </section>
      </section>
    </main>
  );
}

export default App;
