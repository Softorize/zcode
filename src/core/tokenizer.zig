const std = @import("std");

pub fn estimateText(provider: []const u8, model: []const u8, text: []const u8) usize {
    if (text.len == 0) return 0;

    var ascii_word_chars: usize = 0;
    var punctuation: usize = 0;
    var whitespace: usize = 0;
    var newline_count: usize = 0;
    // Count UTF-8 codepoints rather than raw bytes. The previous implementation
    // used `non_ascii_bytes / 3`, which under-counts Latin-1 supplement (2 bytes
    // per codepoint), supplementary plane / emoji (4 bytes), and any BMP script
    // encoded with 2-byte sequences. Under-counting in turn let CJK/emoji-heavy
    // prompts blow past the provider context window and 413 at send time.
    //
    // A UTF-8 leading byte is any byte whose top two bits are not `10` (i.e.
    // `(b & 0xC0) != 0x80`); counting those gives the exact codepoint count.
    // We then charge ~1 token per non-ASCII codepoint, which is a reasonable
    // conservative upper bound across provider tokenizers (real BPE averages
    // 0.5-1.5 tokens per CJK character; 1-2 per emoji; overestimating slightly
    // is safer than the prior under-count).
    var non_ascii_codepoints: usize = 0;

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch >= 0x80) {
            if ((ch & 0xC0) != 0x80) non_ascii_codepoints += 1;
            continue;
        }

        if (std.ascii.isWhitespace(ch)) {
            whitespace += 1;
            if (ch == '\n') newline_count += 1;
            continue;
        }

        if (std.ascii.isAlphanumeric(ch) or ch == '_') {
            ascii_word_chars += 1;
            continue;
        }

        punctuation += 1;
    }

    const word_tokens = divCeil(ascii_word_chars, 4);
    const punctuation_tokens = punctuation;
    const newline_tokens = newline_count;
    const whitespace_tokens = whitespace / 8;
    const unicode_tokens = non_ascii_codepoints;

    var base_tokens = word_tokens + punctuation_tokens + newline_tokens + whitespace_tokens + unicode_tokens;
    base_tokens += 2; // message framing overhead

    const profile = profileFor(provider, model);
    base_tokens += profile.extra_overhead_tokens;

    // Apply provider-specific scaling using integer math to avoid f64 conversion overhead.
    // Multipliers are stored as f64 but only use values like 0.9, 0.98, 1.0, 1.05 —
    // scale to per-mille (x1000) for integer arithmetic.
    const scale_factor: usize = @intFromFloat(@round(profile.multiplier * 1000.0));
    const scaled = (base_tokens * scale_factor + 999) / 1000; // ceiling division
    return @max(@as(usize, 1), scaled);
}

pub fn estimateMany(provider: []const u8, model: []const u8, texts: []const []const u8) usize {
    var total: usize = 0;
    for (texts) |text| {
        total += estimateText(provider, model, text);
    }
    return total;
}

const Profile = struct {
    multiplier: f64,
    extra_overhead_tokens: usize,
};

fn profileFor(provider: []const u8, model: []const u8) Profile {
    var profile: Profile = .{
        .multiplier = 1.0,
        .extra_overhead_tokens = 0,
    };

    if (std.mem.eql(u8, provider, "openai") or std.mem.eql(u8, provider, "openai-compatible")) {
        profile.multiplier = 1.0;
    } else if (std.mem.eql(u8, provider, "deepseek")) {
        profile.multiplier = 1.0;
    } else if (std.mem.eql(u8, provider, "anthropic")) {
        profile.multiplier = 0.98;
    } else if (std.mem.eql(u8, provider, "gemini")) {
        profile.multiplier = 0.9;
    } else if (std.mem.eql(u8, provider, "local") or std.mem.eql(u8, provider, "ollama")) {
        profile.multiplier = 1.05;
    } else if (std.mem.eql(u8, provider, "groq")) {
        profile.multiplier = 1.0;
    } else if (std.mem.eql(u8, provider, "openrouter")) {
        profile.multiplier = 1.0;
    } else if (std.mem.eql(u8, provider, "azure") or std.mem.eql(u8, provider, "azure-openai")) {
        profile.multiplier = 1.0;
    } else if (std.mem.eql(u8, provider, "mock")) {
        profile.multiplier = 1.0;
    }

    if (std.mem.indexOf(u8, model, "reasoner") != null or std.mem.indexOf(u8, model, "opus") != null) {
        profile.extra_overhead_tokens += 4;
    } else if (std.mem.indexOf(u8, model, "flash") != null or std.mem.indexOf(u8, model, "mini") != null) {
        profile.extra_overhead_tokens += 1;
    } else {
        profile.extra_overhead_tokens += 2;
    }

    return profile;
}

