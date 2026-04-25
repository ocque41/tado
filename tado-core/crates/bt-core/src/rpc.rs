use crate::error::BtError;
use crate::service::CoreService;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::time::{Duration as StdDuration, Instant};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::time::{interval, Duration, MissedTickBehavior};

// Stderr warning threshold for slow RPC handlers. Any handler taking
// longer than this emits a structured warning to the daemon's stderr so
// operators and future eval runs can spot regressions immediately.
// See operations/quality/2026-04-08-rpc-latency-hardening.md.
const SLOW_RPC_WARN_THRESHOLD: StdDuration = StdDuration::from_millis(2000);

#[derive(Debug, Serialize, Deserialize)]
pub struct JsonRpcRequest {
    pub jsonrpc: String,
    pub id: Value,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct JsonRpcErrorObj {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct JsonRpcResponse {
    pub jsonrpc: String,
    pub id: Value,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<JsonRpcErrorObj>,
}

impl JsonRpcResponse {
    pub fn success(id: Value, result: Value) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: Some(result),
            error: None,
        }
    }

    pub fn error(id: Value, err: &BtError) -> Self {
        Self {
            jsonrpc: "2.0".to_string(),
            id,
            result: None,
            error: Some(JsonRpcErrorObj {
                code: err.code().to_string(),
                message: err.to_string(),
                data: None,
            }),
        }
    }
}

pub struct RpcClient {
    pub socket_path: PathBuf,
}

impl RpcClient {
    pub fn new(socket_path: PathBuf) -> Self {
        Self { socket_path }
    }

    pub async fn call(&self, method: &str, params: Value) -> Result<Value, BtError> {
        let stream = tokio::net::UnixStream::connect(&self.socket_path)
            .await
            .map_err(|e| BtError::Rpc(format!("connect failed: {}", e)))?;

        let request = JsonRpcRequest {
            jsonrpc: "2.0".to_string(),
            id: json!(1),
            method: method.to_string(),
            params,
        };

        let payload =
            serde_json::to_string(&request).map_err(|e| BtError::Rpc(e.to_string()))? + "\n";
        let (reader, mut writer) = stream.into_split();
        writer
            .write_all(payload.as_bytes())
            .await
            .map_err(|e| BtError::Rpc(format!("write failed: {}", e)))?;
        writer
            .flush()
            .await
            .map_err(|e| BtError::Rpc(format!("flush failed: {}", e)))?;

        let mut line = String::new();
        let mut buf = BufReader::new(reader);
        let read = buf
            .read_line(&mut line)
            .await
            .map_err(|e| BtError::Rpc(format!("read failed: {}", e)))?;

        if read == 0 {
            return Err(BtError::Rpc(
                "connection closed with no response".to_string(),
            ));
        }

        let response: JsonRpcResponse = serde_json::from_str(&line)
            .map_err(|e| BtError::Rpc(format!("invalid response: {}", e)))?;

        if let Some(err) = response.error {
            return Err(BtError::Rpc(format!("{}: {}", err.code, err.message)));
        }

        Ok(response.result.unwrap_or(Value::Null))
    }
}

pub async fn run_daemon(service: CoreService) -> Result<(), BtError> {
    let scheduler_service = service.clone();
    tokio::spawn(async move {
        let mut ticker = interval(Duration::from_secs(15));
        ticker.set_missed_tick_behavior(MissedTickBehavior::Skip);
        loop {
            ticker.tick().await;
            if let Err(err) = scheduler_service.scheduler_tick() {
                eprintln!("bt-core scheduler tick error: {}", err);
            }
        }
    });

    let socket_path = service.socket_path()?;
    if socket_path.exists() {
        std::fs::remove_file(&socket_path)?;
    }

    let listener = tokio::net::UnixListener::bind(&socket_path).map_err(|e| {
        BtError::Rpc(format!(
            "failed to bind socket {}: {}",
            socket_path.display(),
            e
        ))
    })?;

    loop {
        let (stream, _) = listener
            .accept()
            .await
            .map_err(|e| BtError::Rpc(format!("accept failed: {}", e)))?;
        let svc = service.clone();
        tokio::spawn(async move {
            if let Err(e) = handle_unix_conn(stream, svc).await {
                eprintln!("bt-core daemon connection error: {}", e);
            }
        });
    }
}

