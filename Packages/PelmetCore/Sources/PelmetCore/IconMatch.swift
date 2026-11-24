// IconMatch.swift
// Which icon a link or a Shortcuts action means by the text it was given
// (#169): the id Get Menu Bar Layout prints, else the name Settings shows,
// else a name containing the text, else an id containing it ("tailscale"
// finds bundle:io.tailscale.ipn.macsys). Only the best tier comes back, so
// "Wi-Fi" never also returns "Wi-Fi Signal".

import Foundation

public enum IconMatch {
    public struct Candidate: Equatable, Sendable {
        public let name: String
        public let id: String

        public init(name: String, id: String) {
            self.name = name
            self.id = id
        }
    }

    public static func matches(_ text: String, in candidates: [Candidate]) -> [Candidate] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let loose: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let tiers: [(Candidate) -> Bool] = [
            { $0.id == text },
            { $0.name.compare(text, options: loose) == .orderedSame },
            { $0.name.range(of: text, options: loose) != nil },
            { $0.id.range(of: text, options: .caseInsensitive) != nil },
        ]
        for tier in tiers {
            let found = candidates.filter(tier)
            if !found.isEmpty { return found }
        }
        return []
    }
}
