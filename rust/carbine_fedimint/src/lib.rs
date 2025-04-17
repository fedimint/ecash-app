use flutter_rust_bridge::frb;
use multimint::Multimint;

mod multimint;
mod db;

#[frb]
pub async fn init_multimint() -> anyhow::Result<Multimint> {
    Multimint::new().await
}