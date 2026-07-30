import HipparchusRender
import SwiftUI

/// Structure invented from the map rather than fetched with it.
///
/// Its own section rather than part of the style picker, because a preset cannot
/// switch these on: all sixteen style the four derived layers and three tune their
/// sizes, but every switch is off — here and in the Python. So this is the switch,
/// and it says plainly that what it makes is generated.
struct DerivedPanel: View {
    @Bindable var model: MapModel

    var body: some View {
        Section {
            toggle("Voronoi cells", "square.grid.3x3", \.deriveVoronoi,
                   help: "One cell per building, meeting midway between them.")
            toggle("Delaunay mesh", "triangle", \.deriveDelaunay,
                   help: "Triangles between road junctions.")
            toggle("Hex grid", "hexagon", \.deriveHexGrid,
                   help: "A honeycomb over the area the map occupies.")
            toggle("Circle packing", "circle.circle", \.deriveCirclePacking,
                   help: "Circles grown to fill the space, largest first.")

            if model.derivations.deriveHexGrid {
                stepper("Hex radius", \.hexRadius, range: 10...400, step: 10)
            }
            if model.derivations.deriveCirclePacking {
                stepper("Smallest circle", \.circleMinRadius, range: 2...200, step: 2)
                stepper("Largest circle", \.circleMaxRadius, range: 4...600, step: 4)
            }

            if model.derivesAnything {
                Text("Generated, not measured. These describe the map, not the ground.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            HStack {
                Text("Derived")
                Spacer()
                Text("invented, not fetched")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func toggle(
        _ label: String,
        _ symbol: String,
        _ field: WritableKeyPath<GeometryPipelineProfile, Bool>,
        help: String
    ) -> some View {
        Toggle(isOn: Binding(
            get: { model.derivations[keyPath: field] },
            set: { model.derivations[keyPath: field] = $0 }
        )) {
            Label(label, systemImage: symbol)
        }
        .toggleStyle(.checkbox)
        .help(help)
    }

    private func stepper(
        _ label: String,
        _ field: WritableKeyPath<GeometryPipelineProfile, Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        // Projected units are metres, which is the one thing about these numbers
        // that is not obvious from the slider.
        Stepper(
            value: Binding(
                get: { model.derivations[keyPath: field] },
                set: { model.derivations[keyPath: field] = $0 }
            ),
            in: range,
            step: step
        ) {
            HStack {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(model.derivations[keyPath: field])) m")
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .controlSize(.small)
    }
}
