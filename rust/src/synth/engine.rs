//! Stereo chiptune synthesis engine.
//!
//! Provides band-limited oscillators (PolyBLEP), per-voice panning, a small
//! stereo reverb for depth, and a reusable [`RenderCore`] that can render any
//! frame range. Whole-buffer rendering (for WAV/MP3 export) and the streaming
//! player both build on the same core.

use crate::synth::model::{Composition, Envelope, Waveform};
use crate::synth::sampler::{self, Sample};
use std::sync::Arc;

pub const CHANNELS: u16 = 2;

/// Rendered stereo audio (interleaved L,R f32 in roughly -1.0..=1.0).
pub struct RenderedAudio {
    pub sample_rate: u32,
    pub channels: u16,
    pub samples: Vec<f32>,
}

impl RenderedAudio {
    pub fn frame_count(&self) -> usize {
        self.samples.len() / self.channels.max(1) as usize
    }

    /// Interleaved little-endian `i16` PCM.
    pub fn to_pcm16_le(&self) -> Vec<u8> {
        pcm16_le(&self.samples)
    }

    /// Self-contained WAV file (16-bit PCM, stereo).
    pub fn to_wav(&self) -> Vec<u8> {
        wav_from_pcm(&self.to_pcm16_le(), self.sample_rate, self.channels)
    }

    /// MP3 via LAME at the given CBR bitrate (kbps).
    pub fn to_mp3(&self, bitrate_kbps: u16) -> anyhow::Result<Vec<u8>> {
        mp3_from_stereo(&self.samples, self.sample_rate, bitrate_kbps)
    }
}

// ---- Encoders --------------------------------------------------------------

pub fn pcm16_le(samples: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(samples.len() * 2);
    for &s in samples {
        let v = (s.clamp(-1.0, 1.0) * i16::MAX as f32) as i16;
        out.extend_from_slice(&v.to_le_bytes());
    }
    out
}

fn wav_from_pcm(pcm: &[u8], sample_rate: u32, channels: u16) -> Vec<u8> {
    let data_len = pcm.len() as u32;
    let byte_rate = sample_rate * channels as u32 * 2;
    let block_align = channels * 2;
    let mut wav = Vec::with_capacity(44 + pcm.len());
    wav.extend_from_slice(b"RIFF");
    wav.extend_from_slice(&(36 + data_len).to_le_bytes());
    wav.extend_from_slice(b"WAVE");
    wav.extend_from_slice(b"fmt ");
    wav.extend_from_slice(&16u32.to_le_bytes());
    wav.extend_from_slice(&1u16.to_le_bytes());
    wav.extend_from_slice(&channels.to_le_bytes());
    wav.extend_from_slice(&sample_rate.to_le_bytes());
    wav.extend_from_slice(&byte_rate.to_le_bytes());
    wav.extend_from_slice(&block_align.to_le_bytes());
    wav.extend_from_slice(&16u16.to_le_bytes());
    wav.extend_from_slice(b"data");
    wav.extend_from_slice(&data_len.to_le_bytes());
    wav.extend_from_slice(pcm);
    wav
}

fn mp3_from_stereo(samples: &[f32], sample_rate: u32, bitrate_kbps: u16) -> anyhow::Result<Vec<u8>> {
    use mp3lame_encoder::{Builder, DualPcm, FlushNoGap, Quality};
    let frames = samples.len() / 2;
    let mut left = Vec::with_capacity(frames);
    let mut right = Vec::with_capacity(frames);
    for f in 0..frames {
        left.push(samples[f * 2]);
        right.push(samples[f * 2 + 1]);
    }
    let mut b = Builder::new().ok_or_else(|| anyhow::anyhow!("LAME builder"))?;
    b.set_num_channels(2).map_err(|e| anyhow::anyhow!("ch: {e:?}"))?;
    b.set_sample_rate(sample_rate).map_err(|e| anyhow::anyhow!("sr: {e:?}"))?;
    b.set_brate(bitrate_to_enum(bitrate_kbps)).map_err(|e| anyhow::anyhow!("br: {e:?}"))?;
    b.set_quality(Quality::Best).map_err(|e| anyhow::anyhow!("q: {e:?}"))?;
    let mut enc = b.build().map_err(|e| anyhow::anyhow!("init: {e:?}"))?;
    let mut out: Vec<u8> = Vec::with_capacity(mp3lame_encoder::max_required_buffer_size(frames));
    let input = DualPcm { left: &left, right: &right };
    enc.encode_to_vec(input, &mut out).map_err(|e| anyhow::anyhow!("encode: {e:?}"))?;
    enc.flush_to_vec::<FlushNoGap>(&mut out).map_err(|e| anyhow::anyhow!("flush: {e:?}"))?;
    Ok(out)
}

fn bitrate_to_enum(kbps: u16) -> mp3lame_encoder::Bitrate {
    use mp3lame_encoder::Bitrate::*;
    match kbps {
        0..=104 => Kbps96,
        105..=144 => Kbps128,
        145..=176 => Kbps160,
        177..=208 => Kbps192,
        209..=240 => Kbps224,
        241..=288 => Kbps256,
        _ => Kbps320,
    }
}

// ---- Oscillators (band-limited) -------------------------------------------

