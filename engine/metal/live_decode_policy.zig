const std = @import("std");

pub fn autoLanguage(held: u32, winner: u32, margin: f32, switch_margin: f32) u32 {
    return if (held == 0 or (std.math.isFinite(margin) and margin >= switch_margin)) winner else held;
}

// Language logits can be confident on an ambiguous opening. Confirm the
// proposed session language only after the same decode quality floor used by
// the rescue path is met. An empty/dropped decode supplies no confirmation.
pub fn canLockLanguage(dropped: bool, text_tokens: usize, text_bytes: usize, avg_logprob: f32, minimum: f32) bool {
    return !dropped and text_tokens > 0 and text_bytes > 0 and
        std.math.isFinite(avg_logprob) and std.math.isFinite(minimum) and avg_logprob >= minimum;
}

// BPE tokens split Unicode scalars. Interim output may end halfway through a
// Korean syllable or emoji; withhold only that suffix until the next token.
// Invalid interior bytes are not a renderable hypothesis.
pub fn completeUtf8Prefix(text: []const u8) []const u8 {
    var omitted: usize = 0;
    while (omitted <= 3 and omitted <= text.len) : (omitted += 1) {
        const prefix = text[0 .. text.len - omitted];
        if (std.unicode.utf8ValidateSlice(prefix)) return prefix;
    }
    return "";
}

test "a weak opening cannot fix the session language before credible speech" {
    // Measured opening: Arabic probe margin 2.31, failed decode -1.508.
    // The following recorded speech detects Korean and decodes at -0.500.
    try std.testing.expect(!canLockLanguage(false, 5, 20, -1.508, -1.0));
    try std.testing.expect(canLockLanguage(false, 14, 42, -0.500, -1.0));
    try std.testing.expect(canLockLanguage(false, 22, 100, -0.049, -1.0));
    try std.testing.expect(canLockLanguage(false, 1, 1, -1.0, -1.0));
    try std.testing.expect(!canLockLanguage(false, 1, 1, -1.001, -1.0));
    try std.testing.expect(!canLockLanguage(true, 5, 20, -0.1, -1.0));
    try std.testing.expect(!canLockLanguage(false, 0, 20, 0, -1.0));
    try std.testing.expect(!canLockLanguage(false, 5, 0, 0, -1.0));
    try std.testing.expect(!canLockLanguage(false, 5, 20, std.math.nan(f32), -1.0));
}

test "auto language follows clear speech changes but holds through ambiguity" {
    try std.testing.expectEqual(@as(u32, 50272), autoLanguage(0, 50272, 2.31, 1.0));
    try std.testing.expectEqual(@as(u32, 50259), autoLanguage(50272, 50259, 4.24, 1.0));
    try std.testing.expectEqual(@as(u32, 50264), autoLanguage(50259, 50264, 5.69, 1.0));
    try std.testing.expectEqual(@as(u32, 50264), autoLanguage(50264, 50259, 0.99, 1.0));
    try std.testing.expectEqual(@as(u32, 50264), autoLanguage(50264, 50259, std.math.nan(f32), 1.0));
}

test "every BPE byte prefix emits complete Korean Chinese and emoji scalars" {
    const text = "한글 中文 🙂 test";
    for (0..text.len + 1) |end| {
        const prefix = completeUtf8Prefix(text[0..end]);
        try std.testing.expect(std.unicode.utf8ValidateSlice(prefix));
        try std.testing.expect(std.mem.startsWith(u8, text, prefix));
        try std.testing.expect(end - prefix.len <= 3);
        if (std.unicode.utf8ValidateSlice(text[0..end])) {
            try std.testing.expectEqualStrings(text[0..end], prefix);
        }
    }
    try std.testing.expectEqualStrings("", completeUtf8Prefix("bad\xffinterior"));
}