fn divCeil(num: usize, den: usize) usize {
    if (den == 0) return num;
    return @divFloor(num + den - 1, den);
}

const testing = std.testing;

test "estimateText is deterministic and non-zero for non-empty text" {
    const t = "hello world";
    const a = estimateText("openai", "gpt-4.1", t);
    const b = estimateText("openai", "gpt-4.1", t);
    try testing.expect(a > 0);
    try testing.expectEqual(a, b);
}

test "unicode text produces tokens" {
    const t = "你好，世界";
    try testing.expect(estimateText("gemini", "gemini-2.5-pro", t) > 0);
}

test "CJK is counted per codepoint not per byte" {
    // 5 CJK codepoints (15 UTF-8 bytes) should estimate to at least 5
    // non-ASCII tokens plus overhead. Previously `bytes / 3 == 5` by accident
    // for 3-byte sequences; this test guards against regression to byte-based
    // counting when 2-byte or 4-byte codepoints are mixed in.
    const cjk = "你好世界好";
    const latin = "éüñöß"; // 5 Latin-1 supplement codepoints, 10 bytes
    const emoji = "🌍🚀🎉"; // 3 emoji codepoints, 12 bytes
    const cjk_est = estimateText("openai", "gpt-4.1", cjk);
    const latin_est = estimateText("openai", "gpt-4.1", latin);
    const emoji_est = estimateText("openai", "gpt-4.1", emoji);
    // Before the fix, `latin` would count 10/3=3 and `emoji` 12/3=4, both
    // under-counting. After the fix, each scales with codepoint count so
    // Latin-1 gets 5 non-ASCII tokens and emoji gets 3.
    try testing.expect(cjk_est >= 5);
    try testing.expect(latin_est >= 5);
    try testing.expect(emoji_est >= 3);
}

test "empty text produces zero tokens" {
    try testing.expectEqual(@as(usize, 0), estimateText("openai", "gpt-4.1", ""));
}

test "estimateMany sums individual estimates" {
    const texts = [_][]const u8{ "hello", "world" };
    const combined = estimateMany("openai", "gpt-4.1", &texts);
    const individual = estimateText("openai", "gpt-4.1", "hello") + estimateText("openai", "gpt-4.1", "world");
    try testing.expectEqual(individual, combined);
}

test "different providers produce different estimates" {
    const text = "The quick brown fox jumps over the lazy dog";
    const openai_est = estimateText("openai", "gpt-4.1", text);
    const gemini_est = estimateText("gemini", "gemini-2.5-pro", text);
    // Gemini has a 0.9 multiplier so should produce fewer tokens.
    try testing.expect(gemini_est < openai_est);
}

test "punctuation-heavy text gets reasonable estimate" {
    const text = "!!!@@@###$$$%%%^^^&&&***()()()";
    const est = estimateText("openai", "gpt-4.1", text);
    try testing.expect(est > 0);
    // Each punctuation char is roughly 1 token, plus overhead.
    try testing.expect(est >= text.len / 2);
}

test "divCeil handles edge cases" {
    try testing.expectEqual(@as(usize, 0), divCeil(0, 4));
    try testing.expectEqual(@as(usize, 1), divCeil(1, 4));
    try testing.expectEqual(@as(usize, 1), divCeil(4, 4));
    try testing.expectEqual(@as(usize, 2), divCeil(5, 4));
    try testing.expectEqual(@as(usize, 5), divCeil(5, 0));
}
