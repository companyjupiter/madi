//! WavWriter.crop16kMonoPCM and SessionOneShotTranscriber.parse compatibility.
use crate::transcript::whitespace;

#[derive(Debug, PartialEq, Eq)]
pub enum CropError {
    Unsupported,
    Empty,
    InvalidRange,
}

pub fn crop(data: &[u8], start: f64, end: f64, pad: f64) -> Result<Vec<u8>, CropError> {
    if data.len() < 44 {
        return Err(CropError::Unsupported);
    }
    let u16at = |i| u16::from_le_bytes(data[i..i + 2].try_into().unwrap());
    let u32at = |i| u32::from_le_bytes(data[i..i + 4].try_into().unwrap());
    if &data[0..4] != b"RIFF"
        || &data[8..16] != b"WAVEfmt "
        || u16at(20) != 1
        || u16at(22) != 1
        || u32at(24) != 16000
        || u16at(34) != 16
        || &data[36..40] != b"data"
    {
        return Err(CropError::Unsupported);
    }
    let n = (u32at(40) as usize).min(data.len() - 44) / 2;
    let lo = ((start - pad) * 16000.).floor();
    let hi = ((end + pad) * 16000.).ceil();
    // Transcript times are finite. Reject values that trap Swift Int conversion.
    if !lo.is_finite() || !hi.is_finite() {
        return Err(CropError::InvalidRange);
    }
    let lo = lo.clamp(0., n as f64) as usize;
    let hi = (hi.clamp(0., n as f64) as usize).max(lo);
    if hi <= lo {
        return Err(CropError::Empty);
    }
    let bytes = ((hi - lo) * 2) as u32;
    let mut out = Vec::with_capacity(44 + bytes as usize);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&(36 + bytes).to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&16000u32.to_le_bytes());
    out.extend_from_slice(&32000u32.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&bytes.to_le_bytes());
    out.extend_from_slice(&data[44 + lo * 2..44 + hi * 2]);
    Ok(out)
}

pub fn parse_transcription(output: &str) -> Option<String> {
    let mut lines = output.split('\n');
    lines.find(|s| s.starts_with("=== TRANSCRIPTION"))?;
    let mut text = String::new();
    for line in lines {
        if line.starts_with("===") || line.starts_with('[') {
            break;
        }
        let trimmed = line.trim_matches(whitespace);
        if trimmed.is_empty() {
            if text.is_empty() { continue } else { break }
        }
        if !text.is_empty() {
            text.push(' ')
        }
        text.push_str(trimmed);
    }
    Some(text.trim_matches(whitespace).into())
}