#[inline]
fn frac(x: f32) -> f32 {
    x - x.floor()
}

/// PolyBLEP correction for a discontinuity, removing most aliasing.
#[inline]
fn poly_blep(t: f32, dt: f32) -> f32 {
    if dt <= 0.0 {
        return 0.0;
    }
    if t < dt {
        let x = t / dt;
        x + x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt;
        x * x + x + x + 1.0
    } else {
        0.0
    }
}

/// Oscillator value for `phase` in 0..1 with per-sample step `dt = freq/sr`.
#[inline]
fn oscillator(wave: Waveform, phase: f32, dt: f32, duty: f32, noise: f32) -> f32 {
    use core::f32::consts::PI;
    match wave {
        Waveform::Sine => (phase * 2.0 * PI).sin(),
        Waveform::Sawtooth => {
            let naive = 2.0 * phase - 1.0;
            naive - poly_blep(phase, dt)
        }
        Waveform::Square => pulse(phase, dt, 0.5),
        Waveform::Pulse => pulse(phase, dt, duty.clamp(0.05, 0.95)),
        Waveform::Triangle => {
            if phase < 0.5 {
                4.0 * phase - 1.0
            } else {
                3.0 - 4.0 * phase
            }
        }
        Waveform::Noise => noise,
    }
}

#[inline]
fn pulse(phase: f32, dt: f32, duty: f32) -> f32 {
    let naive = if phase < duty { 1.0 } else { -1.0 };
    naive + poly_blep(phase, dt) - poly_blep(frac(phase - duty + 1.0), dt)
}

/// Deterministic, position-independent white noise for percussion.
#[inline]
fn noise_at(seed: u64, local: u64) -> f32 {
    let mut x = seed
        .wrapping_mul(0x9E3779B97F4A7C15)
        .wrapping_add(local.wrapping_mul(0xD1B54A32D192ED03));
    x ^= x >> 30;
    x = x.wrapping_mul(0xBF58476D1CE4E5B9);
    x ^= x >> 27;
    (x >> 40) as f32 / (1u64 << 23) as f32 * 2.0 - 1.0
}

/// Equal-power pan gains for a pan value in -1..1.
#[inline]
fn pan_gains(pan: f32) -> (f32, f32) {
    use core::f32::consts::PI;
    let p = pan.clamp(-1.0, 1.0);
    let angle = (p + 1.0) * 0.25 * PI;
    (angle.cos(), angle.sin())
}

#[inline]
fn envelope_at(env: &Envelope, i: usize, gate: usize, sr: f32) -> f32 {
    let t = i as f32 / sr;
    let gate_t = gate as f32 / sr;
    let sustain = env.sustain.clamp(0.0, 1.0);
    if i < gate {
        if t < env.attack {
            if env.attack <= 0.0 { 1.0 } else { t / env.attack }
        } else if t < env.attack + env.decay {
            if env.decay <= 0.0 {
                sustain
            } else {
                1.0 - (t - env.attack) / env.decay * (1.0 - sustain)
            }
        } else {
            sustain
        }
    } else if env.release <= 0.0 {
        0.0
    } else {
        let rel = t - gate_t;
        let lvl = level_at_gate_close(env, gate_t, sustain);
        (1.0 - rel / env.release).max(0.0) * lvl
    }
}

fn level_at_gate_close(env: &Envelope, gate_t: f32, sustain: f32) -> f32 {
    if gate_t < env.attack {
        if env.attack <= 0.0 { 1.0 } else { gate_t / env.attack }
    } else if gate_t < env.attack + env.decay {
        if env.decay <= 0.0 {
            sustain
        } else {
            1.0 - (gate_t - env.attack) / env.decay * (1.0 - sustain)
        }
    } else {
        sustain
    }
}

// ---- Render core -----------------------------------------------------------

struct NoteEv {
    dt: f32,
    from_dt: f32,    // starting pitch increment for portamento (== dt if none)
    glide_frames: usize,
    start_frame: usize,
    span: usize,  // gate + release, in frames
    gate: usize,
    amp: f32,
    melodic: bool,
    waveform: Waveform,
    duty: f32,
    drive: f32,
    tone: f32,
    drum_kind: u8,     // 0 kick, 1 snare, 2 tom, 3 hat (noise voices)
    vib_depth: f32,    // per-note vibrato depth (0 = engine default)
    cutoff: f32,       // resonant low-pass cutoff (1 = open)
    resonance: f32,
    filter_env: f32,
    crush: f32,
    trem: f32,
    env: Envelope,
    gain_l: f32,
    gain_r: f32,
    seed: u64,
    sample: Option<Arc<Sample>>, // Some = sampler voice (overrides oscillator)
}

/// Map a drum/noise MIDI pitch to a kit piece: 0 kick, 1 snare, 2 tom, 3 hat.
#[inline]
fn drum_kind_of(pitch: i32) -> u8 {
    if pitch <= 36 {
        0
    } else if pitch <= 39 {
        1
    } else if pitch <= 41 {
        2
    } else {
        3
    }
}

/// Precomputed, immutable view of a composition that can render any frame range.
pub struct RenderCore {
    pub sample_rate: u32,
    pub master: f32,
    pub total_frames: usize,
    notes: Vec<NoteEv>,
}

