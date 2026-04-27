//! Thin wrapper around `portable-pty` that spawns a child under a PTY and
//! exposes `Read`/`Write` halves via trait objects + a kill handle.
//!
//! The reader/writer pair are moved into the `Session` type, which owns the
//! background read loop. Keeping this module tiny makes it easy to swap the
//! PTY backend later (e.g. to a direct `openpty` / `posix_spawn` path) if
//! `portable-pty`'s threading model shows up in a profile.

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};

pub struct PtyHandles {
    pub reader: Box<dyn Read + Send>,
    pub writer: Box<dyn Write + Send>,
    pub child: Box<dyn portable_pty::Child + Send + Sync>,
    pub master: Box<dyn portable_pty::MasterPty + Send>,
}

pub fn spawn(
    cmd: &str,
    args: &[String],
    cwd: Option<&str>,
    env: &[(String, String)],
    cols: u16,
    rows: u16,
) -> std::io::Result<PtyHandles> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    let mut builder = CommandBuilder::new(cmd);
    for a in args {
        builder.arg(a);
    }
    if let Some(cwd) = cwd {
        builder.cwd(cwd);
    }
    for (k, v) in env {
        builder.env(k, v);
    }

    let child = pair
        .slave
        .spawn_command(builder)
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    let reader = pair
        .master
        .try_clone_reader()
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let writer = pair
        .master
        .take_writer()
        .map_err(|e| std::io::Error::other(e.to_string()))?;

    Ok(PtyHandles {
        reader,
        writer,
        child,
        master: pair.master,
    })
}
