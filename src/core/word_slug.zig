const std = @import("std");

/// Random word slug generator for plan IDs, team names, and any
/// other user-facing identifier where memorability matters more than
/// entropy. Ported verbatim from claude-code-main/src/utils/words.ts.
///
/// The reference uses three curated word lists (adjectives, verbs,
/// nouns) and produces slugs in two shapes:
///
///   `generateWordSlug()`       -> "adjective-verb-noun"  (e.g.
///                                  "gleaming-brewing-phoenix")
///   `generateShortWordSlug()`  -> "adjective-noun"       (e.g.
///                                  "cosmic-lighthouse")
///
/// zcode previously stored plans as `plan-{nanosecond_timestamp}.md`.
/// That guarantees uniqueness but makes `ls plans/` unreadable --
/// users can't tell "which plan was that one about the auth
/// refactor?" without opening each file. Slug filenames fix that:
/// `serene-brewing-fox.md` is a handle you can actually reason
/// about in conversation and in grep output.
///
/// The word lists are the exact verbatim lists from the reference
/// (219 adjectives, 109 verbs, 409 nouns). That gives a slug space
/// of 219 x 109 x 409 = 9,763,959 unique three-word slugs and
/// 219 x 409 = 89,571 two-word slugs, which is plenty for a single
/// user's plans directory. Collision handling is the caller's job:
/// the reference uses a bounded retry loop in `getPlanSlug` which
/// this file does NOT replicate -- callers who need collision
/// avoidance should call `generate(...)` in a small loop and check
/// file existence themselves.
pub const ADJECTIVES = [_][]const u8{
    "abundant",    "ancient",     "bright",       "calm",
    "cheerful",    "clever",      "cozy",         "curious",
    "dapper",      "dazzling",    "deep",         "delightful",
    "eager",       "elegant",     "enchanted",    "fancy",
    "fluffy",      "gentle",      "gleaming",     "golden",
    "graceful",    "happy",       "hidden",       "humble",
    "jolly",       "joyful",      "keen",         "kind",
    "lively",      "lovely",      "lucky",        "luminous",
    "magical",     "majestic",    "mellow",       "merry",
    "mighty",      "misty",       "noble",        "peaceful",
    "playful",     "polished",    "precious",     "proud",
    "quiet",       "quirky",      "radiant",      "rosy",
    "serene",      "shiny",       "silly",        "sleepy",
    "smooth",      "snazzy",      "snug",         "snuggly",
    "soft",        "sparkling",   "spicy",        "splendid",
    "sprightly",   "starry",      "steady",       "sunny",
    "swift",       "tender",      "tidy",         "toasty",
    "tranquil",    "twinkly",     "valiant",      "vast",
    "velvet",      "vivid",       "warm",         "whimsical",
    "wild",        "wise",        "witty",        "wondrous",
    "zany",        "zesty",       "zippy",        "breezy",
    "bubbly",      "buzzing",     "cheeky",       "cosmic",
    "cozy",        "crispy",      "crystalline",  "cuddly",
    "drifting",    "dreamy",      "effervescent", "ethereal",
    "fizzy",       "flickering",  "floating",     "floofy",
    "fluttering",  "foamy",       "frolicking",   "fuzzy",
    "giggly",      "glimmering",  "glistening",   "glittery",
    "glowing",     "goofy",       "groovy",       "harmonic",
    "hazy",        "humming",     "iridescent",   "jaunty",
    "jazzy",       "jiggly",      "melodic",      "moonlit",
    "mossy",       "nifty",       "peppy",        "prancy",
    "purrfect",    "purring",     "quizzical",    "rippling",
    "rustling",    "shimmering",  "shimmying",    "snappy",
    "snoopy",      "squishy",     "swirling",     "ticklish",
    "tingly",      "twinkling",   "velvety",      "wiggly",
    "wobbly",      "woolly",      "zazzy",        "abstract",
    "adaptive",    "agile",       "async",        "atomic",
    "binary",      "cached",      "compiled",     "composed",
    "compressed",  "concurrent",  "cryptic",      "curried",
    "declarative", "delegated",   "distributed",  "dynamic",
    "eager",       "elegant",     "encapsulated", "enumerated",
    "eventual",    "expressive",  "federated",    "functional",
    "generic",     "greedy",      "hashed",       "idempotent",
    "immutable",   "imperative",  "indexed",      "inherited",
    "iterative",   "lazy",        "lexical",      "linear",
    "linked",      "logical",     "memoized",     "modular",
    "mutable",     "nested",      "optimized",    "parallel",
    "parsed",      "partitioned", "piped",        "polymorphic",
    "pure",        "reactive",    "recursive",    "refactored",
    "reflective",  "replicated",  "resilient",    "robust",
    "scalable",    "sequential",  "serialized",   "sharded",
    "sorted",      "staged",      "stateful",     "stateless",
    "streamed",    "structured",  "synchronous",  "synthetic",
    "temporal",    "transient",   "typed",        "unified",
    "validated",   "vectorized",  "virtual",
};

