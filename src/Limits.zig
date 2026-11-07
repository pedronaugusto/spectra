//! What a pattern may ask of the compiler, each checked before anything is allocated for it.
const aegis = @import("aegis");

/// The longest pattern.
pattern: aegis.units.Bytes(u32) = .literal("64KiB"),
/// The deepest nesting of groups, and of classes inside classes.
nesting: aegis.int.Ranged(u16, 1, 1024) = .literal(250),
/// The largest bound of a counted repetition (`{n,m}`).
repetition: aegis.int.Ranged(u32, 1, 100_000) = .literal(1000),
/// The largest automaton.
nfa: aegis.units.Bytes(usize) = .literal("10MiB"),
/// The largest dense DFA built ahead.
dense_dfa: aegis.units.Bytes(usize) = .literal("2MiB"),
