#[cfg(debug_assertions)]
use std::io::{BufRead, BufReader};
#[cfg(debug_assertions)]
use std::path::PathBuf;
#[cfg(debug_assertions)]
use std::process::Child;
#[cfg(debug_assertions)]
use std::process::{Command, Stdio};
#[cfg(debug_assertions)]
use std::sync::Arc;
use std::sync::Mutex;

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder, WindowEvent};
#[cfg(not(debug_assertions))]
use tauri_plugin_shell::process::CommandChild;
#[cfg(not(debug_assertions))]
use tauri_plugin_shell::process::CommandEvent;
#[cfg(not(debug_assertions))]
use tauri_plugin_shell::ShellExt;
use url::Url;

const PANEL_READY_PREFIX: &str = "HYPERDR_READY ";
#[cfg(not(debug_assertions))]
const PANEL_SIDECAR: &str = "hyperdr-panel";

enum PanelChild {
    #[cfg(debug_assertions)]
    Dev(Arc<Mutex<Child>>),
    #[cfg(not(debug_assertions))]
    Bundled(CommandChild),
}

#[derive(Default)]
struct PanelProcess(Mutex<Option<PanelChild>>);

impl PanelProcess {
    fn replace(&self, child: PanelChild) {
        *self.0.lock().expect("panel process mutex poisoned") = Some(child);
    }

    fn stop(&self) {
        let child = self
            .0
            .lock()
            .expect("panel process mutex poisoned")
            .take();
        let Some(child) = child else { return };
        match child {
            #[cfg(debug_assertions)]
            PanelChild::Dev(child) => {
                if let Ok(mut process) = child.lock() {
                    let _ = process.kill();
                }
            }
            #[cfg(not(debug_assertions))]
            PanelChild::Bundled(child) => {
                let _ = child.kill();
            }
        }
    }
}

fn ready_url(line: &str) -> Option<String> {
    line.trim()
        .strip_prefix(PANEL_READY_PREFIX)
        .filter(|url| !url.is_empty())
        .map(str::to_owned)
}

fn dispatch_ready(app: &AppHandle, url: String) {
    let run_handle = app.clone();
    let window_handle = run_handle.clone();
    let _ = run_handle.run_on_main_thread(move || {
        let Some(window) = window_handle.get_webview_window("main") else {
            eprintln!("HyperDR panel window was closed before startup completed");
            return;
        };
        let Ok(parsed) = Url::parse(&url) else {
            eprintln!("HyperDR panel announced an invalid URL: {url}");
            return;
        };
        if let Err(error) = window.navigate(parsed) {
            eprintln!("Unable to navigate to the HyperDR panel: {error}");
        }
    });
}

#[cfg(debug_assertions)]
fn handle_dev_stdout(app: &AppHandle, line: &str) {
    if let Some(url) = ready_url(line) {
        dispatch_ready(app, url);
    }
    println!("[panel] {line}");
}

fn create_splash_window(app: &AppHandle) -> Result<(), String> {
    if app.get_webview_window("main").is_some() {
        return Ok(());
    }
    let handle = app.clone();
    let window = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("splash.html".into()))
        .title("HyperDR")
        .inner_size(1440.0, 900.0)
        .min_inner_size(960.0, 640.0)
        .resizable(true)
        .build()
        .map_err(|error| error.to_string())
        ?;
    window.on_window_event(move |event| {
        if matches!(event, WindowEvent::CloseRequested { .. }) {
            handle.state::<PanelProcess>().stop();
        }
    });
    Ok(())
}

#[cfg(debug_assertions)]
fn spawn_dev_panel(app: &AppHandle) -> Result<(), String> {
    let repository = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../..")
        .canonicalize()
        .map_err(|error| format!("unable to locate HyperDR repository: {error}"))?;
    let launcher = repository.join("apps/panel/hyperdr_gui.py");
    let python = std::env::var("HYPERDR_PANEL_PYTHON").unwrap_or_else(|_| "python".into());

    let mut command = Command::new(python);
    command
        .current_dir(&repository)
        .arg(&launcher)
        .arg("--desktop")
        .env("HYPERDR_HOST", "127.0.0.1")
        .env("HYPERDR_NO_BROWSER", "1")
        .env("PYTHONUNBUFFERED", "1")
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }

    let mut child = command
        .spawn()
        .map_err(|error| format!("unable to start the Python panel: {error}"))?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| "Python panel stdout was not captured".to_string())?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| "Python panel stderr was not captured".to_string())?;
    let child = Arc::new(Mutex::new(child));
    app.state::<PanelProcess>().replace(PanelChild::Dev(child));

    let stdout_app = app.clone();
    std::thread::spawn(move || {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            handle_dev_stdout(&stdout_app, &line);
        }
    });
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            eprintln!("[panel:error] {line}");
        }
    });
    Ok(())
}

#[cfg(not(debug_assertions))]
fn spawn_bundled_panel(app: &AppHandle) -> Result<(), String> {
    let sidecar = app
        .shell()
        .sidecar(PANEL_SIDECAR)
        .map_err(|error| format!("unable to resolve the Python sidecar: {error}"))?
        .args(["--desktop"]);
    let (mut events, child) = sidecar
        .spawn()
        .map_err(|error| format!("unable to start the Python sidecar: {error}"))?;
    app.state::<PanelProcess>().replace(PanelChild::Bundled(child));

    let sidecar_app = app.clone();
    tauri::async_runtime::spawn(async move {
        while let Some(event) = events.recv().await {
            match event {
                CommandEvent::Stdout(bytes) => {
                    let line = String::from_utf8_lossy(&bytes);
                    if let Some(url) = ready_url(&line) {
                        dispatch_ready(&sidecar_app, url);
                    }
                    println!("[panel] {}", line.trim_end());
                }
                CommandEvent::Stderr(bytes) => {
                    eprintln!("[panel:error] {}", String::from_utf8_lossy(&bytes).trim_end());
                }
                CommandEvent::Error(error) => eprintln!("[panel:error] {error}"),
                CommandEvent::Terminated(payload) => {
                    eprintln!("HyperDR panel stopped: {payload:?}");
                }
                _ => {}
            }
        }
    });
    Ok(())
}

fn spawn_panel(app: &AppHandle) -> Result<(), String> {
    #[cfg(debug_assertions)]
    {
        spawn_dev_panel(app)
    }
    #[cfg(not(debug_assertions))]
    {
        spawn_bundled_panel(app)
    }
}

pub fn run() {
    tauri::Builder::default()
        .manage(PanelProcess::default())
        .plugin(tauri_plugin_shell::init())
        .setup(|app| {
            create_splash_window(app.handle())?;
            spawn_panel(app.handle())?;
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running HyperDR desktop application");
}
