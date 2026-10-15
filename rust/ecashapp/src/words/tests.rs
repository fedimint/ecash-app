use super::*;
use std::collections::HashSet;

fn assert_unique(words: &[&str]) {
    let unique: HashSet<_> = words.iter().collect();
    assert_eq!(unique.len(), words.len(), "word list contains duplicates");
}

#[test]
fn adjectives_are_unique() {
    assert_unique(ADJECTIVES);
}

#[test]
fn nouns_are_unique() {
    assert_unique(NOUNS);
}
