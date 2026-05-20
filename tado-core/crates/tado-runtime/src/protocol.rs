use std::io::{Read, Write};

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: u32 = 16 * 1024 * 1024;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeRequest {
    pub request_id: String,
    #[serde(default = "default_protocol_version")]
    pub version: u32,
    pub kind: String,
    #[serde(default)]
    pub payload: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeResponse {
    pub request_id: String,
    #[serde(default = "default_protocol_version")]
    pub version: u32,
    pub ok: bool,
    #[serde(default)]
    pub data: Option<Value>,
    #[serde(default)]
    pub error: Option<RuntimeError>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeError {
    pub code: String,
    pub message: String,
}

impl RuntimeRequest {
    pub fn new(kind: impl Into<String>, payload: Value) -> Self {
        Self {
            request_id: Uuid::new_v4().to_string(),
            version: PROTOCOL_VERSION,
            kind: kind.into(),
            payload,
        }
    }
}

impl RuntimeResponse {
    pub fn ok(request_id: impl Into<String>, data: Value) -> Self {
        Self {
            request_id: request_id.into(),
            version: PROTOCOL_VERSION,
            ok: true,
            data: Some(data),
            error: None,
        }
    }

    pub fn err(
        request_id: impl Into<String>,
        code: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            request_id: request_id.into(),
            version: PROTOCOL_VERSION,
            ok: false,
            data: None,
            error: Some(RuntimeError {
                code: code.into(),
                message: message.into(),
            }),
        }
    }
}

fn default_protocol_version() -> u32 {
    PROTOCOL_VERSION
}

pub fn write_json_frame<W, T>(writer: &mut W, value: &T) -> std::io::Result<()>
where
    W: Write,
    T: Serialize,
{
    let body = serde_json::to_vec(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    write_frame(writer, &body)
}

pub fn read_json_frame<R, T>(reader: &mut R) -> std::io::Result<T>
where
    R: Read,
    T: for<'de> Deserialize<'de>,
{
    let body = read_frame(reader)?;
    serde_json::from_slice(&body)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

pub fn write_frame<W: Write>(writer: &mut W, body: &[u8]) -> std::io::Result<()> {
    if body.len() > MAX_FRAME_BYTES as usize {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("frame too large: {}", body.len()),
        ));
    }
    let len = body.len() as u32;
    writer.write_all(&len.to_be_bytes())?;
    writer.write_all(body)?;
    Ok(())
}

pub fn read_frame<R: Read>(reader: &mut R) -> std::io::Result<Vec<u8>> {
    let mut header = [0u8; 4];
    reader.read_exact(&mut header)?;
    let len = u32::from_be_bytes(header);
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame length out of bounds: {len}"),
        ));
    }
    let mut body = vec![0u8; len as usize];
    reader.read_exact(&mut body)?;
    Ok(body)
}

pub async fn write_json_frame_async<W, T>(writer: &mut W, value: &T) -> std::io::Result<()>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let body = serde_json::to_vec(value)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    if body.len() > MAX_FRAME_BYTES as usize {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("frame too large: {}", body.len()),
        ));
    }
    writer.write_all(&(body.len() as u32).to_be_bytes()).await?;
    writer.write_all(&body).await?;
    writer.flush().await?;
    Ok(())
}

pub async fn read_json_frame_async<R, T>(reader: &mut R) -> std::io::Result<T>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let mut header = [0u8; 4];
    reader.read_exact(&mut header).await?;
    let len = u32::from_be_bytes(header);
    if len == 0 || len > MAX_FRAME_BYTES {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame length out of bounds: {len}"),
        ));
    }
    let mut body = vec![0u8; len as usize];
    reader.read_exact(&mut body).await?;
    serde_json::from_slice(&body)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}
