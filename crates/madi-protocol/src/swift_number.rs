//! Swift Double accepts C-style hexadecimal floats and numeric NaN payloads.
//! This small compatibility boundary keeps locale out of the engine protocol.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum FloatSyntax {
    #[default]
    CurrentSwift,
    LegacySwift,
}

pub(crate) fn double_with_syntax(text: &str, syntax: FloatSyntax) -> Option<f64> {
    if let Ok(value) = text.parse() {
        return Some(value);
    }
    let (negative, unsigned) = if let Some(rest) = text.strip_prefix('-') {
        (true, rest)
    } else {
        (false, text.strip_prefix('+').unwrap_or(text))
    };
    let sign = if negative { 1_u64 << 63 } else { 0 };
    if let Some(payload) = unsigned
        .strip_prefix("nan(")
        .and_then(|s| s.strip_suffix(')'))
    {
        let (digits, radix) = payload
            .strip_prefix("0x")
            .map(|s| (s, 16))
            .unwrap_or((payload, 10));
        if !digits.bytes().all(|c| {
            if radix == 16 {
                c.is_ascii_hexdigit()
            } else {
                c.is_ascii_digit()
            }
        }) {
            if syntax == FloatSyntax::LegacySwift
                && digits
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b == b'_')
            {
                return Some(f64::from_bits(sign | 0x7ff8_0000_0000_0000));
            }
            return None;
        }
        // Swift's payload parser wraps at UInt64 then masks off the quiet bit.
        let bits = digits.bytes().fold(0_u64, |n, c| {
            n.wrapping_mul(radix)
                .wrapping_add((c as char).to_digit(radix as u32).unwrap() as u64)
        });
        return Some(f64::from_bits(
            sign | 0x7ff8_0000_0000_0000 | (bits & 0x0007_ffff_ffff_ffff),
        ));
    }
    let hex = unsigned.strip_prefix("0x").or_else(|| {
        (syntax == FloatSyntax::LegacySwift)
            .then(|| unsigned.strip_prefix("0X"))
            .flatten()
    })?;
    let (mantissa, exponent) = if let Some(index) = hex.find(['p', 'P']) {
        let exponent = &hex[index + 1..];
        let (minus, digits) = if let Some(rest) = exponent.strip_prefix('-') {
            (true, rest)
        } else {
            (false, exponent.strip_prefix('+').unwrap_or(exponent))
        };
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let n = digits.bytes().fold(0_i64, |n, b| {
            n.saturating_mul(10).saturating_add((b - b'0') as i64)
        });
        (&hex[..index], if minus { -n } else { n })
    } else {
        (hex, 0)
    };
    let mut dots = 0;
    let mut fraction_digits = 0_i64;
    let mut digits = Vec::new();
    for byte in mantissa.bytes() {
        if byte == b'.' {
            dots += 1;
            if dots > 1 {
                return None;
            }
        } else {
            digits.push((byte as char).to_digit(16)? as u8);
            if dots == 1 {
                fraction_digits += 1;
            }
        }
    }
    if digits.is_empty() {
        return None;
    }
    let Some(first) = digits.iter().position(|&d| d != 0) else {
        return Some(f64::from_bits(sign));
    };
    let digits = &digits[first..];
    let kept = digits.len().min(16);
    let significand = digits[..kept]
        .iter()
        .fold(0_u64, |n, &d| (n << 4) | d as u64);
    let sticky = digits[kept..].iter().any(|&d| d != 0);
    let binary_exponent = exponent
        .saturating_sub(fraction_digits.saturating_mul(4))
        .saturating_add(((digits.len() - kept) as i64).saturating_mul(4));
    let bits = (64 - significand.leading_zeros()) as i64;
    let mut unbiased = binary_exponent.saturating_add(bits - 1);
    if unbiased > 1023 {
        return Some(f64::from_bits(sign | 0x7ff0_0000_0000_0000));
    }
    if unbiased < -1022 {
        let shift = -(binary_exponent.saturating_add(1074));
        let rounded = round_shift(significand, shift, sticky);
        return Some(f64::from_bits(sign | rounded));
    }
    let mut rounded = round_shift(significand, bits - 53, sticky);
    if rounded == 1 << 53 {
        rounded >>= 1;
        unbiased += 1;
    }
    if unbiased > 1023 {
        return Some(f64::from_bits(sign | 0x7ff0_0000_0000_0000));
    }
    Some(f64::from_bits(
        sign | (((unbiased + 1023) as u64) << 52) | (rounded & 0x000f_ffff_ffff_ffff),
    ))
}

fn round_shift(value: u64, shift: i64, sticky: bool) -> u64 {
    if shift <= 0 {
        return value << (-shift as u32);
    }
    if shift > 64 {
        return 0;
    }
    let retained = if shift == 64 { 0 } else { value >> shift };
    let half = 1_u64 << (shift - 1);
    let lower = value & (half - 1);
    retained + u64::from(value & half != 0 && (lower != 0 || sticky || retained & 1 != 0))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn double(text: &str) -> Option<f64> {
        double_with_syntax(text, FloatSyntax::CurrentSwift)
    }

    #[test]
    fn legacy_syntax_is_explicit_and_keeps_current_default() {
        assert_eq!(
            double_with_syntax("0X1p2", FloatSyntax::LegacySwift),
            Some(4.0)
        );
        assert_eq!(
            double_with_syntax("nan(foo)", FloatSyntax::LegacySwift)
                .unwrap()
                .to_bits(),
            0x7ff8_0000_0000_0000
        );
        assert_eq!(double("0X1p2"), None);
        assert_eq!(double("nan(foo)"), None);
    }

    #[test]
    fn hex_rounds_half_even_and_preserves_subnormal_boundaries() {
        assert_eq!(double("0x1.00000000000008p0"), Some(1.0));
        assert_eq!(
            double("0x1.00000000000008001p0"),
            Some(f64::from_bits(1.0_f64.to_bits() + 1))
        );
        assert_eq!(double("0x1p-1075"), Some(0.0));
        assert_eq!(double("0x1.1p-1075"), Some(f64::from_bits(1)));
        assert_eq!(
            double("-0x1p-99999").unwrap().to_bits(),
            (-0.0_f64).to_bits()
        );
        assert_eq!(double("0x1.fffffffffffff8p1023"), Some(f64::INFINITY));
    }

    #[test]
    fn payload_and_syntax_match_swift_not_a_locale_dependent_c_parser() {
        assert_eq!(
            double("nan(0x123)").unwrap().to_bits(),
            0x7ff8_0000_0000_0123
        );
        assert_eq!(double("nan(foo)"), None);
        assert_eq!(double("0X1p2"), None);
        assert_eq!(double(" 1.5"), None);
        assert_eq!(double("0x1.2"), Some(1.125));
        assert_eq!(double("+0xAbP2"), Some(684.0));
    }
}
