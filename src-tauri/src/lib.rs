use std::{
    sync::Mutex,
    time::{Duration, Instant},
};

use serde::Serialize;
use tauri::{Manager, State};
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};
use thiserror::Error;

const STARTUP_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Debug, Error)]
enum SupervisorError {
    #[error("Codex is already running")]
    AlreadyRunning,
    #[error("Codex did not report an app-server endpoint within {0:?}")]
    StartupTimeout(Duration),
    #[error("{0}")]
    Shell(String),
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct CodexStatus {
    phase: CodexPhase,
    ws_url: Option<String>,
    readyz_url: Option<String>,
    healthz_url: Option<String>,
    message: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
enum CodexPhase {
    Stopped,
    Starting,
    Running,
    Unhealthy,
}

impl CodexStatus {
    fn stopped() -> Self {
        Self {
            phase: CodexPhase::Stopped,
            ws_url: None,
            readyz_url: None,
            healthz_url: None,
            message: None,
        }
    }
}

#[derive(Default)]
struct CodexSupervisor {
    runtime: Mutex<Option<CodexRuntime>>,
}

struct CodexRuntime {
    child: CommandChild,
    status: CodexStatus,
}

impl CodexSupervisor {
    fn status(&self) -> CodexStatus {
        let guard = self.runtime.lock().expect("supervisor lock poisoned");
        guard
            .as_ref()
            .map(|runtime| runtime.status.clone())
            .unwrap_or_else(CodexStatus::stopped)
    }

    fn set_status(&self, status: CodexStatus) {
        if let Some(runtime) = self
            .runtime
            .lock()
            .expect("supervisor lock poisoned")
            .as_mut()
        {
            runtime.status = status;
        }
    }

    fn stop(&self) -> CodexStatus {
        if let Some(runtime) = self
            .runtime
            .lock()
            .expect("supervisor lock poisoned")
            .take()
        {
            let _ = runtime.child.kill();
        }
        CodexStatus::stopped()
    }
}

#[tauri::command]
async fn start_codex(
    app: tauri::AppHandle,
    supervisor: State<'_, CodexSupervisor>,
) -> Result<CodexStatus, String> {
    if !matches!(supervisor.status().phase, CodexPhase::Stopped) {
        return Err(SupervisorError::AlreadyRunning.to_string());
    }

    let command = app
        .shell()
        .sidecar("codex")
        .map_err(|err| SupervisorError::Shell(err.to_string()).to_string())?
        .args(["app-server", "--listen", "ws://127.0.0.1:0"]);

    let (mut rx, child) = command
        .spawn()
        .map_err(|err| SupervisorError::Shell(err.to_string()).to_string())?;

    let mut status = CodexStatus {
        phase: CodexPhase::Starting,
        ws_url: None,
        readyz_url: None,
        healthz_url: None,
        message: Some("Waiting for Codex app-server to report endpoints.".to_string()),
    };
    let deadline = Instant::now() + STARTUP_TIMEOUT;

    while Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(250), rx.recv()).await {
            Ok(Some(event)) => apply_command_event(&mut status, event),
            Ok(None) => {
                status.phase = CodexPhase::Unhealthy;
                status.message = Some("Codex app-server exited during startup.".to_string());
                break;
            }
            Err(_) => {}
        }

        if status.ws_url.is_some() && status.readyz_url.is_some() && status.healthz_url.is_some() {
            status.phase = CodexPhase::Running;
            status.message = Some("Codex app-server is running.".to_string());
            break;
        }
    }

    if !matches!(status.phase, CodexPhase::Running) {
        return Err(SupervisorError::StartupTimeout(STARTUP_TIMEOUT).to_string());
    }

    *supervisor.runtime.lock().expect("supervisor lock poisoned") = Some(CodexRuntime {
        child,
        status: status.clone(),
    });

    let app_for_events = app.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            let supervisor_handle = app_for_events.state::<CodexSupervisor>();
            let mut next = supervisor_handle.status();
            apply_command_event(&mut next, event);
            supervisor_handle.set_status(next);
        }

        let supervisor_handle = app_for_events.state::<CodexSupervisor>();
        let mut next = supervisor_handle.status();
        next.phase = CodexPhase::Stopped;
        next.message = Some("Codex app-server stopped.".to_string());
        supervisor_handle.set_status(next);
    });

    Ok(status)
}

#[tauri::command]
fn stop_codex(supervisor: State<'_, CodexSupervisor>) -> CodexStatus {
    supervisor.stop()
}

#[tauri::command]
fn codex_status(supervisor: State<'_, CodexSupervisor>) -> CodexStatus {
    supervisor.status()
}

fn apply_command_event(status: &mut CodexStatus, event: CommandEvent) {
    match event {
        CommandEvent::Stdout(bytes) | CommandEvent::Stderr(bytes) => {
            if let Ok(text) = String::from_utf8(bytes) {
                for line in text.lines() {
                    parse_codex_line(status, line.trim());
                }
            }
        }
        CommandEvent::Terminated(payload) => {
            status.phase = CodexPhase::Stopped;
            status.message = Some(format!("Codex exited with status {:?}.", payload.code));
        }
        _ => {}
    }
}

fn parse_codex_line(status: &mut CodexStatus, line: &str) {
    if let Some(url) = line.strip_prefix("listening on: ") {
        status.ws_url = Some(url.trim().to_string());
    } else if let Some(url) = line.strip_prefix("readyz: ") {
        status.readyz_url = Some(url.trim().to_string());
    } else if let Some(url) = line.strip_prefix("healthz: ") {
        status.healthz_url = Some(url.trim().to_string());
    } else if !line.is_empty() {
        status.message = Some(line.to_string());
    }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .manage(CodexSupervisor::default())
        .invoke_handler(tauri::generate_handler![
            start_codex,
            stop_codex,
            codex_status
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Modex")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) {
                app.state::<CodexSupervisor>().stop();
            }
        });
}
