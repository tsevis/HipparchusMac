import Foundation

/// Accessibility identifiers the layout tests anchor to.
///
/// **Identity rather than appearance.** A UI test that finds a control by its
/// label breaks when the wording improves, and one that finds it by position
/// breaks the moment anything moves — which makes it a test of the layout's
/// stillness rather than of its correctness, and the usual response to that is
/// to stop running the tests. An identifier is a promise about *what a control
/// is*, and it survives a rewrite of the words and a rearrangement of the
/// window.
///
/// These are also read by `Scripts/ui-test.sh` and by `HipparchusUITests`, which
/// is why they are one list rather than string literals at both ends. A renamed
/// identifier then fails to compile instead of failing to match.
enum UITestID {
    // Structure: the three columns and the bar under them.
    static let framePanel = "frame_panel"
    static let mapColumn = "map_column"
    static let inspector = "inspector"
    static let statusBar = "status_bar"

    // The verbs.
    static let renderButton = "render_map_button"
    static let cancelButton = "cancel_fetch_button"
    static let locatorButton = "open_locator_button"
    static let exportMenu = "export_menu"

    // What the window says about itself.
    static let areaDescription = "area_description"
}
