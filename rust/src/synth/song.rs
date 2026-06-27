//! Tracker-style song model produced by the AI composer.
//!
//! The AI emits a compact song (instruments + a few patterns + an arrangement)
//! and the engine expands the arrangement, looping it until the requested
//! duration is reached. This is how real chiptune fills minutes of music from
//! small, memorable building blocks.

use serde::{Deserialize, Serialize};

use crate::synth::model::{Composition, Envelope, Note, Track, Waveform};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Song {
    #[serde(default)]
    pub title: String,
    /// Tempo chosen by the AI.
    pub bpm: f32,
    #[serde(default = "default_sample_rate")]
    pub sample_rate: u32,
    #[serde(default = "default_master")]
    pub master_volume: f32,
    /// Tempo-synced master echo wetness, 0..1 (0 = off).
    #[serde(default)]
    pub delay_wet: f32,
    /// Voices/timbres chosen by the AI (typically 3-5, NES-style).
    pub instruments: Vec<Instrument>,
    /// Reusable musical blocks (intro, verse, chorus, bridge, fill...).
    pub patterns: Vec<Pattern>,
    /// Order in which patterns play. Looped to fill the target duration.
    #[serde(default)]
    pub arrangement: Vec<String>,
    /// Optional path to a packed sample bank to load before rendering (enables
    /// the sampler voices referenced by instruments' `sample` field).
    #[serde(default)]
    pub sample_bank: Option<String>,
}

fn default_sample_rate() -> u32 {
    44_100
}

