use std::{
    mem,
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
use url::Url;

const MAX_STATUS_MESSAGE_CHARS: usize = 4096;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(12);

#[derive(Debug, Error)]
enum SupervisorError {
    #[error("Codex is already running")]
    AlreadyRunning,
    #[error("Codex startup was cancelled")]
    StartupCancelled,
    #[error("Codex app-server exited during startup")]
    StartupExited,
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

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum CodexPhase {
    Stopped,
    Starting,
    Running,
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
    state: Mutex<CodexSupervisorState>,
}

#[derive(Default)]
struct CodexSupervisorState {
    next_generation: u64,
    runtime: CodexRuntime,
}

// Generation IDs prevent late sidecar events from mutating a restarted runtime.
#[derive(Default)]
enum CodexRuntime {
    #[default]
    Stopped,
    Starting {
        generation: u64,
        child: Option<CommandChild>,
        status: CodexStatus,
    },
    Running {
        generation: u64,
        child: CommandChild,
        status: CodexStatus,
    },
}

impl CodexSupervisor {
    fn status(&self) -> CodexStatus {
        let guard = self.state.lock().expect("supervisor lock poisoned");
        match &guard.runtime {
            CodexRuntime::Stopped => CodexStatus::stopped(),
            CodexRuntime::Starting { status, .. } | CodexRuntime::Running { status, .. } => {
                status.clone()
            }
        }
    }

    fn reserve_starting(&self) -> Result<u64, SupervisorError> {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        if !matches!(guard.runtime, CodexRuntime::Stopped) {
            return Err(SupervisorError::AlreadyRunning);
        }

        guard.next_generation = guard.next_generation.wrapping_add(1);
        let generation = guard.next_generation;
        guard.runtime = CodexRuntime::Starting {
            generation,
            child: None,
            status: CodexStatus {
                phase: CodexPhase::Starting,
                ws_url: None,
                readyz_url: None,
                healthz_url: None,
                message: Some("Waiting for Codex app-server to report endpoints.".to_string()),
            },
        };

        Ok(generation)
    }

    fn attach_child(&self, generation: u64, child: CommandChild) -> Result<(), CommandChild> {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        match &mut guard.runtime {
            CodexRuntime::Starting {
                generation: current,
                child: slot,
                ..
            } if *current == generation && slot.is_none() => {
                *slot = Some(child);
                Ok(())
            }
            _ => Err(child),
        }
    }

    fn promote_running(&self, generation: u64, status: CodexStatus) -> bool {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        let runtime = mem::replace(&mut guard.runtime, CodexRuntime::Stopped);

        match runtime {
            CodexRuntime::Starting {
                generation: current,
                child: Some(child),
                ..
            } if current == generation => {
                guard.runtime = CodexRuntime::Running {
                    generation,
                    child,
                    status,
                };
                true
            }
            runtime => {
                guard.runtime = runtime;
                false
            }
        }
    }

    fn stop(&self) -> CodexStatus {
        self.stop_active();
        CodexStatus::stopped()
    }

    fn stop_active(&self) {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        let runtime = mem::replace(&mut guard.runtime, CodexRuntime::Stopped);
        kill_runtime(runtime);
    }

    fn stop_generation(&self, generation: u64) -> bool {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        if !runtime_matches(&guard.runtime, generation) {
            return false;
        }

        let runtime = mem::replace(&mut guard.runtime, CodexRuntime::Stopped);
        kill_runtime(runtime);
        true
    }

    fn status_for_generation(&self, generation: u64) -> Option<CodexStatus> {
        let guard = self.state.lock().expect("supervisor lock poisoned");
        match &guard.runtime {
            CodexRuntime::Starting {
                generation: current,
                status,
                ..
            }
            | CodexRuntime::Running {
                generation: current,
                status,
                ..
            } if *current == generation => Some(status.clone()),
            _ => None,
        }
    }

    fn set_status_for_generation(&self, generation: u64, status: CodexStatus) -> bool {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        match &mut guard.runtime {
            CodexRuntime::Starting {
                generation: current,
                status: current_status,
                ..
            }
            | CodexRuntime::Running {
                generation: current,
                status: current_status,
                ..
            } if *current == generation => {
                *current_status = status;
                true
            }
            _ => false,
        }
    }

    fn finish_generation(&self, generation: u64) -> bool {
        let mut guard = self.state.lock().expect("supervisor lock poisoned");
        if runtime_matches(&guard.runtime, generation) {
            guard.runtime = CodexRuntime::Stopped;
            true
        } else {
            false
        }
    }
}

#[tauri::command]
async fn start_codex(
    app: tauri::AppHandle,
    supervisor: State<'_, CodexSupervisor>,
) -> Result<CodexStatus, String> {
    let generation = supervisor
        .reserve_starting()
        .map_err(|err| err.to_string())?;

    let command = app
        .shell()
        .sidecar("codex")
        .map_err(|err| SupervisorError::Shell(err.to_string()).to_string())?
        .args(["app-server", "--listen", "ws://127.0.0.1:0"]);

    let (mut rx, child) = command.spawn().map_err(|err| {
        supervisor.stop_generation(generation);
        SupervisorError::Shell(err.to_string()).to_string()
    })?;

    if let Err(child) = supervisor.attach_child(generation, child) {
        let _ = child.kill();
        return Err(SupervisorError::StartupCancelled.to_string());
    }

    let mut status = supervisor
        .status_for_generation(generation)
        .ok_or_else(|| SupervisorError::StartupCancelled.to_string())?;
    let mut output_parser = CommandOutputParser::default();
    let deadline = Instant::now() + STARTUP_TIMEOUT;

    while Instant::now() < deadline {
        match tokio::time::timeout(Duration::from_millis(250), rx.recv()).await {
            Ok(Some(event)) => {
                let terminated = output_parser.apply_event(&mut status, event);
                supervisor.set_status_for_generation(generation, status.clone());
                if terminated {
                    supervisor.finish_generation(generation);
                    return Err(SupervisorError::StartupExited.to_string());
                }
            }
            Ok(None) => {
                status.message = Some("Codex app-server exited during startup.".to_string());
                supervisor.stop_generation(generation);
                return Err(SupervisorError::StartupExited.to_string());
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
        supervisor.stop_generation(generation);
        return Err(SupervisorError::StartupTimeout(STARTUP_TIMEOUT).to_string());
    }

    if !supervisor.promote_running(generation, status.clone()) {
        return Err(SupervisorError::StartupCancelled.to_string());
    }

    let app_for_events = app.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = rx.recv().await {
            let supervisor_handle = app_for_events.state::<CodexSupervisor>();
            let Some(mut next) = supervisor_handle.status_for_generation(generation) else {
                break;
            };

            if output_parser.apply_event(&mut next, event) {
                supervisor_handle.finish_generation(generation);
                break;
            }

            supervisor_handle.set_status_for_generation(generation, next);
        }
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

#[derive(Default)]
struct CommandOutputParser {
    stdout: String,
    stderr: String,
}

impl CommandOutputParser {
    fn apply_event(&mut self, status: &mut CodexStatus, event: CommandEvent) -> bool {
        match event {
            CommandEvent::Stdout(bytes) => {
                parse_output_bytes(status, &mut self.stdout, &bytes);
                false
            }
            CommandEvent::Stderr(bytes) => {
                parse_output_bytes(status, &mut self.stderr, &bytes);
                false
            }
            CommandEvent::Terminated(payload) => {
                status.phase = CodexPhase::Stopped;
                status.message = Some(format!("Codex exited with status {:?}.", payload.code));
                true
            }
            _ => false,
        }
    }
}

fn parse_output_bytes(status: &mut CodexStatus, pending: &mut String, bytes: &[u8]) {
    pending.push_str(&String::from_utf8_lossy(bytes));

    while let Some(newline) = pending.find('\n') {
        let line: String = pending.drain(..=newline).collect();
        parse_codex_line(status, line.trim());
    }
}

fn parse_codex_line(status: &mut CodexStatus, line: &str) {
    if let Some(url) = line.strip_prefix("listening on: ") {
        if let Some(url) = loopback_endpoint(status, url.trim(), &["ws"]) {
            status.ws_url = Some(url);
        }
    } else if let Some(url) = line.strip_prefix("readyz: ") {
        if let Some(url) = loopback_endpoint(status, url.trim(), &["http"]) {
            status.readyz_url = Some(url);
        }
    } else if let Some(url) = line.strip_prefix("healthz: ") {
        if let Some(url) = loopback_endpoint(status, url.trim(), &["http"]) {
            status.healthz_url = Some(url);
        }
    } else if !line.is_empty() {
        set_status_message(status, line);
    }
}

fn loopback_endpoint(status: &mut CodexStatus, raw_url: &str, schemes: &[&str]) -> Option<String> {
    if is_loopback_endpoint(raw_url, schemes) {
        Some(raw_url.to_string())
    } else {
        set_status_message(status, "Ignored non-loopback Codex app-server endpoint.");
        None
    }
}

fn is_loopback_endpoint(raw_url: &str, schemes: &[&str]) -> bool {
    let Ok(url) = Url::parse(raw_url) else {
        return false;
    };

    if !schemes.contains(&url.scheme()) || url.port().is_none() {
        return false;
    }

    matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "::1"))
}

fn set_status_message(status: &mut CodexStatus, message: &str) {
    status.message = Some(message.chars().take(MAX_STATUS_MESSAGE_CHARS).collect());
}

fn runtime_matches(runtime: &CodexRuntime, generation: u64) -> bool {
    match runtime {
        CodexRuntime::Starting {
            generation: current,
            ..
        }
        | CodexRuntime::Running {
            generation: current,
            ..
        } => *current == generation,
        CodexRuntime::Stopped => false,
    }
}

fn kill_runtime(runtime: CodexRuntime) {
    match runtime {
        CodexRuntime::Starting {
            child: Some(child), ..
        }
        | CodexRuntime::Running { child, .. } => {
            let _ = child.kill();
        }
        _ => {}
    }
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_websocket::init())
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_codex_app_server_endpoints() {
        let mut status = CodexStatus::stopped();

        parse_codex_line(&mut status, "listening on: ws://127.0.0.1:65036");
        parse_codex_line(&mut status, "readyz: http://127.0.0.1:65036/readyz");
        parse_codex_line(&mut status, "healthz: http://127.0.0.1:65036/healthz");

        assert_eq!(status.ws_url.as_deref(), Some("ws://127.0.0.1:65036"));
        assert_eq!(
            status.readyz_url.as_deref(),
            Some("http://127.0.0.1:65036/readyz")
        );
        assert_eq!(
            status.healthz_url.as_deref(),
            Some("http://127.0.0.1:65036/healthz")
        );
    }

    #[test]
    fn parses_split_codex_app_server_endpoint_lines() {
        let mut status = CodexStatus::stopped();
        let mut parser = CommandOutputParser::default();

        for chunk in [
            "listening on: ws://127.0.",
            "0.1:65036\nreadyz: http://127.",
            "0.0.1:65036/readyz\nhealthz: http://",
            "127.0.0.1:65036/healthz\n",
        ] {
            parser.apply_event(&mut status, CommandEvent::Stdout(chunk.as_bytes().to_vec()));
        }

        assert_eq!(status.ws_url.as_deref(), Some("ws://127.0.0.1:65036"));
        assert_eq!(
            status.readyz_url.as_deref(),
            Some("http://127.0.0.1:65036/readyz")
        );
        assert_eq!(
            status.healthz_url.as_deref(),
            Some("http://127.0.0.1:65036/healthz")
        );
    }

    #[test]
    fn rejects_non_loopback_endpoints() {
        let mut status = CodexStatus::stopped();

        parse_codex_line(&mut status, "listening on: ws://example.com:65036");
        parse_codex_line(&mut status, "readyz: http://192.168.1.2:65036/readyz");

        assert_eq!(status.ws_url, None);
        assert_eq!(status.readyz_url, None);
        assert_eq!(
            status.message.as_deref(),
            Some("Ignored non-loopback Codex app-server endpoint.")
        );
    }

    #[test]
    fn truncates_status_messages() {
        let mut status = CodexStatus::stopped();
        let message = "x".repeat(MAX_STATUS_MESSAGE_CHARS + 10);

        parse_codex_line(&mut status, &message);

        assert_eq!(
            status.message.unwrap().chars().count(),
            MAX_STATUS_MESSAGE_CHARS
        );
    }

    #[test]
    fn reserve_starting_blocks_concurrent_starts() {
        let supervisor = CodexSupervisor::default();

        let generation = supervisor.reserve_starting().unwrap();
        assert_eq!(generation, 1);
        assert!(matches!(
            supervisor.reserve_starting(),
            Err(SupervisorError::AlreadyRunning)
        ));
        assert_eq!(supervisor.status().phase, CodexPhase::Starting);
    }

    #[test]
    fn stale_generation_cannot_update_new_runtime() {
        let supervisor = CodexSupervisor::default();
        let first = supervisor.reserve_starting().unwrap();
        assert!(supervisor.stop_generation(first));
        let second = supervisor.reserve_starting().unwrap();

        let stale = CodexStatus {
            phase: CodexPhase::Stopped,
            ws_url: Some("ws://127.0.0.1:1".to_string()),
            readyz_url: None,
            healthz_url: None,
            message: Some("stale".to_string()),
        };

        assert!(!supervisor.set_status_for_generation(first, stale));
        assert_eq!(supervisor.status().phase, CodexPhase::Starting);
        assert_eq!(
            supervisor.status_for_generation(second).unwrap().ws_url,
            None
        );
    }
}
