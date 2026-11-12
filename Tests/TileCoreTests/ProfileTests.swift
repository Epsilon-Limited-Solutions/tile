import CoreGraphics
import Testing
@testable import TileCore

struct ProfileTests {
    let profiles: [DisplayProfile]

    init() throws {
        profiles = try Fixtures.config(Fixtures.defaultsWithDesk).profiles
    }

    func renamed(_ display: DisplayInfo, _ name: String) -> DisplayInfo {
        Fixtures.display(display.id, name, frame: display.frame, visible: display.visibleFrame,
                         builtin: display.isBuiltin, primary: display.isPrimary,
                         rotation: display.rotation, serial: display.serial)
    }

    @Test func laptopAlone() {
        let match = ProfileMatching.activeProfile(profiles, displays: [Fixtures.laptop])
        #expect(match?.profile.id == "laptop")
        #expect(match?.roles == ["laptop": Fixtures.laptop.id])
    }

    @Test func dockedMatchesDeskWithEachDellBySerial() {
        let match = ProfileMatching.activeProfile(profiles, displays: Fixtures.desk)
        #expect(match?.profile.id == "desk")
        #expect(match?.roles == ["laptop": 1, "vertical-left": 2, "vertical-right": 3])
        #expect(match?.role(of: 3) == "vertical-right")
        #expect(match?.role(of: 99) == nil)
    }

    @Test func dellsKeepTheirRolesWhenMacOSSwapsTheirNumbers() {
        let swapped = [Fixtures.laptop,
                       renamed(Fixtures.verticalLeft, "DELL S2722QC (2)"),
                       renamed(Fixtures.verticalRight, "DELL S2722QC (1)")]
        let match = ProfileMatching.activeProfile(profiles, displays: swapped)
        #expect(match?.roles == ["laptop": 1, "vertical-left": 2, "vertical-right": 3])
    }

    @Test func displayCountsMustBeEqual() {
        // Laptop plus one Dell: neither the one-display nor the three-display profile.
        #expect(ProfileMatching.activeProfile(profiles, displays: [Fixtures.laptop, Fixtures.verticalLeft]) == nil)
    }

    @Test func unknownMonitorMatchesNothing() {
        let stranger = Fixtures.display(9, "DELL S2722QC", frame: Fixtures.verticalRight.frame, serial: 12345)
        #expect(ProfileMatching.activeProfile(profiles, displays: [Fixtures.laptop, Fixtures.verticalLeft, stranger]) == nil)
    }

    @Test func firstMatchingProfileWins() throws {
        let config = try Fixtures.config("""
        { "profiles": [
            { "id": "any-two", "displays": { "main": { "builtin": true }, "other": { "builtin": false } } },
            { "id": "dell", "displays": { "main": { "builtin": true }, "dell": { "name": "DELL S2722QC" } } } ] }
        """)
        let match = ProfileMatching.activeProfile(config.profiles, displays: [Fixtures.laptop, Fixtures.verticalRight])
        #expect(match?.profile.id == "any-two")
    }

    @Test func rolesGetDistinctDisplaysEvenWhenMatchersOverlap() throws {
        // Both Dells match both name-only roles; "left" is also pinned by rotation.
        // A greedy match that gave "any" the 270° Dell first would leave "left" with nothing.
        let config = try Fixtures.config("""
        { "profiles": [ { "id": "p", "displays": {
            "any":  { "name": "DELL S2722QC" },
            "left": { "name": "DELL S2722QC", "rotation": 270 },
            "main": { "builtin": true } } } ] }
        """)
        let match = ProfileMatching.activeProfile(config.profiles, displays: Fixtures.desk)
        #expect(match?.roles == ["main": 1, "left": 2, "any": 3])
    }

    @Test func overrideMayLeaveDisplaysUnassigned() throws {
        let laptopProfile = try #require(profiles.first { $0.id == "laptop" })
        #expect(ProfileMatching.assignRoles(laptopProfile, displays: Fixtures.desk) == ["laptop": 1])
        let deskProfile = try #require(profiles.first { $0.id == "desk" })
        #expect(ProfileMatching.assignRoles(deskProfile, displays: [Fixtures.laptop]) == nil)
    }

