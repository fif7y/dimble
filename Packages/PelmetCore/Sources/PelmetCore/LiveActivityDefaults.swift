/// Live Activities live mode leaves off until the user turns them on.
public enum LiveActivityDefaults {
    /// macOS 27.3's "System & App Protection Override" (AXVisualSupportAgent):
    /// it lists every app that can control the Mac, Dimble among them, so on
    /// a Mac running Dimble it never ends and would sit beside the « for good.
    public static let offIdentifiers: Set<String> = [
        "live-activity-pill-com.apple.accessibility.AXVisualSupportAgent",
    ]

    /// The default-off pills seen for the first time, by the name they show
    /// (macOS's, so localized), each once. `seeded`: identifiers whose
    /// default was applied before, so one the user turned on stays on.
    public static func toTurnOff(
        seen: [(identifier: String, name: String)], seeded: Set<String>
    ) -> [(identifier: String, name: String)] {
        var out: [(identifier: String, name: String)] = []
        for pill in seen where offIdentifiers.contains(pill.identifier) && !seeded.contains(pill.identifier)
            && !out.contains(where: { $0.identifier == pill.identifier }) {
            out.append(pill)
        }
        return out
    }
}
