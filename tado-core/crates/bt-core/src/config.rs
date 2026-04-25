use crate::error::BtError;
use crate::fs_guard::{atomic_write, safe_join};
use crate::model::{TokenRecord, VaultConfig};
use chrono::Utc;
use rand::RngCore;
use sha2::{Digest, Sha256};
use std::fs;
use std::path::Path;

fn random_hex(bytes: usize) -> String {
    let mut b = vec![0_u8; bytes];
    rand::thread_rng().fill_bytes(&mut b);
    hex::encode(b)
}

pub fn hash_token(raw: &str, salt: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(salt.as_bytes());
    hasher.update(raw.as_bytes());
    hex::encode(hasher.finalize())
}

pub fn config_path(vault_root: &Path) -> Result<std::path::PathBuf, BtError> {
    safe_join(vault_root, Path::new(".bt/config.toml"))
}

pub fn load_config(vault_root: &Path) -> Result<VaultConfig, BtError> {
    let path = config_path(vault_root)?;
    if !path.exists() {
        let config = VaultConfig::default();
        save_config(vault_root, &config)?;
        return Ok(config);
    }
    let raw = fs::read_to_string(&path)?;
    let cfg: VaultConfig = toml::from_str(&raw).map_err(|e| BtError::Validation(e.to_string()))?;
    Ok(cfg)
}

pub fn save_config(vault_root: &Path, config: &VaultConfig) -> Result<(), BtError> {
    let path = config_path(vault_root)?;
    let serialized =
        toml::to_string_pretty(config).map_err(|e| BtError::Validation(e.to_string()))?;
    atomic_write(vault_root, &path, &serialized)
}

pub fn create_token(
    config: &mut VaultConfig,
    agent_name: &str,
    caps: Vec<String>,
) -> (String, TokenRecord) {
    let token_id = format!("agt_{}", random_hex(6));
    let raw_token = format!("bt_tok_{}", random_hex(24));
    let salt = random_hex(16);
    let hash = hash_token(&raw_token, &salt);
    let now = Utc::now();

    let record = TokenRecord {
        token_id,
        agent_name: agent_name.to_string(),
        token_hash: hash,
        token_salt: salt,
        caps,
        created_at: now,
        last_used_at: None,
        revoked: false,
    };

    config.tokens.push(record.clone());
    (raw_token, record)
}

pub fn rotate_token(
    config: &mut VaultConfig,
    token_id: &str,
) -> Result<(String, TokenRecord), BtError> {
    let idx = config
        .tokens
        .iter()
        .position(|t| t.token_id == token_id && !t.revoked)
        .ok_or_else(|| BtError::NotFound(format!("token {} not found", token_id)))?;

    let raw = format!("bt_tok_{}", random_hex(24));
    let salt = random_hex(16);
    let hash = hash_token(&raw, &salt);
    config.tokens[idx].token_hash = hash;
    config.tokens[idx].token_salt = salt;
    config.tokens[idx].last_used_at = None;

    Ok((raw, config.tokens[idx].clone()))
}

pub fn revoke_token(config: &mut VaultConfig, token_id: &str) -> Result<(), BtError> {
    let token = config
        .tokens
        .iter_mut()
        .find(|t| t.token_id == token_id)
        .ok_or_else(|| BtError::NotFound(format!("token {} not found", token_id)))?;
    token.revoked = true;
    Ok(())
}

pub fn authenticate_token(
    config: &mut VaultConfig,
    raw_token: &str,
) -> Result<TokenRecord, BtError> {
    for token in &mut config.tokens {
        if token.revoked {
            continue;
        }
        let hash = hash_token(raw_token, &token.token_salt);
        if hash == token.token_hash {
            token.last_used_at = Some(Utc::now());
            return Ok(token.clone());
        }
    }
    Err(BtError::Auth("invalid token".to_string()))
}