impl RenderCore {
    pub fn build(comp: &Composition) -> Self {
        let sr = comp.sample_rate.max(8_000);
        let srf = sr as f32;
        let beat_secs = 60.0 / comp.bpm.max(1.0);
        let mut notes = Vec::new();
        let mut total = 1usize;
        let bank = sampler::bank();

        // Gain staging: give headroom so summed voices don't clip/distort.
        let active_tracks = comp.tracks.iter().filter(|t| !t.notes.is_empty()).count();
        let headroom = 1.0 / (0.65 * (active_tracks.max(1) as f32).sqrt() + 0.35);

        for (ti, track) in comp.tracks.iter().enumerate() {
            let (gl, gr) = pan_gains(track.pan);
            let melodic = !matches!(track.waveform, Waveform::Noise);
            // Noise (percussion) tends to be loud; tame it a little.
            let voice_trim = if melodic { 0.7 } else { 0.5 };
            let glide_secs = if melodic { track.glide.max(0.0) } else { 0.0 };
            let f_cut = if melodic { track.cutoff.clamp(0.05, 1.0) } else { 1.0 };
            let f_res = track.resonance.clamp(0.0, 0.95);
            let f_env = if melodic { track.filter_env.clamp(0.0, 1.0) } else { 0.0 };
            let mut prev_dt = 0.0f32; // last note's pitch increment (for glide)
            let mut prev_end = -1i64;
            for (ni, n) in track.notes.iter().enumerate() {
                if n.is_rest() || n.duration <= 0.0 {
                    continue;
                }
                // Note delay (lay-back groove) shifts the start.
                let start_frame =
                    ((n.start + n.delay.max(0.0)) * beat_secs * srf) as usize;
                let gate = (n.duration * beat_secs * srf) as usize;
                let release = (track.envelope.release * srf) as usize;
                let span = gate + release;
                let seed = ((ti as u64) << 32 ^ ni as u64).wrapping_add(0x1234_5678);
                // Subtle velocity humanization to avoid a robotic feel.
                let dither = 0.92 + 0.08 * ((noise_at(seed, 0) + 1.0) * 0.5);
                let amp = track.volume.clamp(0.0, 1.0)
                    * n.velocity.clamp(0.0, 1.0)
                    * voice_trim
                    * dither;
                let dt = n.frequency() / srf;
                let vib_depth = if melodic { n.vib.clamp(0.0, 1.0) } else { 0.0 };
                // Resolve a sampler voice for this note (if the track uses one).
                let smp = match (&bank, &track.sample) {
                    (Some(b), Some(name)) => {
                        let cat = match drum_kind_of(n.pitch) {
                            0 => "kick",
                            1 => "snare",
                            2 => "tom",
                            _ => "hat",
                        };
                        b.resolve(name, cat)
                    }
                    _ => None,
                };

                // Tracker-style hardware arpeggio: split the note into rapid
                // sub-notes cycling [0, ...offsets] semitones — a chord on one
                // channel, the signature NES/MOD sound.
                if melodic && !n.arp.is_empty() {
                    let mut offs = vec![0i32];
                    offs.extend(n.arp.iter().copied().filter(|o| o.abs() <= 24));
                    let step = ((srf / 50.0) as usize).max(64); // ~50 Hz cycle
                    let sub_rel = release.min(step / 2);
                    let mut t = 0usize;
                    let mut k = 0usize;
                    while t < gate {
                        let g = step.min(gate - t);
                        let p = n.pitch + offs[k % offs.len()];
                        notes.push(NoteEv {
                            dt: crate::synth::model::pitch_to_freq(p) / srf,
                            from_dt: crate::synth::model::pitch_to_freq(p) / srf,
                            glide_frames: 0,
                            start_frame: start_frame + t,
                            span: g + sub_rel,
                            gate: g,
                            amp,
                            melodic: true,
                            waveform: track.waveform,
                            duty: track.duty,
                            drive: track.drive.clamp(0.0, 1.0),
                            tone: 0.5,
                            drum_kind: 0,
                            vib_depth: 0.0,
                            cutoff: f_cut,
                            resonance: f_res,
                            filter_env: f_env,
                            crush: track.crush.clamp(0.0, 1.0),
                            trem: track.trem.clamp(0.0, 1.0),
                            env: track.envelope,
                            gain_l: gl,
                            gain_r: gr,
                            seed: seed ^ (k as u64),
                            sample: smp.clone(),
                        });
                        t += step;
                        k += 1;
                    }
                    prev_dt = dt;
                    prev_end = (start_frame + gate) as i64;
                    total = total.max(start_frame + gate + sub_rel);
                    continue;
                }

                // Retrigger / stutter: re-strike the same pitch N times.
                if melodic && n.retrig > 1 && gate > 0 {
                    let count = (n.retrig.min(16)) as usize;
                    let step = (gate / count).max(64);
                    let sub_rel = release.min(step / 2);
                    let mut k = 0usize;
                    while k * step < gate {
                        let t = k * step;
                        let g = step.min(gate - t);
                        notes.push(NoteEv {
                            dt,
                            from_dt: dt,
                            glide_frames: 0,
                            start_frame: start_frame + t,
                            span: g + sub_rel,
                            gate: g,
                            amp,
                            melodic: true,
                            waveform: track.waveform,
                            duty: track.duty,
                            drive: track.drive.clamp(0.0, 1.0),
                            tone: track.tone.clamp(0.0, 1.0),
                            drum_kind: 0,
                            vib_depth,
                            cutoff: f_cut,
                            resonance: f_res,
                            filter_env: f_env,
                            crush: track.crush.clamp(0.0, 1.0),
                            trem: track.trem.clamp(0.0, 1.0),
                            env: track.envelope,
                            gain_l: gl,
                            gain_r: gr,
                            seed: seed ^ (k as u64),
                            sample: smp.clone(),
                        });
                        k += 1;
                    }
                    prev_dt = dt;
                    prev_end = (start_frame + gate) as i64;
                    total = total.max(start_frame + gate + release);
                    continue;
                }

                // Pitch slide (portamento) over the note OVERRIDES legato glide.
                let (eff_dt, from_dt, glide_frames) = if n.slide.abs() > 1e-3 {
                    let endf = 440.0
                        * 2f32.powf((n.pitch as f32 + n.slide - 69.0) / 12.0)
                        / srf;
                    (endf, dt, gate.max(1))
                } else {
                    let close = prev_end >= 0
                        && (start_frame as i64 - prev_end).abs() < (0.18 * srf) as i64;
                    if glide_secs > 0.0 && close && prev_dt > 0.0 {
                        (dt, prev_dt, ((glide_secs * srf) as usize).min(gate.max(1)))
                    } else {
                        (dt, dt, 0)
                    }
                };
                notes.push(NoteEv {
                    dt: eff_dt,
                    from_dt,
                    glide_frames,
                    start_frame,
                    span,
                    gate,
                    amp,
                    melodic,
                    waveform: track.waveform,
                    duty: track.duty,
                    drive: track.drive.clamp(0.0, 1.0),
                    tone: track.tone.clamp(0.0, 1.0),
                    drum_kind: if melodic { 0 } else { drum_kind_of(n.pitch) },
                    vib_depth,
                    cutoff: f_cut,
                    resonance: f_res,
                    filter_env: f_env,
                    crush: track.crush.clamp(0.0, 1.0),
                    trem: track.trem.clamp(0.0, 1.0),
                    env: track.envelope,
                    gain_l: gl,
                    gain_r: gr,
                    seed,
                    sample: smp.clone(),
                });
                prev_dt = eff_dt;
                prev_end = (start_frame + gate) as i64;
                total = total.max(start_frame + span);
            }
        }
        let master = (comp.master_volume.clamp(0.0, 1.0) * headroom).min(1.0);
        RenderCore { sample_rate: sr, master, total_frames: total, notes }
    }

