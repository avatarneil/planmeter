//! GTK-free core of the PlanMeter Linux desktop app: wire models, the
//! `planmeterd` control-socket client, range and granularity rules, chart
//! layout, formatting, spend alerts, and a mock daemon for development.
//!
//! The GTK 4 / libadwaita UI lives in the `planmeter` binary (`src/ui`).

pub mod chart;
pub mod client;
pub mod format;
pub mod http;
pub mod mock;
pub mod models;
pub mod notify;
pub mod range;