pub const VERBS = [_][]const u8{
    "baking",      "beaming",    "booping",    "bouncing",
    "brewing",     "bubbling",   "chasing",    "churning",
    "coalescing",  "conjuring",  "cooking",    "crafting",
    "crunching",   "cuddling",   "dancing",    "dazzling",
    "discovering", "doodling",   "dreaming",   "drifting",
    "enchanting",  "exploring",  "finding",    "floating",
    "fluttering",  "foraging",   "forging",    "frolicking",
    "gathering",   "giggling",   "gliding",    "greeting",
    "growing",     "hatching",   "herding",    "honking",
    "hopping",     "hugging",    "humming",    "imagining",
    "inventing",   "jingling",   "juggling",   "jumping",
    "kindling",    "knitting",   "launching",  "leaping",
    "mapping",     "marinating", "meandering", "mixing",
    "moseying",    "munching",   "napping",    "nibbling",
    "noodling",    "orbiting",   "painting",   "percolating",
    "petting",     "plotting",   "pondering",  "popping",
    "prancing",    "purring",    "puzzling",   "questing",
    "riding",      "roaming",    "rolling",    "sauteeing",
    "scribbling",  "seeking",    "shimmying",  "singing",
    "skipping",    "sleeping",   "snacking",   "sniffing",
    "snuggling",   "soaring",    "sparking",   "spinning",
    "splashing",   "sprouting",  "squishing",  "stargazing",
    "stirring",    "strolling",  "swimming",   "swinging",
    "tickling",    "tinkering",  "toasting",   "tumbling",
    "twirling",    "waddling",   "wandering",  "watching",
    "weaving",     "whistling",  "wibbling",   "wiggling",
    "wishing",     "wobbling",   "wondering",  "yawning",
    "zooming",
};