    /// Render frames [start, start+count) as interleaved stereo into `out`
    /// (which is resized to count*2). Dry signal, no reverb/limiter/fade.
    pub fn render_range(&self, start: usize, count: usize, out: &mut Vec<f32>) {
        out.clear();
        out.resize(count * 2, 0.0);
        let srf = self.sample_rate as f32;
        let end = start + count;
        for ev in &self.notes {
            let ns = ev.start_frame;
            let ne = ev.start_frame + ev.span;
            if ns >= end || ne <= start {
                continue;
            }
            let from = ns.max(start);
            let to = ne.min(end);
            let f0 = ev.dt * srf;
            // Vibrato on sustained melodic notes (or when a per-note depth is set).
            let vib = ev.melodic && (ev.vib_depth > 0.0 || ev.gate as f32 / srf > 0.4);
            const VIB_RATE: f32 = 5.5;
            let vib_depth_v = if ev.vib_depth > 0.0 {
                0.004 + 0.03 * ev.vib_depth
            } else {
                0.004
            };
            let mod_index = if vib {
                f0 * vib_depth_v / (core::f32::consts::TAU * VIB_RATE)
            } else {
                0.0
            };

            // Per-note sound-design state.
            // Noise voices: blend a dark low-pass (hiss) with a resonant
            // band-pass (metallic ring) by `tone`, so drums can hiss or ring.
            // Drum synthesis state (noise voices): each kit piece is its own
            // synth — kick/tom = pitch-swept sine, snare = band-passed noise +
            // tonal body, hat = high-passed noise. NOT one filtered noise.
            let is_noise = matches!(ev.waveform, Waveform::Noise);
            let kind = ev.drum_kind;
            let mut kphase = 0.0f32; // kick/tom body phase (cycles)
            let mut sn_lp = 0.0f32; // snare band-pass state
            let mut sn_band = 0.0f32;
            let mut sn_phase = 0.0f32; // snare tonal body phase
            let mut hat_lp = 0.0f32; // hat high-pass state
            let snare_f = (2.0 * (core::f32::consts::PI * 1800.0 / srf).sin()).min(0.5);
            let mut nlp = 0.0f32; // low-pass state
            let mut svf_low = 0.0f32;
            let mut svf_band = 0.0f32;
            // Drive (waveshaper) precomputed gain + makeup.
            let drv = ev.drive;
            let drv_pre = 1.0 + drv * 6.0;
            let drv_mk = 1.0 / (1.0 + drv * 1.2);
            // Bitcrush: quantize to fewer levels (16 bits down to ~4).
            let crush_levels = if ev.crush > 0.0 {
                (2.0f32).powf(12.0 - 8.0 * ev.crush).max(2.0)
            } else {
                0.0
            };
            // Tremolo: amplitude wobble ~6 Hz.
            const TREM_RATE: f32 = 6.0;
            let trem_d = ev.trem;
            // IT-style resonant low-pass with an envelope sweep (pluck/wow) —
            // the demoscene/Unreal Tournament richness. Zero-delay (TPT) SVF.
            let do_filt = ev.melodic && (ev.cutoff < 0.999 || ev.filter_env > 0.0);
            let f_q = 0.5 + ev.resonance * 8.0;
            let f_k = 1.0 / f_q;
            let f_env_decay = 0.25 * srf;
            let mut ic1 = 0.0f32;
            let mut ic2 = 0.0f32;
            // Sampler playback step (frames of sample per output frame): pitched
            // voices track the note, drums play at their native rate.
            let smp_step = match &ev.sample {
                Some(s) if s.pitched => (s.sample_rate as f64) * (ev.dt as f64)
                    / (s.root_freq.max(1.0) as f64),
                Some(s) => s.sample_rate as f64 / srf as f64,
                None => 0.0,
            };

            for f in from..to {
                let local = f - ns;
                let tt = local as f32 / srf;
                // Base phase accumulation, honoring portamento when set.
                let base = if ev.glide_frames > 0 {
                    let g = ev.glide_frames as f32;
                    let li = local as f32;
                    if local < ev.glide_frames {
                        ev.from_dt * li + (ev.dt - ev.from_dt) * (li * (li - 1.0) * 0.5) / g
                    } else {
                        ev.from_dt * g + (ev.dt - ev.from_dt) * (g * (g - 1.0) * 0.5) / g
                            + ev.dt * (li - g)
                    }
                } else {
                    local as f32 * ev.dt
                };
                let cycles = if vib {
                    base + mod_index * (1.0 - (core::f32::consts::TAU * VIB_RATE * tt).cos())
                } else {
                    base
                };
                let nz = noise_at(ev.seed, local as u64);
                let mut osc = if let Some(s) = &ev.sample {
                    // Sampler voice: read the PCM with linear interpolation,
                    // looping sustained samples; position is derived from the
                    // absolute in-note frame so it's seamless across chunks.
                    let mut pos = local as f64 * smp_step;
                    if s.loop_len > 0.0 && pos >= s.loop_start + s.loop_len {
                        pos = s.loop_start + ((pos - s.loop_start) % s.loop_len);
                    }
                    let i = pos as usize;
                    if i + 1 < s.pcm.len() {
                        let fr = (pos - i as f64) as f32;
                        s.pcm[i] * (1.0 - fr) + s.pcm[i + 1] * fr
                    } else if i < s.pcm.len() {
                        s.pcm[i]
                    } else {
                        0.0
                    }
                } else if is_noise {
                    let ttn = local as f32 / srf;
                    match kind {
                        0 => {
                            // KICK: pitch-swept sine (≈152→42 Hz) + transient
                            // click. Deeper floor, longer body, a bit hotter —
                            // real sub weight to match sampled originals.
                            let f = 42.0 + 110.0 * (-ttn / 0.04).exp();
                            kphase += f / srf;
                            let body = (kphase * core::f32::consts::TAU).sin();
                            let click = nz * (-ttn / 0.005).exp();
                            (body * 1.18 + 0.32 * click) * (-ttn / 0.16).exp()
                        }
                        2 => {
                            // TOM: pitch-swept sine, a touch longer.
                            let f = 110.0 + 80.0 * (-ttn / 0.08).exp();
                            kphase += f / srf;
                            (kphase * core::f32::consts::TAU).sin() * (-ttn / 0.18).exp()
                        }
                        1 => {
                            // SNARE: band-passed noise + ~190 Hz tonal body.
                            let high = nz - sn_lp - 0.6 * sn_band;
                            sn_band += snare_f * high;
                            sn_lp += snare_f * sn_band;
                            sn_phase += 190.0 / srf;
                            let body = (sn_phase * core::f32::consts::TAU).sin();
                            (0.85 * sn_band + 0.5 * body) * (-ttn / 0.09).exp()
                        }
                        _ => {
                            // HAT: high-passed noise, very short.
                            hat_lp += 0.5 * (nz - hat_lp);
                            (nz - hat_lp) * (-ttn / 0.028).exp()
                        }
                    }
                } else {
                    let phase = frac(cycles);
                    oscillator(ev.waveform, phase, ev.dt, ev.duty, nz)
                };
                // Overdrive / distortion: soft waveshaping with makeup gain.
                if drv > 0.0 {
                    osc = (osc * drv_pre).tanh() * drv_mk;
                }
                // Bitcrush (lo-fi quantization).
                if crush_levels > 0.0 {
                    osc = (osc * crush_levels).round() / crush_levels;
                }
                // Resonant low-pass with cutoff envelope (opens then settles).
                if do_filt {
                    let envv = (-(local as f32) / f_env_decay).exp();
                    let cutn =
                        (ev.cutoff + ev.filter_env * (1.0 - ev.cutoff) * envv).clamp(0.02, 1.0);
                    let fc = (60.0 * (20000.0f32 / 60.0).powf(cutn)).min(srf * 0.45);
                    let g = (core::f32::consts::PI * fc / srf).tan();
                    let a1 = 1.0 / (1.0 + g * (g + f_k));
                    let a2 = g * a1;
                    let a3 = g * a2;
                    let v3 = osc - ic2;
                    let v1 = a1 * ic1 + a2 * v3;
                    let v2 = ic2 + a2 * ic1 + a3 * v3;
                    ic1 = 2.0 * v1 - ic1;
                    ic2 = 2.0 * v2 - ic2;
                    osc = v2.clamp(-2.0, 2.0);
                }
                let env = envelope_at(&ev.env, local, ev.gate, srf);
                let mut amp = ev.amp;
                if trem_d > 0.0 {
                    let lfo = 0.5 - 0.5 * (core::f32::consts::TAU * TREM_RATE * tt).cos();
                    amp *= 1.0 - trem_d * lfo;
                }
                let s = osc * env * amp;
                let idx = (f - start) * 2;
                out[idx] += s * ev.gain_l;
                out[idx + 1] += s * ev.gain_r;
            }
        }
    }
}

