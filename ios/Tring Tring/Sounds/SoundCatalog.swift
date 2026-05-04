//
//  SoundCatalog.swift
//  Tring Tring
//

import Foundation

enum SoundCatalog {
    struct Sound: Identifiable, Equatable, Sendable {
        let name: String
        let displayLabel: String
        var id: String { name }
    }

    static let all: [Sound] = [
        Sound(name: "default",     displayLabel: "Default"),
        Sound(name: "vibrateOnly", displayLabel: "Vibrate only"),
        Sound(name: "system",      displayLabel: "System"),
        Sound(name: "subtle",      displayLabel: "Subtle"),
        Sound(name: "question",    displayLabel: "Question"),
        Sound(name: "jobDone",     displayLabel: "Job done"),
        Sound(name: "problem",     displayLabel: "Problem"),
        Sound(name: "loud",        displayLabel: "Loud"),
        Sound(name: "lasers",      displayLabel: "Lasers"),
    ]

    static func displayLabel(for name: String?) -> String {
        guard let name, let match = all.first(where: { $0.name == name }) else {
            return all.first?.displayLabel ?? "Default"
        }
        return match.displayLabel
    }
}