fn default_master() -> f32 {
    0.85
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Instrument {
    pub id: String,
    pub waveform: Waveform,
    #[serde(default = "default_duty")]
    pub duty: f32,
    #[serde(default = "default_volume")]
    pub volume: f32,
    /// Stereo position -1..1. If omitted (0), the engine auto-spreads voices.
    #[serde(default)]
    pub pan: f32,
    #[serde(default)]
    pub envelope: Envelope,
    /// Portamento (pitch slide) time in seconds. 0 = off.
    #[serde(default)]
    pub glide: f32,
    /// Resonant low-pass cutoff 0.05..1.0 (1 = open).
    #[serde(default = "default_cutoff")]
    pub cutoff: f32,
    /// Filter resonance 0..1.
    #[serde(default)]
    pub resonance: f32,
    /// Filter envelope sweep amount 0..1.
    #[serde(default)]
    pub filter_env: f32,
    /// Overdrive/distortion amount, 0..1.
    #[serde(default)]
    pub drive: f32,
    /// Noise colour: 0 = dark hiss .. 1 = bright metallic ring.
    #[serde(default = "default_tone")]
    pub tone: f32,
    /// Bitcrush amount, 0..1.
    #[serde(default)]
    pub crush: f32,
    /// Tremolo depth, 0..1.
    #[serde(default)]
    pub trem: f32,
    /// Optional sampler voice: a sample name in the loaded bank, or "@kit".
    #[serde(default)]
    pub sample: Option<String>,
}

fn default_duty() -> f32 {
    0.5
}

fn default_tone() -> f32 {
    0.5
}

fn default_volume() -> f32 {
    0.8
}

fn default_cutoff() -> f32 {
    1.0
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Pattern {
    pub id: String,
    /// Length of the pattern in beats. If 0/omitted it is derived from notes.
    #[serde(default)]
    pub length_beats: f32,
    pub tracks: Vec<PatternTrack>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PatternTrack {
    /// Id of the instrument this lane uses.
    pub instrument: String,
    pub notes: Vec<Note>,
}

impl Song {
    fn pattern_length(p: &Pattern) -> f32 {
        if p.length_beats > 0.0 {
            return p.length_beats;
        }
        let mut max_end = 0.0f32;
        for t in &p.tracks {
            for n in &t.notes {
                let end = n.start + n.duration;
                if end > max_end {
                    max_end = end;
                }
            }
        }
        max_end.max(1.0)
    }
}

/// Expand the song into a flat [`Composition`], looping the arrangement until
/// `target_seconds` of music has been laid out.
pub fn expand(song: &Song, target_seconds: f32) -> Composition {
    const MAX_NOTES: usize = 300_000;

    let bps = (song.bpm.max(1.0)) / 60.0;
    let target_beats = target_seconds.max(1.0) * bps;

    // One low-level track per instrument, preserving declaration order.
    let mut tracks: Vec<Track> = song
        .instruments
        .iter()
        .map(|inst| Track {
            name: inst.id.clone(),
            waveform: inst.waveform,
            duty: inst.duty,
            volume: inst.volume,
            pan: inst.pan,
            envelope: inst.envelope,
            glide: inst.glide,
            cutoff: inst.cutoff,
            resonance: inst.resonance,
            filter_env: inst.filter_env,
            drive: inst.drive,
            tone: inst.tone,
            crush: inst.crush,
            trem: inst.trem,
            sample: inst.sample.clone(),
            notes: Vec::new(),
        })
        .collect();

    auto_spread_pans(&song.instruments, &mut tracks);
    let index_of: std::collections::HashMap<&str, usize> = song
        .instruments
        .iter()
        .enumerate()
        .map(|(i, inst)| (inst.id.as_str(), i))
        .collect();

    let order: Vec<&Pattern> = if song.arrangement.is_empty() {
        song.patterns.iter().collect()
    } else {
        song.arrangement
            .iter()
            .filter_map(|id| song.patterns.iter().find(|p| &p.id == id))
            .collect()
    };

    let mut cursor = 0.0f32;
    let mut note_count = 0usize;

    // Lay one pattern's notes at `cursor`; returns the pattern's length in beats.
    let mut lay = |pattern: &Pattern, cur: f32, tracks: &mut Vec<Track>, nc: &mut usize| -> f32 {
        let len = Song::pattern_length(pattern);
        for ptrack in &pattern.tracks {
            let Some(&ti) = index_of.get(ptrack.instrument.as_str()) else {
                continue;
            };
            for n in &ptrack.notes {
                if cur + n.start >= target_beats || *nc >= MAX_NOTES {
                    continue;
                }
                tracks[ti].notes.push(Note {
                    pitch: n.pitch,
                    start: cur + n.start,
                    duration: n.duration,
                    velocity: n.velocity,
                    arp: n.arp.clone(),
                    slide: n.slide,
                    vib: n.vib,
                    retrig: n.retrig,
                    delay: n.delay,
                });
                *nc += 1;
            }
        }
        len
    };

    if order.len() >= 3 {
        // Real song form: intro ONCE, body looped to fill, outro ONCE at the end
        // — so the track has a genuine beginning, development and ending.
        let intro = order[0];
        let outro = order[order.len() - 1];
        let body = &order[1..order.len() - 1];
        let outro_len = Song::pattern_length(outro);
        cursor += lay(intro, cursor, &mut tracks, &mut note_count);
        if !body.is_empty() {
            let mut i = 0usize;
            while cursor + outro_len < target_beats && note_count < MAX_NOTES {
                let l = lay(body[i % body.len()], cursor, &mut tracks, &mut note_count);
                cursor += l;
                i += 1;
                if l <= 0.0 {
                    break;
                }
            }
        }
        lay(outro, cursor, &mut tracks, &mut note_count);
    } else if !order.is_empty() {
        // Too few sections for an arc — loop the whole arrangement as before.
        'outer: loop {
            let start_cursor = cursor;
            for pattern in &order {
                let l = lay(pattern, cursor, &mut tracks, &mut note_count);
                cursor += l;
                if cursor >= target_beats || note_count >= MAX_NOTES {
                    break 'outer;
                }
            }
            if cursor <= start_cursor {
                break;
            }
        }
    }

    Composition {
        title: song.title.clone(),
        bpm: song.bpm,
        sample_rate: song.sample_rate,
        master_volume: song.master_volume,
        delay_wet: song.delay_wet,
        tracks,
    }
}

/// If the song does not specify panning, spread melodic voices across the
/// stereo field for width, keeping bass and percussion centered.
fn auto_spread_pans(instruments: &[Instrument], tracks: &mut [Track]) {
    let any_pan = instruments.iter().any(|i| i.pan.abs() > 0.001);
    if any_pan {
        return;
    }

    fn is_centered(inst: &Instrument) -> bool {
        if matches!(inst.waveform, Waveform::Noise) {
            return true;
        }
        let id = inst.id.to_lowercase();
        ["bass", "sub", "kick", "drum", "perc"]
            .iter()
            .any(|k| id.contains(k))
    }

    let wide: Vec<usize> = instruments
        .iter()
        .enumerate()
        .filter(|(_, i)| !is_centered(i))
        .map(|(idx, _)| idx)
        .collect();

    let m = wide.len();
    for (k, &idx) in wide.iter().enumerate() {
        tracks[idx].pan = if m <= 1 {
            0.0
        } else {
            -0.6 + 1.2 * (k as f32) / ((m - 1) as f32)
        };
    }
}