// ---- Stereo reverb (Freeverb-lite) ----------------------------------------

struct Comb {
    buf: Vec<f32>,
    idx: usize,
    feedback: f32,
    damp: f32,
    store: f32,
}

impl Comb {
    fn new(len: usize, feedback: f32, damp: f32) -> Self {
        Self { buf: vec![0.0; len.max(1)], idx: 0, feedback, damp, store: 0.0 }
    }
    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let y = self.buf[self.idx];
        self.store = y * (1.0 - self.damp) + self.store * self.damp;
        self.buf[self.idx] = x + self.store * self.feedback;
        self.idx += 1;
        if self.idx >= self.buf.len() {
            self.idx = 0;
        }
        y
    }
}

struct Allpass {
    buf: Vec<f32>,
    idx: usize,
    feedback: f32,
}

impl Allpass {
    fn new(len: usize, feedback: f32) -> Self {
        Self { buf: vec![0.0; len.max(1)], idx: 0, feedback }
    }
    #[inline]
    fn process(&mut self, x: f32) -> f32 {
        let bufout = self.buf[self.idx];
        let out = -x + bufout;
        self.buf[self.idx] = x + bufout * self.feedback;
        self.idx += 1;
        if self.idx >= self.buf.len() {
            self.idx = 0;
        }
        out
    }
}

