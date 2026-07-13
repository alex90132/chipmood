//! Real-instrument sample playback (a proper sampler voice) alongside the chip
//! oscillators. A packed bank (extracted from the UT modules) is loaded once and
//! kept in a global; instruments reference a sample by name, or "@kit" to pick a
//! drum sample by note. The engine reads samples with linear interpolation,
//! pitch-shifting melodic samples to the note and looping sustained ones.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};

use serde::Deserialize;

#[derive(Debug)]
pub struct Sample {
    pub pcm: Vec<f32>,
    pub sample_rate: u32,
    pub root_freq: f32,
    pub loop_start: f64,
    pub loop_len: f64, // 0 = one-shot (no loop)
    pub pitched: bool, // melodic/bass = true; drums = false (play native rate)
}

#[derive(Default)]
pub struct SampleBank {
    pub map: HashMap<String, Arc<Sample>>,
    pub by_cat: HashMap<String, Vec<Arc<Sample>>>,
}

#[derive(Deserialize)]
struct MetaSample {
    name: String,
    category: String,
    root_midi: f32,
    sample_rate: u32,
    length: u32,
    loop_start: u32,
    loop_end: u32,
    offset: u32,
}

#[derive(Deserialize)]
struct Meta {
    samples: Vec<MetaSample>,
}

static BANK: OnceLock<Mutex<Option<Arc<SampleBank>>>> = OnceLock::new();
static LOADED_PATH: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn cell() -> &'static Mutex<Option<Arc<SampleBank>>> {
    BANK.get_or_init(|| Mutex::new(None))
}

fn loaded_path() -> &'static Mutex<Option<String>> {
    LOADED_PATH.get_or_init(|| Mutex::new(None))
}

pub fn bank() -> Option<Arc<SampleBank>> {
    cell().lock().ok().and_then(|g| g.clone())
}

fn midi_to_freq(m: f32) -> f32 {
    440.0 * 2f32.powf((m - 69.0) / 12.0)
}

const DRUM_CATS: [&str; 4] = ["kick", "snare", "hat", "tom"];

/// Parse the packed bank: [u32 meta_len][meta json][i16 LE pcm blob].
pub fn load_bytes(data: &[u8]) -> anyhow::Result<()> {
    if data.len() < 4 {
        anyhow::bail!("bank too small");
    }
    let meta_len = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let meta_end = 4 + meta_len;
    if meta_end > data.len() {
        anyhow::bail!("bank meta overruns file");
    }
    let meta: Meta = serde_json::from_slice(&data[4..meta_end])?;
    let blob = &data[meta_end..];
    let mut b = SampleBank::default();
    for m in &meta.samples {
        let start = m.offset as usize;
        let n = m.length as usize;
        let end = start + n * 2;
        if end > blob.len() {
            continue;
        }
        let mut pcm = Vec::with_capacity(n);
        let mut i = start;
        while i + 1 < end {
            let s = i16::from_le_bytes([blob[i], blob[i + 1]]) as f32 / 32768.0;
            pcm.push(s);
            i += 2;
        }
        let pitched = !DRUM_CATS.contains(&m.category.as_str());
        let loop_len = if m.loop_end > m.loop_start + 2 {
            (m.loop_end - m.loop_start) as f64
        } else {
            0.0
        };
        let smp = Arc::new(Sample {
            pcm,
            sample_rate: m.sample_rate,
            root_freq: midi_to_freq(m.root_midi),
            loop_start: m.loop_start as f64,
            loop_len,
            pitched,
        });
        b.map.insert(m.name.clone(), smp.clone());
        b.by_cat.entry(m.category.clone()).or_default().push(smp);
    }
    *cell().lock().unwrap() = Some(Arc::new(b));
    Ok(())
}

/// Load the bank from a file path (used by the app/the offline renderer).
/// Skips the work if the same path is already loaded.
pub fn load_path(path: &str) -> anyhow::Result<()> {
    {
        let g = loaded_path().lock().unwrap();
        if g.as_deref() == Some(path) && bank().is_some() {
            return Ok(());
        }
    }
    let data = std::fs::read(path)?;
    load_bytes(&data)?;
    *loaded_path().lock().unwrap() = Some(path.to_string());
    Ok(())
}

impl SampleBank {
    /// Resolve a track's `sample` reference for a given note pitch:
    /// "@kit" (or "@kitN" for kit variant N) -> a drum sample chosen by the
    /// note's kit piece; otherwise a named melodic/bass sample. The variant
    /// index lets every track use a different-sounding drum kit instead of
    /// always the first sample of each category.
    pub fn resolve(&self, name: &str, kit_cat: &str) -> Option<Arc<Sample>> {
        if let Some(rest) = name.strip_prefix("@kit") {
            let idx: usize = rest.parse().unwrap_or(0);
            return self
                .by_cat
                .get(kit_cat)
                .and_then(|v| if v.is_empty() { None } else { v.get(idx % v.len()) })
                .cloned();
        }
        self.map.get(name).cloned()
    }
}
