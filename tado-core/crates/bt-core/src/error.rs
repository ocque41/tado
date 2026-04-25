use thiserror::Error;

#[derive(Debug, Error)]
pub enum BtError {
    #[error("invalid vault path: {0}")]
    InvalidVaultPath(String),
    #[error("path escape blocked: {0}")]
    PathEscape(String),
    #[error("forbidden: {0}")]
    Forbidden(String),
    #[error("not found: {0}")]
    NotFound(String),
    #[error("conflict: {0}")]
    Conflict(String),
    #[error("validation failed: {0}")]
    Validation(String),
    #[error("io error: {0}")]
    Io(String),
    #[error("database error: {0}")]
    Db(String),
    #[error("auth error: {0}")]
    Auth(String),
    #[error("rpc error: {0}")]
    Rpc(String),
}

impl BtError {
    pub fn code(&self) -> &'static str {
        match self {
            BtError::InvalidVaultPath(_) => "ERR_INVALID_VAULT_PATH",
            BtError::PathEscape(_) => "ERR_PATH_SANDBOX",
            BtError::Forbidden(_) => "ERR_FORBIDDEN",
            BtError::NotFound(_) => "ERR_NOT_FOUND",
            BtError::Conflict(_) => "ERR_CONFLICT",
            BtError::Validation(_) => "ERR_VALIDATION",
            BtError::Io(_) => "ERR_IO",
            BtError::Db(_) => "ERR_DB",
            BtError::Auth(_) => "ERR_AUTH",
            BtError::Rpc(_) => "ERR_RPC",
        }
    }
}

impl From<std::io::Error> for BtError {
    fn from(value: std::io::Error) -> Self {
        BtError::Io(value.to_string())
    }
}

impl From<rusqlite::Error> for BtError {
    fn from(value: rusqlite::Error) -> Self {
        BtError::Db(value.to_string())
    }
}

impl From<serde_json::Error> for BtError {
    fn from(value: serde_json::Error) -> Self {
        BtError::Validation(value.to_string())
    }
}