pub struct Reverb {
    combs_l: Vec<Comb>,
    combs_r: Vec<Comb>,
    ap_l: Vec<Allpass>,
    ap_r: Vec<Allpass>,
    wet: f32,
    dry: f32,
}

impl Reverb {
    pub fn new(sample_rate: u32, wet: f32) -> Self {
        let scale = sample_rate as f32 / 44_100.0;
        let s = |n: usize| ((n as f32) * scale) as usize;
        let spread = s(23);
        let fb = 0.84;
        let damp = 0.2;
        let combs = [1116usize, 1188, 1277, 1356];
        let aps = [556usize, 441];
        Reverb {
            combs_l: combs.iter().map(|&c| Comb::new(s(c), fb, damp)).collect(),
            combs_r: combs.iter().map(|&c| Comb::new(s(c) + spread, fb, damp)).collect(),
            ap_l: aps.iter().map(|&a| Allpass::new(s(a), 0.5)).collect(),
            ap_r: aps.iter().map(|&a| Allpass::new(s(a) + spread, 0.5)).collect(),
            wet,
            dry: 1.0 - wet * 0.5,
        }
    }

    /// Process interleaved stereo in place.
    pub fn process(&mut self, buf: &mut [f32]) {
        let frames = buf.len() / 2;
        for f in 0..frames {
            let l = buf[f * 2];
            let r = buf[f * 2 + 1];
            let input = (l + r) * 0.5;

            let mut wl = 0.0;
            for c in &mut self.combs_l {
                wl += c.process(input);
            }
            let mut wr = 0.0;
            for c in &mut self.combs_r {
                wr += c.process(input);
            }
            for a in &mut self.ap_l {
                wl = a.process(wl);
            }
            for a in &mut self.ap_r {
                wr = a.process(wr);
            }
            buf[f * 2] = l * self.dry + wl * self.wet;
            buf[f * 2 + 1] = r * self.dry + wr * self.wet;
        }
    }
}

// ---- Tempo-synced stereo delay (echo) -------------------------------------

/// A ping-pong style stereo echo. The feedback send is high-passed so the bass
/// and kick don't smear — only the mids/highs (lead, snare, hats) echo, which
/// is how producers add space without mud. Stateful for streaming.
pub struct Delay {
    bl: Vec<f32>,
    br: Vec<f32>,
    idx: usize,
    fb: f32,
    wet: f32,
    hp_x: f32,
    hp_y: f32,
    hp_a: f32,
}

