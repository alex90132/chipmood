//! Stateful streaming playback session.
//!
//! Renders the song sequentially in small chunks so playback can start almost
//! instantly and memory stays bounded, while the reverb tail carries correctly
//! across chunk boundaries.

use std::sync::Mutex;

use crate::synth::engine::{
    apply_master, finalize, pcm16_le, Delay, Mastering, RenderCore, Reverb, CHANNELS,
    REVERB_WET,
};
use crate::synth::model::Composition;

pub struct StreamSession {
    core: RenderCore,
    reverb: Reverb,
    delay: Option<Delay>,
    leveler: Mastering,
    cursor: usize,
    scratch: Vec<f32>,
}

impl StreamSession {
    pub fn new(comp: &Composition) -> Self {
        let core = RenderCore::build(comp);
        let reverb = Reverb::new(core.sample_rate, REVERB_WET);
        let delay = if comp.delay_wet > 0.0 {
            let t = (60.0 / comp.bpm.max(1.0)) * 0.75;
            Some(Delay::new(core.sample_rate, t, comp.delay_wet))
        } else {
            None
        };
        let leveler = Mastering::new(core.sample_rate);
        StreamSession { core, reverb, delay, leveler, cursor: 0, scratch: Vec::new() }
    }

    pub fn sample_rate(&self) -> u32 {
        self.core.sample_rate
    }

    pub fn total_frames(&self) -> usize {
        self.core.total_frames
    }

    /// Render and return the next chunk as interleaved 16-bit stereo PCM.
    /// Returns an empty vec once the song is finished.
    pub fn next_chunk(&mut self, max_frames: usize) -> Vec<u8> {
        if self.cursor >= self.core.total_frames || max_frames == 0 {
            return Vec::new();
        }
        let count = max_frames.min(self.core.total_frames - self.cursor);
        self.core.render_range(self.cursor, count, &mut self.scratch);
        apply_master(&mut self.scratch, self.core.master);
        self.reverb.process(&mut self.scratch);
        if let Some(d) = self.delay.as_mut() {
            d.process(&mut self.scratch);
        }
        self.leveler.process(&mut self.scratch);
        finalize(&mut self.scratch, self.cursor, self.core.total_frames, self.core.sample_rate);
        self.cursor += count;
        pcm16_le(&self.scratch)
    }
}

/// Single active playback session (the app plays one track at a time).
static SESSION: Mutex<Option<StreamSession>> = Mutex::new(None);

pub struct StreamHandle {
    pub sample_rate: u32,
    pub channels: u16,
    pub total_frames: u64,
}

pub fn start(comp: &Composition) -> StreamHandle {
    let session = StreamSession::new(comp);
    let handle = StreamHandle {
        sample_rate: session.sample_rate(),
        channels: CHANNELS,
        total_frames: session.total_frames() as u64,
    };
    *SESSION.lock().unwrap() = Some(session);
    handle
}

pub fn next(max_frames: usize) -> Vec<u8> {
    let mut guard = SESSION.lock().unwrap();
    match guard.as_mut() {
        Some(s) => s.next_chunk(max_frames),
        None => Vec::new(),
    }
}

pub fn stop() {
    *SESSION.lock().unwrap() = None;
}