    @Test func matcherFields() {
        func matcher(builtin: Bool? = nil, name: String? = nil, serial: UInt32? = nil, rotation: Int? = nil) -> DisplayMatcher {
            DisplayMatcher(builtin: builtin, name: name, serial: serial, rotation: rotation)
        }
        let dell = Fixtures.verticalLeft
        #expect(matcher(builtin: false).matches(dell))
        #expect(!matcher(builtin: true).matches(dell))
        #expect(matcher(name: "DELL S2722QC").matches(dell))
        #expect(matcher(name: "dell s2722qc").matches(dell))
        #expect(matcher(name: "DELL S2722QC (2)").matches(dell))
        #expect(!matcher(name: "DELL").matches(dell))
        #expect(matcher(serial: 810894658).matches(dell))
        #expect(!matcher(serial: 825446978).matches(dell))
        #expect(matcher(rotation: 270).matches(dell))
        #expect(!matcher(rotation: 90).matches(dell))
        #expect(!matcher(name: "DELL S2722QC", serial: 1).matches(dell))
    }

    @Test func baseNameStripsOnlyTheDuplicateCounter() {
        #expect(DisplayMatcher.baseName("DELL S2722QC (1)") == "DELL S2722QC")
        #expect(DisplayMatcher.baseName("DELL S2722QC (12)") == "DELL S2722QC")
        #expect(DisplayMatcher.baseName("Built-in Retina Display") == "Built-in Retina Display")
        #expect(DisplayMatcher.baseName("Studio (Display)") == "Studio (Display)")
    }
}

struct ProfileOverrideTests {
    let profiles: [DisplayProfile]

    init() throws {
        profiles = try Fixtures.config(Fixtures.defaultsWithDesk).profiles
    }

    @Test func overrideFitsWhenEveryRoleHasADisplay() {
        let match = ProfileMatching.overrideMatch("laptop", profiles: profiles, displays: Fixtures.desk)
        #expect(match?.profile.id == "laptop")
        #expect(match?.roles == ["laptop": 1])
    }

    @Test func overrideThatDoesntFitIsNil() {
        #expect(ProfileMatching.overrideMatch("desk", profiles: profiles, displays: [Fixtures.laptop]) == nil)
        #expect(ProfileMatching.overrideMatch("nope", profiles: profiles, displays: Fixtures.desk) == nil)
    }

    @Test func explainsWhyAProfileDoesntFit() throws {
        let desk = try #require(profiles.first { $0.id == "desk" })
        #expect(ProfileMatching.whyUnassignable(desk, displays: [Fixtures.laptop])
                == "no display connected for 'vertical-left' and 'vertical-right'")
        let config = try Fixtures.config("""
        { "profiles": [ { "id": "p", "displays": {
            "a": { "serial": 810894658 }, "b": { "rotation": 270 } } } ] }
        """)
        #expect(ProfileMatching.whyUnassignable(config.profiles[0], displays: Fixtures.desk)
                == "two of its roles need the same display")
    }
}

struct ProfileSkeletonTests {
    @Test func deskSkeletonTellsTheDellsApartBySerialLeftToRight() throws {
        let json = ProfileSkeleton.json(for: [Fixtures.verticalRight, Fixtures.laptop, Fixtures.verticalLeft])
        #expect(json == """
        { "id": "new-profile", "displays": {
            "dell-s2722qc-1": { "name": "DELL S2722QC", "serial": 810894658 },
            "laptop": { "builtin": true },
            "dell-s2722qc-2": { "name": "DELL S2722QC", "serial": 825446978 } } }
        """)
        // Pasted into a config, it matches the displays it came from.
        let config = try Fixtures.config(#"{ "profiles": [ \#(json) ] }"#)
        let match = ProfileMatching.activeProfile(config.profiles, displays: Fixtures.desk)
        #expect(match?.roles == ["dell-s2722qc-1": 2, "laptop": 1, "dell-s2722qc-2": 3])
    }

    @Test func singleMonitorGetsNameOnly() {
        let json = ProfileSkeleton.json(for: [Fixtures.laptop, Fixtures.above], id: "hotel")
        #expect(json == """
        { "id": "hotel", "displays": {
            "laptop": { "builtin": true },
            "lg-ultrafine": { "name": "LG UltraFine" } } }
        """)
    }

    @Test func twinsWithoutSerialsFallBackToRotation() throws {
        let left = Fixtures.display(2, "DELL S2722QC (1)", frame: Fixtures.verticalLeft.frame, rotation: 270)
        let right = Fixtures.display(3, "DELL S2722QC (2)", frame: Fixtures.verticalRight.frame, rotation: 90)
        let json = ProfileSkeleton.json(for: [Fixtures.laptop, left, right])
        #expect(json.contains(#""dell-s2722qc-1": { "name": "DELL S2722QC", "rotation": 270 }"#))
        #expect(json.contains(#""dell-s2722qc-2": { "name": "DELL S2722QC", "rotation": 90 }"#))
        _ = try Fixtures.config(#"{ "profiles": [ \#(json) ] }"#)
    }
}