impl Delay {
    /// [time_secs] echo time, [wet] 0..1 overall echo level.
    pub fn new(sample_rate: u32, time_secs: f32, wet: f32) -> Self {
        let sr = sample_rate.max(8_000) as f32;
        let len = ((time_secs.clamp(0.05, 1.5)) * sr) as usize;
        let dt = 1.0 / sr;
        let rc = 1.0 / (2.0 * core::f32::consts::PI * 300.0); // HP ~300 Hz on send
        Delay {
            bl: vec![0.0; len.max(1)],
            br: vec![0.0; len.max(1)],
            idx: 0,
            fb: 0.36,
            wet: wet.clamp(0.0, 1.0) * 0.45,
            hp_x: 0.0,
            hp_y: 0.0,
            hp_a: rc / (rc + dt),
        }
    }

    pub fn process(&mut self, buf: &mut [f32]) {
        let n = self.bl.len();
        let frames = buf.len() / 2;
        for f in 0..frames {
            let l = buf[f * 2];
            let r = buf[f * 2 + 1];
            // High-pass the mono send so lows don't echo.
            let mono = (l + r) * 0.5;
            let hp = self.hp_a * (self.hp_y + mono - self.hp_x);
            self.hp_x = mono;
            self.hp_y = hp;

            let dl = self.bl[self.idx];
            let dr = self.br[self.idx];
            // Ping-pong: each line is fed by the send plus the OTHER line's tail.
            self.bl[self.idx] = hp + dr * self.fb;
            self.br[self.idx] = dl * self.fb;
            self.idx += 1;
            if self.idx >= n {
                self.idx = 0;
            }
            buf[f * 2] = l + dl * self.wet;
            buf[f * 2 + 1] = r + dr * self.wet;
        }
    }
}

// ---- Mastering bus --------------------------------------------------------

/// A small but proper mastering chain applied to the final stereo mix, so the
/// track sounds glued and consistent — and crucially WITHOUT ducking quiet
/// instruments (the old broadband AGC could momentarily swallow voices on loud
/// hits). Stateful, so it runs seamlessly across streaming chunks.
///
/// Signal flow per sample (stereo-linked detection):
///   1. rumble high-pass + gentle low-shelf cleanup (frees headroom, less mud)
///   2. glue compressor — gentle 2:1, slowish, evens dynamics & "glues"
///   3. long-term leveler — very slow, keeps section-to-section loudness even
///   4. brickwall limiter — transparent peak control under the ceiling
pub struct Mastering {
    // EQ state (per channel)
    hp_xl: f32,
    hp_yl: f32,
    hp_xr: f32,
    hp_yr: f32,
    hp_a: f32,
    lp_l: f32,
    lp_r: f32,
    lp_a: f32,
    low_trim: f32,
    // glue compressor
    c_env: f32,
    c_atk: f32,
    c_rel: f32,
    c_thr: f32,
    c_ratio: f32,
    c_makeup: f32,
    // long-term leveler
    lv_env: f32,
    lv_gain: f32,
    lv_atk: f32,
    lv_rel: f32,
    lv_smooth: f32,
    lv_target: f32,
    lv_min: f32,
    lv_max: f32,
    // limiter
    lim_gain: f32,
    lim_rel: f32,
    ceiling: f32,
}

impl Mastering {
    pub fn new(sample_rate: u32) -> Self {
        let sr = sample_rate.max(8_000) as f32;
        let dt = 1.0 / sr;
        let coef = |ms: f32| (-1.0 / (ms * 0.001 * sr)).exp();
        // one-pole high-pass ~30 Hz
        let rc_hp = 1.0 / (2.0 * core::f32::consts::PI * 30.0);
        let hp_a = rc_hp / (rc_hp + dt);
        // one-pole low-pass ~150 Hz (for the low-shelf cleanup)
        let rc_lp = 1.0 / (2.0 * core::f32::consts::PI * 150.0);
        let lp_a = dt / (rc_lp + dt);
        Mastering {
            hp_xl: 0.0,
            hp_yl: 0.0,
            hp_xr: 0.0,
            hp_yr: 0.0,
            hp_a,
            lp_l: 0.0,
            lp_r: 0.0,
            lp_a,
            low_trim: 0.16, // shave ~16% of the sub-low band to reduce mud
            c_env: 0.0,
            c_atk: coef(12.0),
            c_rel: coef(180.0),
            c_thr: 0.16,
            c_ratio: 2.0,
            c_makeup: 1.5,
            lv_env: 0.0,
            lv_gain: 1.0,
            lv_atk: coef(400.0),
            lv_rel: coef(1200.0),
            lv_smooth: coef(300.0),
            lv_target: 0.32,
            lv_min: 0.7,
            lv_max: 1.7,
            ceiling: 0.95,
            lim_gain: 1.0,
            lim_rel: coef(80.0),
        }
    }

    #[inline]
    fn hp(&self, prev_y: f32, x: f32, prev_x: f32) -> f32 {
        self.hp_a * (prev_y + x - prev_x)
    }

