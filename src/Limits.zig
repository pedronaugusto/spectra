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
/// The most memory one `Cache` holds, every engine's within it: what each search of the
/// pattern keeps, sized once to the automaton (the PikeVM's thread sets and their capture
/// slots). The slot tables grow as states times groups, so it is many groups in a long pattern
/// that reach it: 300 groups one after another (`(a)(a)...`) fit the default and 500 do not.
cache: aegis.units.Bytes(usize) = .literal("32MiB"),
/// The largest dense DFA built ahead.
dense_dfa: aegis.units.Bytes(usize) = .literal("2MiB"),