async fn handle_unix_conn(
    stream: tokio::net::UnixStream,
    service: CoreService,
) -> Result<(), BtError> {
    let (reader, mut writer) = stream.into_split();
    let mut reader = BufReader::new(reader);
    let mut line = String::new();

    loop {
        line.clear();
        let read = reader
            .read_line(&mut line)
            .await
            .map_err(|e| BtError::Rpc(format!("read line failed: {}", e)))?;

        if read == 0 {
            break;
        }

        let req: Result<JsonRpcRequest, _> = serde_json::from_str(&line);
        let response = match req {
            Ok(req) => {
                if req.jsonrpc != "2.0" {
                    JsonRpcResponse {
                        jsonrpc: "2.0".to_string(),
                        id: req.id,
                        result: None,
                        error: Some(JsonRpcErrorObj {
                            code: "ERR_RPC_PROTOCOL".to_string(),
                            message: "jsonrpc must be 2.0".to_string(),
                            data: None,
                        }),
                    }
                } else {
                    dispatch_blocking(&service, req).await
                }
            }
            Err(err) => JsonRpcResponse {
                jsonrpc: "2.0".to_string(),
                id: Value::Null,
                result: None,
                error: Some(JsonRpcErrorObj {
                    code: "ERR_RPC_PARSE".to_string(),
                    message: format!("failed to parse request: {}", err),
                    data: None,
                }),
            },
        };

        let payload =
            serde_json::to_string(&response).map_err(|e| BtError::Rpc(e.to_string()))? + "\n";
        writer
            .write_all(payload.as_bytes())
            .await
            .map_err(|e| BtError::Rpc(format!("write failed: {}", e)))?;
        writer
            .flush()
            .await
            .map_err(|e| BtError::Rpc(format!("flush failed: {}", e)))?;
    }

    Ok(())
}

/// Run a single synchronous `handle_rpc` call on the blocking pool so the
/// daemon's async runtime threads stay free to drive other socket tasks.
///
/// `handle_rpc` is a fully blocking function: it opens SQLite connections,
/// walks the filesystem, writes the audit log, and can take hundreds of
/// milliseconds (or more) on a busy vault. Calling it directly inside the
/// async per-connection task pinned the work to a tokio worker thread, and
/// concurrent slow handlers (e.g. plan-sync after a `user.md` save) could
/// starve the runtime so that *other* connections — including the VSCode
/// `crafting.craftship.session.launch` call from the doc-plan handoff
/// path — could not even be polled within their client-side timeout.
async fn dispatch_blocking(service: &CoreService, req: JsonRpcRequest) -> JsonRpcResponse {
    let svc = service.clone();
    let id = req.id;
    let method = req.method;
    let params = req.params;
    let method_for_log = method.clone();
    let started_at = Instant::now();
    let outcome =
        tokio::task::spawn_blocking(move || svc.handle_rpc(&method, params)).await;
    let elapsed = started_at.elapsed();
    if elapsed >= SLOW_RPC_WARN_THRESHOLD {
        // Intentional stderr write (no log crate in bt-core yet). The
        // line format is stable and parseable so eval/observability
        // tooling can grep for it. If this fires, the very next thing
        // to check is the O(N) / O(N²) audit-hot-path section of
        // `operations/quality/2026-04-08-rpc-latency-hardening.md`.
        let outcome_tag = match &outcome {
            Ok(Ok(_)) => "ok",
            Ok(Err(_)) => "err",
            Err(_) => "panic",
        };
        eprintln!(
            "[bt-core slow-rpc] method={} elapsed_ms={} outcome={} threshold_ms={}",
            method_for_log,
            elapsed.as_millis(),
            outcome_tag,
            SLOW_RPC_WARN_THRESHOLD.as_millis()
        );
    }
    match outcome {
        Ok(Ok(value)) => JsonRpcResponse::success(id, value),
        Ok(Err(err)) => JsonRpcResponse::error(id, &err),
        Err(join_err) => JsonRpcResponse::error(
            id,
            &BtError::Rpc(format!("handler task failed: {}", join_err)),
        ),
    }
}

// Windows named-pipe support removed — macOS only.
