//! Offline renderer: takes a song-plan JSON (the exact contract the app feeds
//! the engine) and renders it through the SAME synth + mastering to an MP3.
//! Used to A/B our engine against original tracker modules.
//!
//!   cargo run --release --example render -- in.json out.mp3 [target_seconds]

use std::env;
use std::fs;

use rust_lib_chiptune_ai::api::synth::synthesize_mp3;

fn main() {
    let args: Vec<String> = env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: render <in.json> <out.mp3> [target_seconds]");
        std::process::exit(1);
    }
    let json = fs::read_to_string(&args[1]).expect("read json");
    let target: f32 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(240.0);
    let mp3 = synthesize_mp3(json, target, 256).expect("synthesize");
    fs::write(&args[2], &mp3).expect("write mp3");
    println!("wrote {} ({} bytes), target {}s", &args[2], mp3.len(), target);
}
