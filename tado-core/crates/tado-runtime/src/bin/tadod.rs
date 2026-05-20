use anyhow::Result;
use clap::Parser;
use tado_runtime::daemon::{run_daemon, DaemonOptions};
use tado_runtime::profile::profile_from_env;
use tracing_subscriber::EnvFilter;

#[derive(Parser, Debug)]
#[command(name = "tadod")]
#[command(about = "Run the profile-isolated Tado CLI runtime daemon.")]
struct Cli {
    #[arg(long)]
    profile: Option<String>,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("tado_runtime=info,tadod=info"));
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_target(false)
        .compact()
        .init();

    let cli = Cli::parse();
    let profile = profile_from_env(cli.profile);
    run_daemon(DaemonOptions { profile }).await
}
