import Foundation
import HipparchusData

/// What to call the change between two sessions.
///
/// macOS puts the action name in the Edit menu — "Undo Change Preset", "Undo
/// Enable OpenStreetMap" — and a menu that only ever says "Undo" is a menu that
/// tells you nothing. Working out that name is the whole of it.
///
/// It lives here rather than in the window for one reason: it is a pure function
/// of two values, and the app target has no tests. Naming used to be three
/// observers diffing live model properties, where no rule could be checked
/// without a person opening the Edit menu and reading it.
public enum SessionEdit {

    public struct Description: Sendable, Equatable {
        /// What the menu says, after "Undo".
        public let action: String
        /// Same key arriving again within the coalescing window continues one
        /// action; `nil` never merges. A stepper drag is one intention.
        public let coalescingKey: String?

        public init(action: String, coalescingKey: String? = nil) {
            self.action = action
            self.coalescingKey = coalescingKey
        }
    }

    /// Name the change, or `nil` if there is not one.
    ///
    /// **One gesture changes one thing**, so the first difference found is the
    /// action and anything that rode along with it shares the entry — adopting a
    /// preset brings its derivation sizes, and that is still "Change Preset".
    /// The order below is therefore the order of specificity, not of the fields
    /// in `Session`.
    public static func describe(
        from before: Session,
        to after: Session,
        definitions: [SourceDefinition] = SourceStack.defaultDefinitions
    ) -> Description? {
        guard before != after else { return nil }

        if let edit = sourceEdit(from: before, to: after, definitions: definitions) {
            return edit
        }
        if before.presetName != after.presetName {
            return Description(action: "Change Preset")
        }
        if before.qualityKey != after.qualityKey {
            return Description(action: "Change Quality")
        }
        if let edit = derivedEdit(from: before.derived, to: after.derived) {
            return edit
        }
        if let edit = layerEdit(from: before.hiddenLayers, to: after.hiddenLayers) {
            return edit
        }
        if before.area != after.area || before.placeName != after.placeName {
            // Typing four numbers is one act of framing, not four.
            return Description(action: "Change Area", coalescingKey: "area")
        }
        // Something changed that has no better name — a field added later, most
        // likely. A vague entry beats a silent one: the undo still works.
        return Description(action: "Change Settings")
    }

    // MARK: -

    private static func sourceEdit(
        from before: Session, to after: Session, definitions: [SourceDefinition]
    ) -> Description? {
        func label(_ id: String) -> String {
            definitions.first { $0.id == id }?.label ?? id
        }

        let wasEnabled = Set(before.enabledSources)
        let isEnabled = Set(after.enabledSources)
        if let turnedOn = isEnabled.subtracting(wasEnabled).sorted().first {
            return Description(action: "Enable \(label(turnedOn))")
        }
        if let turnedOff = wasEnabled.subtracting(isEnabled).sorted().first {
            return Description(action: "Disable \(label(turnedOff))")
        }

        if before.sourcePaths != after.sourcePaths {
            let changed = Set(before.sourcePaths.keys).union(after.sourcePaths.keys).sorted()
                .first { before.sourcePaths[$0] != after.sourcePaths[$0] }
            return Description(action: "Choose File for \(label(changed ?? ""))")
        }

        // A number and a choice are the same idea to a reader, so they share the
        // sentence — and the field they came from is the coalescing key, so
        // dragging one stepper never merges with dragging the next.
        if before.sourceSettings != after.sourceSettings {
            let field = Set(before.sourceSettings.keys).union(after.sourceSettings.keys).sorted()
                .first { before.sourceSettings[$0] != after.sourceSettings[$0] }
            return settingEdit(field, definitions: definitions)
        }
        if before.sourceChoices != after.sourceChoices {
            let field = Set(before.sourceChoices.keys).union(after.sourceChoices.keys).sorted()
                .first { before.sourceChoices[$0] != after.sourceChoices[$0] }
            return settingEdit(field, definitions: definitions)
        }
        return nil
    }

    private static func settingEdit(
        _ field: String?, definitions: [SourceDefinition]
    ) -> Description {
        guard let field, let (id, key) = split(field) else {
            return Description(action: "Change Setting")
        }
        let label = definitions.first { $0.id == id }?.setting(key)?.label ?? "Setting"
        return Description(action: "Change \(label)", coalescingKey: "stack.\(id).\(key)")
    }

    private static func derivedEdit(
        from before: Session.Derived, to after: Session.Derived
    ) -> Description? {
        func switched(_ on: Bool, _ layer: String) -> Description {
            Description(action: on ? "Turn On \(layer)" : "Turn Off \(layer)")
        }
        if before.voronoi != after.voronoi { return switched(after.voronoi, "Voronoi Cells") }
        if before.delaunay != after.delaunay { return switched(after.delaunay, "Delaunay Mesh") }
        if before.hexGrid != after.hexGrid { return switched(after.hexGrid, "Hex Grid") }
        if before.circlePacking != after.circlePacking {
            return switched(after.circlePacking, "Circle Packing")
        }
        if before.hexRadius != after.hexRadius {
            return Description(action: "Change Hex Size", coalescingKey: "derived.hexRadius")
        }
        if before.circleMinRadius != after.circleMinRadius {
            return Description(action: "Change Circle Size", coalescingKey: "derived.circleMinRadius")
        }
        if before.circleMaxRadius != after.circleMaxRadius {
            return Description(action: "Change Circle Size", coalescingKey: "derived.circleMaxRadius")
        }
        return nil
    }

    private static func layerEdit(from before: [String], to after: [String]) -> Description? {
        let wasHidden = Set(before)
        let isHidden = Set(after)
        // The panel's own name for the layer, so the menu and the row agree.
        if let hidden = isHidden.subtracting(wasHidden).sorted().first {
            return Description(action: "Hide \(LayerInventory.label(for: hidden))")
        }
        if let shown = wasHidden.subtracting(isHidden).sorted().first {
            return Description(action: "Show \(LayerInventory.label(for: shown))")
        }
        return nil
    }

    /// Split on the last dot: a source id may not contain one, but this is the
    /// side that must be right if one ever does.
    private static func split(_ field: String) -> (id: String, key: String)? {
        guard let dot = field.lastIndex(of: ".") else { return nil }
        return (String(field[field.startIndex..<dot]), String(field[field.index(after: dot)...]))
    }
}
