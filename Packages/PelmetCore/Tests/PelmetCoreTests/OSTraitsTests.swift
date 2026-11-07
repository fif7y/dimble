// OSTraitsTests.swift
// The asymmetry is the point: a positive is proof and final, a negative
// only lands while nothing has proved otherwise. Behaviour measured on
// macOS 27.3 (26C5035r, 2026-11-06) sets the assumptions.

import Foundation
import Testing
@testable import PelmetCore

struct OSTraitsTests {
    /// Before anything is seen, Dimble acts on the newest measured macOS.
    @Test func assumesTheNewestMeasuredBehaviour() {
        let traits = OSTraits()
        #expect(traits.value(.systemPillSurvivesAssertion) == true)
        #expect(traits.learned(.systemPillSurvivesAssertion) == nil)
    }

    /// 27.2: the assertion took the pill off the bar, so one pass with the
    /// hardware live and no pill found corrects the assumption for good.
    @Test func aNegativeLandsWhileNothingHasProvedOtherwise() {
        var traits = OSTraits()
        let line = traits.learn(.systemPillSurvivesAssertion, false, why: "no pill came")
        #expect(line?.contains("systemPillSurvivesAssertion is false") == true)
        #expect(line?.contains("assumed true") == true)
        #expect(traits.value(.systemPillSurvivesAssertion) == false)
        #expect(traits.learned(.systemPillSurvivesAssertion) == false)
    }

    /// Seeing the pill mirrored is proof, and it outranks an earlier
    /// negative: a pill can be late or ghosted in AX, it cannot be imagined.
    @Test func aPositiveOutranksANegative() {
        var traits = OSTraits()
        _ = traits.learn(.systemPillSurvivesAssertion, false, why: "no pill came")
        let line = traits.learn(.systemPillSurvivesAssertion, true, why: "the pill is mirrored")
        #expect(line != nil)
        #expect(traits.value(.systemPillSurvivesAssertion) == true)
    }

    /// Once proved, a later empty pass cannot take it back.
    @Test func aPositiveIsFinal() {
        var traits = OSTraits()
        _ = traits.learn(.systemPillSurvivesAssertion, true, why: "the pill is mirrored")
        #expect(traits.learn(.systemPillSurvivesAssertion, false, why: "no pill came") == nil)
        #expect(traits.value(.systemPillSurvivesAssertion) == true)
    }

    /// A pinned trait is what the debug default says, whatever the Mac it
    /// runs on observes. This is the only way to reach the other macOS's
    /// path from here.
    @Test func aPinnedTraitDoesNotLearn() {
        var traits = OSTraits()
        traits.pin(.systemPillSurvivesAssertion, false)
        #expect(traits.value(.systemPillSurvivesAssertion) == false)
        #expect(traits.isPinned(.systemPillSurvivesAssertion))
        // Even proof does not move it: the point is to hold the old path.
        #expect(traits.learn(.systemPillSurvivesAssertion, true, why: "the pill is mirrored") == nil)
        #expect(traits.value(.systemPillSurvivesAssertion) == false)
    }

    /// The same answer twice logs once: these fire from a tick.
    @Test func anAnswerThatChangesNothingIsSilent() {
        var traits = OSTraits()
        #expect(traits.learn(.systemPillSurvivesAssertion, false, why: "first") != nil)
        #expect(traits.learn(.systemPillSurvivesAssertion, false, why: "again") == nil)
    }

    /// An answer that matches the assumption is still worth a line, without
    /// the "assumed" aside — it says the measurement happened.
    @Test func aConfirmedAssumptionSaysSoPlainly() {
        var traits = OSTraits()
        let line = traits.learn(.systemPillSurvivesAssertion, true, why: "the pill is mirrored")
        #expect(line?.contains("is true") == true)
        #expect(line?.contains("assumed") == false)
    }
}
