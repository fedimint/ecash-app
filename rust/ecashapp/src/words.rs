pub const ADJECTIVES: &[&str] = &[
    "beautiful",
    "witty",
    "wicked",
    "confusing",
    "rich",
    "new",
    "strange",
    "rocky",
    "circular",
    "helpful",
    "competent",
    "smelly",
    "stable",
    "grumpy",
    "devoted",
    "smart",
    "muscular",
    "graceful",
    "scary",
    "safe",
    "wooden",
    "sleepy",
    "tardy",
    "hungry",
    "hopeful",
    "proud",
    "dainty",
    "royal",
    "arrogant",
    "round",
    "efficient",
    "youthful",
    "cumbersome",
    "fickle",
    "mild",
    "expensive",
    "small",
    "rude",
    "generous",
    "courageous",
    "zany",
    "thin",
    "oval",
    "dark",
    "hot",
    "modern",
    "petite",
    "weary",
];

pub const NOUNS: &[&str] = &[
    "apple",
    "asteroid",
    "beacon",
    "bison",
    "breeze",
    "cactus",
    "cargo",
    "cipher",
    "cloud",
    "comet",
    "crystal",
    "ember",
    "falcon",
    "fjord",
    "flame",
    "fox",
    "galaxy",
    "goblin",
    "granite",
    "griffin",
    "harbor",
    "haven",
    "horizon",
    "hurricane",
    "iceberg",
    "jungle",
    "labyrinth",
    "lantern",
    "lighthouse",
    "lizard",
    "marble",
    "meteor",
    "monolith",
    "mountain",
    "nebula",
    "nexus",
    "oasis",
    "onyx",
    "panther",
    "pebble",
    "phoenix",
    "pirate",
    "planet",
    "pyramid",
    "raven",
    "rift",
    "robot",
    "saber",
    "satellite",
    "whale",
];

#[cfg(test)]
mod tests {
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
}