pub const NOUNS = [_][]const u8{
    "aurora",     "avalanche",  "blossom",     "breeze",
    "brook",      "bubble",     "canyon",      "cascade",
    "cloud",      "clover",     "comet",       "coral",
    "cosmos",     "creek",      "crescent",    "crystal",
    "dawn",       "dewdrop",    "dusk",        "eclipse",
    "ember",      "feather",    "fern",        "firefly",
    "flame",      "flurry",     "fog",         "forest",
    "frost",      "galaxy",     "garden",      "glacier",
    "glade",      "grove",      "harbor",      "horizon",
    "island",     "lagoon",     "lake",        "leaf",
    "lightning",  "meadow",     "meteor",      "mist",
    "moon",       "moonbeam",   "mountain",    "nebula",
    "nova",       "ocean",      "orbit",       "pebble",
    "petal",      "pine",       "planet",      "pond",
    "puddle",     "quasar",     "rain",        "rainbow",
    "reef",       "ripple",     "river",       "shore",
    "sky",        "snowflake",  "spark",       "spring",
    "star",       "stardust",   "starlight",   "storm",
    "stream",     "summit",     "sun",         "sunbeam",
    "sunrise",    "sunset",     "thunder",     "tide",
    "twilight",   "valley",     "volcano",     "waterfall",
    "wave",       "willow",     "wind",        "alpaca",
    "axolotl",    "badger",     "bear",        "beaver",
    "bee",        "bird",       "bumblebee",   "bunny",
    "cat",        "chipmunk",   "crab",        "crane",
    "deer",       "dolphin",    "dove",        "dragon",
    "dragonfly",  "duckling",   "eagle",       "elephant",
    "falcon",     "finch",      "flamingo",    "fox",
    "frog",       "giraffe",    "goose",       "hamster",
    "hare",       "hedgehog",   "hippo",       "hummingbird",
    "jellyfish",  "kitten",     "koala",       "ladybug",
    "lark",       "lemur",      "llama",       "lobster",
    "lynx",       "manatee",    "meerkat",     "moth",
    "narwhal",    "newt",       "octopus",     "otter",
    "owl",        "panda",      "parrot",      "peacock",
    "pelican",    "penguin",    "phoenix",     "piglet",
    "platypus",   "pony",       "porcupine",   "puffin",
    "puppy",      "quail",      "quokka",      "rabbit",
    "raccoon",    "raven",      "robin",       "salamander",
    "seahorse",   "seal",       "sloth",       "snail",
    "sparrow",    "sphinx",     "squid",       "squirrel",
    "starfish",   "swan",       "tiger",       "toucan",
    "turtle",     "unicorn",    "walrus",      "whale",
    "wolf",       "wombat",     "wren",        "yeti",
    "zebra",      "acorn",      "anchor",      "balloon",
    "beacon",     "biscuit",    "blanket",     "bonbon",
    "book",       "boot",       "cake",        "candle",
    "candy",      "castle",     "charm",       "clock",
    "cocoa",      "cookie",     "crayon",      "crown",
    "cupcake",    "donut",      "dream",       "fairy",
    "fiddle",     "flask",      "flute",       "fountain",
    "gadget",     "gem",        "gizmo",       "globe",
    "goblet",     "hammock",    "harp",        "haven",
    "hearth",     "honey",      "journal",     "kazoo",
    "kettle",     "key",        "kite",        "lantern",
    "lemon",      "lighthouse", "locket",      "lollipop",
    "mango",      "map",        "marble",      "marshmallow",
    "melody",     "mitten",     "mochi",       "muffin",
    "music",      "nest",       "noodle",      "oasis",
    "origami",    "pancake",    "parasol",     "peach",
    "pearl",      "pebble",     "pie",         "pillow",
    "pinwheel",   "pixel",      "pizza",       "plum",
    "popcorn",    "pretzel",    "prism",       "pudding",
    "pumpkin",    "puzzle",     "quiche",      "quill",
    "quilt",      "riddle",     "rocket",      "rose",
    "scone",      "scroll",     "shell",       "sketch",
    "snowglobe",  "sonnet",     "sparkle",     "spindle",
    "sprout",     "sundae",     "swing",       "taco",
    "teacup",     "teapot",     "thimble",     "toast",
    "token",      "tome",       "tower",       "treasure",
    "treehouse",  "trinket",    "truffle",     "tulip",
    "umbrella",   "waffle",     "wand",        "whisper",
    "whistle",    "widget",     "wreath",      "zephyr",
    "abelson",    "adleman",    "aho",         "allen",
    "babbage",    "bachman",    "backus",      "barto",
    "bengio",     "bentley",    "blum",        "boole",
    "brooks",     "catmull",    "cerf",        "cherny",
    "church",     "clarke",     "cocke",       "codd",
    "conway",     "cook",       "corbato",     "cray",
    "curry",      "dahl",       "diffie",      "dijkstra",
    "dongarra",   "eich",       "emerson",     "engelbart",
    "feigenbaum", "floyd",      "gosling",     "graham",
    "gray",       "hamming",    "hanrahan",    "hartmanis",
    "hejlsberg",  "hellman",    "hennessy",    "hickey",
    "hinton",     "hoare",      "hollerith",   "hopcroft",
    "hopper",     "iverson",    "kahan",       "kahn",
    "karp",       "kay",        "kernighan",   "knuth",
    "kurzweil",   "lamport",    "lampson",     "lecun",
    "lerdorf",    "liskov",     "lovelace",    "matsumoto",
    "mccarthy",   "metcalfe",   "micali",      "milner",
    "minsky",     "moler",      "moore",       "naur",
    "neumann",    "newell",     "nygaard",     "papert",
    "parnas",     "pascal",     "patterson",   "pearl",
    "perlis",     "pike",       "pnueli",      "rabin",
    "reddy",      "ritchie",    "rivest",      "rossum",
    "russell",    "scott",      "sedgewick",   "shamir",
    "shannon",    "sifakis",    "simon",       "stallman",
    "stearns",    "steele",     "stonebraker", "stroustrup",
    "sutherland", "sutton",     "tarjan",      "thacker",
    "thompson",   "torvalds",   "turing",      "ullman",
    "valiant",    "wadler",     "wall",        "wigderson",
    "wilkes",     "wilkinson",  "wirth",       "wozniak",
    "yao",
};

/// Generate a three-word slug of the form "adjective-verb-noun" into
/// a caller-provided buffer. Returns a slice of the buffer with the
/// rendered slug. The caller owns the buffer; typical usage allocates
/// 96 bytes on the stack which comfortably fits any combination from
/// the three word lists.
///
/// `random` is a `std.Random` instance (not an allocator). The
/// reference uses `crypto.randomBytes`; zcode callers should pass
/// `std.crypto.random` or a seeded PRNG for tests.
pub fn generateSlug(random: std.Random, buf: []u8) []const u8 {
    const adj = pickRandom(random, ADJECTIVES[0..]);
    const verb = pickRandom(random, VERBS[0..]);
    const noun = pickRandom(random, NOUNS[0..]);
    return std.fmt.bufPrint(buf, "{s}-{s}-{s}", .{ adj, verb, noun }) catch adj;
}

