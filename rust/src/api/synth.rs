//! flutter_rust_bridge API surface for the synthesis engine.
//!
//! Dart sends a song (the tracker-style JSON the AI composer produces) plus a
//! target duration in seconds. The engine expands the arrangement to fill that
//! duration, renders it, and returns raw 16-bit PCM, a WAV, or an MP3.

use crate::synth::{engine, song, stream};

/// 16-bit PCM audio result handed back to Dart.
pub struct PcmAudio {
    pub sample_rate: u32,
    pub channels: u16,
    /// Number of mono frames (samples per channel).
    pub frame_count: u32,
    /// Interleaved little-endian signed 16-bit PCM.
    pub bytes: Vec<u8>,
}

fn parse(song_json: &str) -> anyhow::Result<song::Song> {
    let song: song::Song =
        serde_json::from_str(song_json).map_err(|e| anyhow::anyhow!("invalid song JSON: {e}"))?;
    // Load the sampler bank if the song references one (best-effort; failure
    // just leaves the chip oscillators in place).
    if let Some(path) = song.sample_bank.as_deref() {
        let _ = crate::synth::sampler::load_path(path);
    }
    Ok(song)
}

/// Synthesize a song (JSON) into raw 16-bit PCM, expanded to `target_seconds`.
pub fn synthesize_pcm(song_json: String, target_seconds: f32) -> anyhow::Result<PcmAudio> {
    let song = parse(&song_json)?;
    let comp = song::expand(&song, target_seconds);
    let audio = engine::render(&comp);
    Ok(PcmAudio {
        sample_rate: audio.sample_rate,
        channels: audio.channels,
        frame_count: audio.samples.len() as u32,
        bytes: audio.to_pcm16_le(),
    })
}

/// Synthesize a song into a complete WAV file.
pub fn synthesize_wav(song_json: String, target_seconds: f32) -> anyhow::Result<Vec<u8>> {
    let song = parse(&song_json)?;
    let comp = song::expand(&song, target_seconds);
    Ok(engine::render(&comp).to_wav())
}

/// Synthesize a song into an MP3 file at the given CBR bitrate (kbps).
pub fn synthesize_mp3(
    song_json: String,
    target_seconds: f32,
    bitrate_kbps: u16,
) -> anyhow::Result<Vec<u8>> {
    let song = parse(&song_json)?;
    let comp = song::expand(&song, target_seconds);
    engine::render(&comp).to_mp3(bitrate_kbps)
}

/// Metadata for a streaming playback session.
pub struct StreamInfo {
    pub sample_rate: u32,
    pub channels: u16,
    pub total_frames: u64,
}

/// Begin a streaming playback session for the song expanded to `target_seconds`.
/// Returns format info; pull audio with [`stream_next_chunk`].
pub fn stream_start(song_json: String, target_seconds: f32) -> anyhow::Result<StreamInfo> {
    let song = parse(&song_json)?;
    let comp = song::expand(&song, target_seconds);
    let h = stream::start(&comp);
    Ok(StreamInfo {
        sample_rate: h.sample_rate,
        channels: h.channels,
        total_frames: h.total_frames,
    })
}

/// Pull the next chunk (up to `max_frames` stereo frames) of 16-bit PCM.
/// Returns an empty list once playback is complete.
pub fn stream_next_chunk(max_frames: u32) -> Vec<u8> {
    stream::next(max_frames as usize)
}

/// Stop and release the current streaming session.
pub fn stream_stop() {
    stream::stop();
}
