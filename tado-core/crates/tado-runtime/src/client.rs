use std::io;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde_json::Value;
use uuid::Uuid;

use crate::profile::ProfilePaths;
use crate::protocol::{read_json_frame, write_json_frame, RuntimeRequest, RuntimeResponse};

#[derive(Debug)]
pub enum RuntimeClientError {
    NotRunning(String),
    Io(io::Error),
    Decode(String),
    Server { code: String, message: String },
}

impl std::fmt::Display for RuntimeClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotRunning(s) => write!(f, "Tado runtime is not running: {s}"),
            Self::Io(e) => write!(f, "i/o error: {e}"),
            Self::Decode(s) => write!(f, "decode error: {s}"),
            Self::Server { code, message } => write!(f, "server error [{code}]: {message}"),
        }
    }
}

impl std::error::Error for RuntimeClientError {}

impl From<io::Error> for RuntimeClientError {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Debug, Clone)]
pub struct RuntimeClient {
    pub profile: String,
    pub paths: ProfilePaths,
}

impl RuntimeClient {
    pub fn new(profile: &str) -> Result<Self, RuntimeClientError> {
        let paths = ProfilePaths::resolve(profile)
            .map_err(|e| RuntimeClientError::Decode(e.to_string()))?;
        Ok(Self {
            profile: paths.profile.clone(),
            paths,
        })
    }

    pub fn call(&self, kind: &str, payload: Value) -> Result<RuntimeResponse, RuntimeClientError> {
        let mut stream = UnixStream::connect(&self.paths.socket_path).map_err(|e| {
            RuntimeClientError::NotRunning(format!(
                "connect {} failed: {e}",
                self.paths.socket_path.display()
            ))
        })?;
        let _ = stream.set_read_timeout(Some(Duration::from_secs(15)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(15)));
        let request = RuntimeRequest {
            request_id: Uuid::new_v4().to_string(),
            version: crate::protocol::PROTOCOL_VERSION,
            kind: kind.to_string(),
            payload,
        };
        write_json_frame(&mut stream, &request)?;
        let response: RuntimeResponse = read_json_frame(&mut stream)?;
        if !response.ok {
            if let Some(err) = response.error.clone() {
                return Err(RuntimeClientError::Server {
                    code: err.code,
                    message: err.message,
                });
            }
        }
        Ok(response)
    }
}

pub fn ensure_daemon(profile: &str) -> Result<RuntimeClient, RuntimeClientError> {
    let client = RuntimeClient::new(profile)?;
    if client.call("runtime.status", serde_json::json!({})).is_ok() {
        return Ok(client);
    }
    start_daemon(&client)?;
    let start = Instant::now();
    loop {
        if client.call("runtime.status", serde_json::json!({})).is_ok() {
            return Ok(client);
        }
        if start.elapsed() > Duration::from_secs(5) {
            return Err(RuntimeClientError::NotRunning(format!(
                "daemon did not become ready at {}",
                client.paths.socket_path.display()
            )));
        }
        std::thread::sleep(Duration::from_millis(80));
    }
}

pub fn start_daemon(client: &RuntimeClient) -> Result<(), RuntimeClientError> {
    client.paths.create_dirs().map_err(RuntimeClientError::Io)?;
    let tadod = find_tadod().ok_or_else(|| {
        RuntimeClientError::NotRunning("could not find tadod next to the CLI or on PATH".into())
    })?;
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(client.paths.log_path())
        .map_err(RuntimeClientError::Io)?;
    let log_err = log.try_clone().map_err(RuntimeClientError::Io)?;
    let mut cmd = Command::new(tadod);
    cmd.arg("--profile")
        .arg(&client.profile)
        .env("TADO_PROFILE", &client.profile)
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err));
    if let Some(root) = std::env::var_os("TADO_RUNTIME_ROOT") {
        cmd.env("TADO_RUNTIME_ROOT", root);
    }
    if let Some(socket_dir) = std::env::var_os("TADO_RUNTIME_SOCKET_DIR") {
        cmd.env("TADO_RUNTIME_SOCKET_DIR", socket_dir);
    }
    if let Some(socket) = std::env::var_os("TADO_RUNTIME_SOCKET") {
        cmd.env("TADO_RUNTIME_SOCKET", socket);
    }
    unsafe {
        cmd.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    cmd.spawn().map_err(RuntimeClientError::Io)?;
    Ok(())
}

fn find_tadod() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok();
    if let Some(exe) = exe {
        if exe.file_name().and_then(|n| n.to_str()) == Some("tadod") {
            return Some(exe);
        }
        if let Some(dir) = exe.parent() {
            let sibling = dir.join("tadod");
            if sibling.exists() {
                return Some(sibling);
            }
        }
    }
    let path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&path) {
        let candidate = dir.join("tadod");
        if candidate.exists() {
            return Some(candidate);
        }
    }
    None
}
