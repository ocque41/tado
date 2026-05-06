//! Synchronous request-response client over the Tado app's
//! Unix domain socket. Each call: connect, send framed request,
//! read framed response, close. No retries (rule 1) — if the
//! socket isn't reachable, return `AppNotRunning` with a clear
//! message and let the caller surface it.
//!
//! Wire format mirrors `Sources/Tado/Services/ControlSocketServer.swift`:
//!   - 4-byte big-endian unsigned length
//!   - exactly that many bytes of UTF-8 JSON
//!   - request envelope: `{request_id, kind, payload}`
//!   - response envelope: `{request_id, ok, data, error}`

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use uuid::Uuid;

#[derive(Debug)]
pub enum ControlClientError {
    AppNotRunning(String),
    Io(std::io::Error),
    Decode(String),
    Server { code: String, message: String, data: Option<Value> },
}

impl std::fmt::Display for ControlClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::AppNotRunning(s) => write!(f, "Tado is not running: {s}"),
            Self::Io(e) => write!(f, "i/o error: {e}"),
            Self::Decode(s) => write!(f, "decode error: {s}"),
            Self::Server { code, message, .. } => write!(f, "server error [{code}]: {message}"),
        }
    }
}

impl std::error::Error for ControlClientError {}

#[derive(Serialize)]
pub struct Request {
    pub request_id: String,
    pub kind: String,
    pub payload: Value,
}

#[derive(Deserialize, Serialize, Debug)]
pub struct Response {
    pub request_id: String,
    pub ok: bool,
    #[serde(default)]
    pub data: Option<Value>,
    #[serde(default)]
    pub error: Option<String>,
}

/// Send a single request and return the response. The pid file
/// at `/tmp/tado-ipc/active-pid` tells us which per-pid socket
/// to connect to. The socket lives at
/// `/tmp/tado-ipc-<pid>/control.sock`.
pub fn call(kind: &str, payload: Value) -> Result<Response, ControlClientError> {
    let pid = active_pid()
        .map_err(|e| ControlClientError::AppNotRunning(format!("could not read /tmp/tado-ipc/active-pid: {e}")))?;
    let socket_path = PathBuf::from(format!("/tmp/tado-ipc-{pid}/control.sock"));
    if !socket_path.exists() {
        return Err(ControlClientError::AppNotRunning(format!(
            "socket missing at {}",
            socket_path.display()
        )));
    }

    let mut stream = UnixStream::connect(&socket_path).map_err(|e| {
        ControlClientError::AppNotRunning(format!("connect failed: {e}"))
    })?;
    // Read/write timeouts cap pathological hangs — these are NOT
    // retry timeouts (rule 1); they only catch a wedged socket
    // where the server died mid-write. 10 s is generous for a
    // single round-trip; coordinator polling waits live in the
    // agent's prompt.
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(10)));

    let request = Request {
        request_id: Uuid::new_v4().to_string(),
        kind: kind.to_string(),
        payload,
    };
    let body = serde_json::to_vec(&request).map_err(|e| {
        ControlClientError::Decode(format!("encode request: {e}"))
    })?;
    write_frame(&mut stream, &body).map_err(ControlClientError::Io)?;

    let resp_bytes = read_frame(&mut stream).map_err(ControlClientError::Io)?;
    let response: Response = serde_json::from_slice(&resp_bytes).map_err(|e| {
        ControlClientError::Decode(format!("decode response: {e}"))
    })?;

    if !response.ok {
        let code = response.error.clone().unwrap_or_else(|| "unknown".into());
        let message = response
            .data
            .as_ref()
            .and_then(|d| d.get("message"))
            .and_then(|m| m.as_str())
            .unwrap_or("(no message)")
            .to_string();
        return Err(ControlClientError::Server {
            code,
            message,
            data: response.data,
        });
    }

    Ok(response)
}

fn active_pid() -> Result<u32, std::io::Error> {
    let raw = std::fs::read_to_string("/tmp/tado-ipc/active-pid")?;
    raw.trim()
        .parse::<u32>()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

fn write_frame<W: Write>(w: &mut W, body: &[u8]) -> std::io::Result<()> {
    let len = body.len() as u32;
    let mut header = [0u8; 4];
    header[0] = ((len >> 24) & 0xFF) as u8;
    header[1] = ((len >> 16) & 0xFF) as u8;
    header[2] = ((len >> 8) & 0xFF) as u8;
    header[3] = (len & 0xFF) as u8;
    w.write_all(&header)?;
    w.write_all(body)?;
    Ok(())
}

fn read_frame<R: Read>(r: &mut R) -> std::io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    r.read_exact(&mut header)?;
    let len = ((header[0] as u32) << 24)
        | ((header[1] as u32) << 16)
        | ((header[2] as u32) << 8)
        | (header[3] as u32);
    if len == 0 || len > 4 * 1024 * 1024 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame length out of bounds: {len}"),
        ));
    }
    let mut body = vec![0u8; len as usize];
    r.read_exact(&mut body)?;
    Ok(body)
}

/// Convenience: return a JSON object payload with snake_case keys.
/// Most CLI subcommands assemble payloads inline.
pub fn payload<I, K, V>(items: I) -> Value
where
    I: IntoIterator<Item = (K, V)>,
    K: Into<String>,
    V: Into<Value>,
{
    let mut map = serde_json::Map::new();
    for (k, v) in items {
        map.insert(k.into(), v.into());
    }
    Value::Object(map)
}