    /// Process interleaved stereo in place.
    pub fn process(&mut self, buf: &mut [f32]) {
        let frames = buf.len() / 2;
        for f in 0..frames {
            let l0 = buf[f * 2];
            let r0 = buf[f * 2 + 1];

            // 1. EQ: high-pass (rumble) then gentle low-shelf cleanup.
            let yl = self.hp(self.hp_yl, l0, self.hp_xl);
            self.hp_xl = l0;
            self.hp_yl = yl;
            let yr = self.hp(self.hp_yr, r0, self.hp_xr);
            self.hp_xr = r0;
            self.hp_yr = yr;
            self.lp_l += self.lp_a * (yl - self.lp_l);
            self.lp_r += self.lp_a * (yr - self.lp_r);
            let mut l = yl - self.low_trim * self.lp_l;
            let mut r = yr - self.low_trim * self.lp_r;

            // 2. Glue compressor (stereo-linked, gentle, won't duck voices).
            let det = l.abs().max(r.abs());
            if det > self.c_env {
                self.c_env = self.c_atk * self.c_env + (1.0 - self.c_atk) * det;
            } else {
                self.c_env = self.c_rel * self.c_env + (1.0 - self.c_rel) * det;
            }
            let cg = if self.c_env > self.c_thr {
                (self.c_thr + (self.c_env - self.c_thr) / self.c_ratio) / self.c_env
            } else {
                1.0
            };
            let g = cg * self.c_makeup;
            l *= g;
            r *= g;

            // 3. Long-term leveler: keep sections at an even loudness. Very slow
            //    so individual instruments are never pumped/ducked.
            let d2 = l.abs().max(r.abs());
            if d2 > self.lv_env {
                self.lv_env = self.lv_atk * self.lv_env + (1.0 - self.lv_atk) * d2;
            } else {
                self.lv_env = self.lv_rel * self.lv_env + (1.0 - self.lv_rel) * d2;
            }
            let want = if self.lv_env > 1e-4 {
                (self.lv_target / self.lv_env).clamp(self.lv_min, self.lv_max)
            } else {
                self.lv_max
            };
            self.lv_gain = self.lv_smooth * self.lv_gain + (1.0 - self.lv_smooth) * want;
            l *= self.lv_gain;
            r *= self.lv_gain;

            // 4. Brickwall limiter: instant attack, smooth release.
            let peak = l.abs().max(r.abs());
            let tgt = if peak > self.ceiling { self.ceiling / peak } else { 1.0 };
            if tgt < self.lim_gain {
                self.lim_gain = tgt; // catch the transient immediately
            } else {
                self.lim_gain = self.lim_rel * self.lim_gain + (1.0 - self.lim_rel) * tgt;
            }
            buf[f * 2] = l * self.lim_gain;
            buf[f * 2 + 1] = r * self.lim_gain;
        }
    }
}

// ---- Finalization & whole-buffer render -----------------------------------

pub const REVERB_WET: f32 = 0.14;

/// Apply master gain to a dry buffer (call before reverb).
pub fn apply_master(buf: &mut [f32], master: f32) {
    for s in buf.iter_mut() {
        *s *= master;
    }
}

/// Transparent soft-clip: linear below the knee, gently saturated above, so
/// normal levels stay clean and only peaks are tamed (no harsh distortion).
#[inline]
fn soft_clip(x: f32) -> f32 {
    const KNEE: f32 = 0.7;
    let a = x.abs();
    if a <= KNEE {
        x
    } else {
        x.signum() * (KNEE + (1.0 - KNEE) * ((a - KNEE) / (1.0 - KNEE)).tanh())
    }
}

/// Soft-clip limiter + click-free fades, given the chunk's absolute position.
pub fn finalize(buf: &mut [f32], abs_start: usize, total_frames: usize, sample_rate: u32) {
    for s in buf.iter_mut() {
        *s = soft_clip(*s);
    }
    let frames = buf.len() / 2;
    let fade_in = (sample_rate as f32 * 0.005) as usize;
    let fade_out = (sample_rate as f32 * 1.2) as usize;
    for f in 0..frames {
        let abs = abs_start + f;
        let mut g = 1.0f32;
        if abs < fade_in && fade_in > 0 {
            g *= abs as f32 / fade_in as f32;
        }
        let remaining = total_frames.saturating_sub(abs + 1);
        if remaining < fade_out && fade_out > 0 {
            g *= remaining as f32 / fade_out as f32;
        }
        buf[f * 2] *= g;
        buf[f * 2 + 1] *= g;
    }
}

/// Render an entire composition to stereo (used for WAV/MP3 export).
pub fn render(comp: &Composition) -> RenderedAudio {
    let core = RenderCore::build(comp);
    let total = core.total_frames;
    let mut buf = Vec::new();
    core.render_range(0, total, &mut buf);
    apply_master(&mut buf, core.master);
    Reverb::new(core.sample_rate, REVERB_WET).process(&mut buf);
    if comp.delay_wet > 0.0 {
        let t = (60.0 / comp.bpm.max(1.0)) * 0.75; // dotted-eighth echo
        Delay::new(core.sample_rate, t, comp.delay_wet).process(&mut buf);
    }
    Mastering::new(core.sample_rate).process(&mut buf);
    finalize(&mut buf, 0, total, core.sample_rate);
    RenderedAudio { sample_rate: core.sample_rate, channels: CHANNELS, samples: buf }
}
