//! Pure chiptune synthesis core (no FFI, no I/O).

pub mod engine;
pub mod model;
pub mod sampler;
pub mod song;
pub mod stream;

#[cfg(test)]
mod tests {
    use super::engine::render;
    use super::model::*;

    fn demo() -> Composition {
        Composition {
            title: "test".into(),
            bpm: 120.0,
            sample_rate: 44_100,
            master_volume: 0.9,
            delay_wet: 0.0,
            tracks: vec![Track {
                name: "lead".into(),
                waveform: Waveform::Square,
                duty: 0.5,
                volume: 0.8,
                pan: 0.0,
                envelope: Envelope::default(),
                glide: 0.0, cutoff: 1.0, resonance: 0.0, filter_env: 0.0,
                drive: 0.0,
                tone: 0.5,
                crush: 0.0,
                trem: 0.0,
                sample: None,
                notes: vec![
                    Note { pitch: 60, start: 0.0, duration: 1.0, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                    Note { pitch: -1, start: 1.0, duration: 1.0, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                    Note { pitch: 67, start: 2.0, duration: 1.0, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                ],
            }],
        }
    }

    #[test]
    fn renders_non_empty_audio() {
        let audio = render(&demo());
        assert_eq!(audio.sample_rate, 44_100);
        assert!(!audio.samples.is_empty());
        // Roughly 3 beats at 120bpm == 1.5s plus release tail.
        assert!(audio.samples.len() > 44_100);
    }

    #[test]
    fn pcm_is_16bit_aligned() {
        let audio = render(&demo());
        let pcm = audio.to_pcm16_le();
        assert_eq!(pcm.len() % 2, 0);
    }

    #[test]
    fn wav_has_riff_header() {
        let audio = render(&demo());
        let wav = audio.to_wav();
        assert_eq!(&wav[0..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
    }

    #[test]
    fn mp3_has_valid_frame_sync() {
        let audio = render(&demo());
        let mp3 = audio.to_mp3(320).expect("encode mp3");
        assert!(mp3.len() > 256, "mp3 should not be empty");
        // An MP3 frame/ID3 tag starts with either "ID3" or a 0xFF frame sync.
        let starts_id3 = &mp3[0..3] == b"ID3";
        let starts_sync = mp3[0] == 0xFF && (mp3[1] & 0xE0) == 0xE0;
        assert!(starts_id3 || starts_sync, "unexpected MP3 header: {:?}", &mp3[0..4]);
    }

    #[test]
    fn mastering_output_is_finite_controlled_and_audible() {
        let audio = render(&demo());
        let mut peak = 0.0f32;
        let mut sumsq = 0.0f64;
        for &s in &audio.samples {
            assert!(s.is_finite(), "sample must be finite");
            peak = peak.max(s.abs());
            sumsq += (s as f64) * (s as f64);
        }
        let rms = (sumsq / audio.samples.len() as f64).sqrt();
        // Limiter keeps us under the ceiling (+ soft-clip safety), never clipping.
        assert!(peak <= 1.0, "peak {peak} exceeded full scale");
        assert!(peak > 0.2, "output should be audibly loud, peak {peak}");
        assert!(rms > 0.01, "output should not be near-silent, rms {rms}");
    }

    #[test]
    fn driven_ringing_noise_stays_finite_and_bounded() {
        // A noise voice with full ring + heavy drive must not blow up / NaN.
        let comp = Composition {
            title: "fx".into(),
            bpm: 120.0,
            sample_rate: 44_100,
            master_volume: 0.9,
            delay_wet: 0.5,
            tracks: vec![
                Track {
                    name: "drums".into(),
                    waveform: Waveform::Noise,
                    duty: 0.5,
                    volume: 0.7,
                    pan: 0.0,
                    envelope: Envelope::default(),
                    glide: 0.0, cutoff: 1.0, resonance: 0.0, filter_env: 0.0,
                    drive: 1.0,
                    tone: 1.0,
                    crush: 0.8,
                    trem: 0.7,
                    sample: None,
                    notes: vec![
                        Note { pitch: 38, start: 0.0, duration: 0.2, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                        Note { pitch: 42, start: 1.0, duration: 0.2, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                    ],
                },
                Track {
                    name: "lead".into(),
                    waveform: Waveform::Sawtooth,
                    duty: 0.5,
                    volume: 0.8,
                    pan: 0.0,
                    envelope: Envelope::default(),
                    glide: 0.05, cutoff: 1.0, resonance: 0.0, filter_env: 0.0,
                    drive: 0.9,
                    tone: 0.5,
                    crush: 0.5,
                    trem: 0.4,
                    sample: None,
                    notes: vec![
                        Note { pitch: 60, start: 0.0, duration: 1.0, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                        Note { pitch: 64, start: 1.0, duration: 1.0, velocity: 1.0, arp: vec![], slide: 0.0, vib: 0.0, retrig: 0, delay: 0.0 },
                    ],
                },
            ],
        };
        let audio = render(&comp);
        let mut peak = 0.0f32;
        for &s in &audio.samples {
            assert!(s.is_finite(), "fx sample must be finite");
            peak = peak.max(s.abs());
        }
        assert!(peak <= 1.0, "fx peak {peak} exceeded full scale");
    }

    #[test]
    fn hardware_arpeggio_expands_into_subnotes() {
        // A single arp note should render as many rapid sub-notes (chord on one
        // channel) and stay finite/bounded.
        let comp = Composition {
            title: "arp".into(),
            bpm: 120.0,
            sample_rate: 44_100,
            master_volume: 0.9,
            delay_wet: 0.0,
            tracks: vec![Track {
                name: "lead".into(),
                waveform: Waveform::Pulse,
                duty: 0.5,
                volume: 0.8,
                pan: 0.0,
                envelope: Envelope::default(),
                glide: 0.0, cutoff: 1.0, resonance: 0.0, filter_env: 0.0,
                drive: 0.0,
                tone: 0.5,
                crush: 0.0,
                trem: 0.0,
                sample: None,
                notes: vec![Note {
                    pitch: 60,
                    start: 0.0,
                    duration: 2.0,
                    velocity: 1.0,
                    arp: vec![4, 7],
                    slide: 0.0,
                    vib: 0.0,
                    retrig: 0,
                    delay: 0.0,
                }],
            }],
        };
        let audio = render(&comp);
        assert!(audio.samples.iter().all(|s| s.is_finite()));
        let peak = audio.samples.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
        assert!(peak > 0.1 && peak <= 1.0, "arp peak {peak}");
    }

    #[test]
    fn resonant_filter_sweep_stays_finite() {
        let comp = Composition {
            title: "filt".into(),
            bpm: 120.0,
            sample_rate: 44_100,
            master_volume: 0.9,
            delay_wet: 0.0,
            tracks: vec![Track {
                name: "lead".into(),
                waveform: Waveform::Sawtooth,
                duty: 0.5,
                volume: 0.8,
                pan: 0.0,
                envelope: Envelope::default(),
                glide: 0.0,
                cutoff: 0.3,
                resonance: 0.9,
                filter_env: 1.0,
                drive: 0.5,
                tone: 0.5,
                crush: 0.0,
                trem: 0.0,
                sample: None,
                notes: vec![Note {
                    pitch: 50,
                    start: 0.0,
                    duration: 2.0,
                    velocity: 1.0,
                    arp: vec![],
                    slide: 0.0,
                    vib: 0.0,
                    retrig: 0,
                    delay: 0.0,
                }],
            }],
        };
        let audio = render(&comp);
        let mut peak = 0.0f32;
        for &s in &audio.samples {
            assert!(s.is_finite(), "filter sample must be finite");
            peak = peak.max(s.abs());
        }
        assert!(peak <= 1.0, "filter peak {peak}");
    }

    #[test]
    fn parses_json_contract() {
        let json = r#"{
            "title": "json",
            "bpm": 100,
            "tracks": [
                {"waveform":"triangle","notes":[{"pitch":64,"start":0,"duration":2}]}
            ]
        }"#;
        let comp: Composition = serde_json::from_str(json).unwrap();
        assert_eq!(comp.tracks.len(), 1);
        let audio = render(&comp);
        assert!(!audio.samples.is_empty());
    }

    #[test]
    fn song_expands_and_loops_to_target_duration() {
        use crate::synth::song::{expand, Song};
        let json = r#"{
            "title": "Loop Test",
            "bpm": 120,
            "instruments": [
                {"id":"lead","waveform":"pulse","duty":0.5},
                {"id":"bass","waveform":"triangle"}
            ],
            "patterns": [
                {"id":"A","length_beats":4,"tracks":[
                    {"instrument":"lead","notes":[{"pitch":72,"start":0,"duration":1}]},
                    {"instrument":"bass","notes":[{"pitch":48,"start":0,"duration":2}]}
                ]}
            ],
            "arrangement": ["A"]
        }"#;
        let song: Song = serde_json::from_str(json).unwrap();
        // 30s at 120bpm (2 beats/s) -> ~60 beats -> ~15 loops of the 4-beat pattern.
        let comp = expand(&song, 30.0);
        assert_eq!(comp.tracks.len(), 2);
        let lead_notes = comp.tracks[0].notes.len();
        assert!(lead_notes > 10, "expected looped notes, got {lead_notes}");
        let audio = render(&comp);
        // ~30s of audio at 44.1k.
        assert!(audio.samples.len() > 44_100 * 25);
    }
}
