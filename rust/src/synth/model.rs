//! Domain model of a chiptune composition.
//!
//! This is the shared contract between the AI composer (which emits JSON),
//! the Dart domain layer and the Rust synthesis engine. Keep it in sync with
//! `lib/src/domain/entities/*`.

use serde::{Deserialize, Serialize};

/// A full piece of music produced by the AI composer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Composition {
    #[serde(default)]
    pub title: String,
    /// Beats per minute.
    pub bpm: f32,
    /// Output sample rate in Hz (e.g. 44100).
    #[serde(default = "default_sample_rate")]
    pub sample_rate: u32,
    /// Master gain applied to the final mix, 0.0..=1.0.
    #[serde(default = "default_master")]
    pub master_volume: f32,
    /// Tempo-synced master echo/delay wetness, 0.0..=1.0 (0 = off).
    #[serde(default)]
    pub delay_wet: f32,
    pub tracks: Vec<Track>,
}

fn default_sample_rate() -> u32 {
    44_100
}

fn default_master() -> f32 {
    0.9
}

/// A single monophonic/polyphonic voice with one timbre.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Track {
    #[serde(default)]
    pub name: String,
    pub waveform: Waveform,
    /// Pulse width for square/pulse waves, 0.0..=1.0.
    #[serde(default = "default_duty")]
    pub duty: f32,
    /// Per-track gain, 0.0..=1.0.
    #[serde(default = "default_track_volume")]
    pub volume: f32,
    /// Stereo position: -1.0 = hard left, 0.0 = center, +1.0 = hard right.
    #[serde(default)]
    pub pan: f32,
    #[serde(default)]
    pub envelope: Envelope,
    /// Portamento time in seconds: a note slides from the previous note's pitch
    /// over this long. 0 = off (classic stepped chiptune pitch).
    #[serde(default)]
    pub glide: f32,
    /// Resonant low-pass cutoff, 0.05 (dark) .. 1.0 (fully open). IT-style.
    #[serde(default = "default_cutoff")]
    pub cutoff: f32,
    /// Filter resonance/emphasis, 0..1 (peak at the cutoff).
    #[serde(default)]
    pub resonance: f32,
    /// Filter envelope amount, 0..1: how far the cutoff sweeps DOWN over the
    /// note (a "pluck"/"wow"). 0 = static filter.
    #[serde(default)]
    pub filter_env: f32,
    /// Overdrive/distortion amount (0 = clean .. 1 = heavily driven).
    #[serde(default)]
    pub drive: f32,
    /// Timbre/colour control. For NOISE voices: 0 = dark hiss .. 1 = bright,
    /// resonant metallic ring. (Unused by tonal voices.)
    #[serde(default = "default_tone")]
    pub tone: f32,
    /// Bitcrush amount (0 = clean .. 1 = heavy lo-fi quantization).
    #[serde(default)]
    pub crush: f32,
    /// Tremolo depth (0 = off .. 1 = full amplitude wobble ~6 Hz).
    #[serde(default)]
    pub trem: f32,
    /// Optional sampler voice: a sample name in the loaded bank, or "@kit" to
    /// pick a drum sample per note. None = use the oscillator `waveform`.
    #[serde(default)]
    pub sample: Option<String>,
    pub notes: Vec<Note>,
}

fn default_duty() -> f32 {
    0.5
}

fn default_tone() -> f32 {
    0.5
}

fn default_cutoff() -> f32 {
    1.0
}

fn default_track_volume() -> f32 {
    0.8
}

/// One note event positioned on the beat grid.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Note {
    /// MIDI note number (60 = middle C). Use a value < 0 for a rest.
    pub pitch: i32,
    /// Start position in beats from the beginning of the track.
    pub start: f32,
    /// Duration in beats.
    pub duration: f32,
    /// Optional per-note velocity, 0.0..=1.0.
    #[serde(default = "default_velocity")]
    pub velocity: f32,
    /// Tracker-style hardware arpeggio: semitone offsets rapidly cycled with the
    /// base pitch (e.g. [4,7] = major chord on one channel). Empty = off.
    #[serde(default)]
    pub arp: Vec<i32>,
    /// Pitch slide (portamento) in semitones reached across the note. 0 = off.
    #[serde(default)]
    pub slide: f32,
    /// Per-note vibrato depth 0..1 (0 = engine default for sustained notes).
    #[serde(default)]
    pub vib: f32,
    /// Retrigger: re-strike the note this many times within its duration
    /// (a stutter). 0 or 1 = play once.
    #[serde(default)]
    pub retrig: i32,
    /// Note delay in beats (lay-back groove). 0 = on the grid.
    #[serde(default)]
    pub delay: f32,
}

fn default_velocity() -> f32 {
    1.0
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Waveform {
    Square,
    Pulse,
    Triangle,
    Sawtooth,
    Sine,
    Noise,
}

/// Classic ADSR amplitude envelope. Times are in seconds, sustain is a level.
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub struct Envelope {
    pub attack: f32,
    pub decay: f32,
    pub sustain: f32,
    pub release: f32,
}

impl Default for Envelope {
    fn default() -> Self {
        Self {
            attack: 0.005,
            decay: 0.04,
            sustain: 0.7,
            release: 0.08,
        }
    }
}

impl Note {
    pub fn is_rest(&self) -> bool {
        self.pitch < 0
    }

    /// Convert the MIDI pitch to a frequency in Hz (A4 = 440 Hz).
    pub fn frequency(&self) -> f32 {
        pitch_to_freq(self.pitch)
    }
}

/// MIDI pitch -> frequency in Hz.
pub fn pitch_to_freq(pitch: i32) -> f32 {
    440.0 * 2f32.powf((pitch as f32 - 69.0) / 12.0)
}