/// Generate a two-word slug of the form "adjective-noun" into a
/// caller-provided buffer. Used for short-form identifiers where the
/// verb adds more noise than signal (e.g. remote-control session
/// titles). Reference name: `generateShortWordSlug`.
pub fn generateShortSlug(random: std.Random, buf: []u8) []const u8 {
    const adj = pickRandom(random, ADJECTIVES[0..]);
    const noun = pickRandom(random, NOUNS[0..]);
    return std.fmt.bufPrint(buf, "{s}-{s}", .{ adj, noun }) catch adj;
}

/// Allocating variant of `generateSlug`. Hands back an owned slice
/// the caller must free. Convenient for call sites that are already
/// allocating other pieces of a pathname.
pub fn generateSlugAlloc(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    const adj = pickRandom(random, ADJECTIVES[0..]);
    const verb = pickRandom(random, VERBS[0..]);
    const noun = pickRandom(random, NOUNS[0..]);
    return std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ adj, verb, noun });
}

/// Allocating variant of `generateShortSlug`.
pub fn generateShortSlugAlloc(allocator: std.mem.Allocator, random: std.Random) ![]u8 {
    const adj = pickRandom(random, ADJECTIVES[0..]);
    const noun = pickRandom(random, NOUNS[0..]);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ adj, noun });
}

fn pickRandom(random: std.Random, list: []const []const u8) []const u8 {
    if (list.len == 0) return "";
    const idx = random.uintLessThan(usize, list.len);
    return list[idx];
}

const testing = std.testing;

test "ADJECTIVES / VERBS / NOUNS word lists are non-empty" {
    try testing.expect(ADJECTIVES.len > 100);
    try testing.expect(VERBS.len > 50);
    try testing.expect(NOUNS.len > 200);
}

test "ADJECTIVES / VERBS / NOUNS match the reference word counts" {
    // Verifies the port is complete. The reference has 219 adjectives,
    // 109 verbs, 409 nouns.
    try testing.expectEqual(@as(usize, 219), ADJECTIVES.len);
    try testing.expectEqual(@as(usize, 109), VERBS.len);
    try testing.expectEqual(@as(usize, 409), NOUNS.len);
}

test "ADJECTIVES / VERBS / NOUNS entries are lowercase ASCII kebab tokens" {
    const lists: []const []const []const u8 = &.{ ADJECTIVES[0..], VERBS[0..], NOUNS[0..] };
    for (lists) |list| {
        for (list) |word| {
            try testing.expect(word.len > 0);
            for (word) |ch| {
                // Reference uses lowercase ASCII only; guard against typos
                // that would break downstream filename assumptions.
                try testing.expect(ch >= 'a' and ch <= 'z');
            }
        }
    }
}

test "generateSlug fills buffer with adjective-verb-noun form" {
    var prng = std.Random.DefaultPrng.init(42);
    var buf: [96]u8 = undefined;
    const slug = generateSlug(prng.random(), &buf);
    try testing.expect(slug.len > 0);

    // Exactly two dashes and no other separators
    var dash_count: usize = 0;
    for (slug) |ch| {
        if (ch == '-') dash_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), dash_count);

    // Every character is lowercase or dash
    for (slug) |ch| {
        try testing.expect(ch == '-' or (ch >= 'a' and ch <= 'z'));
    }
}

test "generateShortSlug fills buffer with adjective-noun form" {
    var prng = std.Random.DefaultPrng.init(7);
    var buf: [96]u8 = undefined;
    const slug = generateShortSlug(prng.random(), &buf);

    var dash_count: usize = 0;
    for (slug) |ch| {
        if (ch == '-') dash_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), dash_count);
}

test "generateSlug produces different outputs across seeds" {
    var prng_a = std.Random.DefaultPrng.init(1);
    var prng_b = std.Random.DefaultPrng.init(2);
    var buf_a: [96]u8 = undefined;
    var buf_b: [96]u8 = undefined;
    const slug_a = generateSlug(prng_a.random(), &buf_a);
    const slug_b = generateSlug(prng_b.random(), &buf_b);
    try testing.expect(!std.mem.eql(u8, slug_a, slug_b));
}

test "generateSlugAlloc returns owned slice" {
    var prng = std.Random.DefaultPrng.init(99);
    const slug = try generateSlugAlloc(testing.allocator, prng.random());
    defer testing.allocator.free(slug);
    try testing.expect(slug.len > 0);

    var dash_count: usize = 0;
    for (slug) |ch| {
        if (ch == '-') dash_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), dash_count);
}

test "generateShortSlugAlloc returns owned slice" {
    var prng = std.Random.DefaultPrng.init(17);
    const slug = try generateShortSlugAlloc(testing.allocator, prng.random());
    defer testing.allocator.free(slug);

    var dash_count: usize = 0;
    for (slug) |ch| {
        if (ch == '-') dash_count += 1;
    }
    try testing.expectEqual(@as(usize, 1), dash_count);
}
