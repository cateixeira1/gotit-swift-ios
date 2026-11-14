#if canImport(UIKit)
import UIKit

/// The app's default font (Ajustes › Fonte padrão): text with no font of its own is shown in it,
/// so changing it changes that text everywhere. Text given a font keeps it.
@MainActor
public enum AppFonts {
    public static let key = "defaultFontName"
    /// Stored for text put in the system font on purpose while the default is another font.
    public static let systemName = "System"
    /// Fonts offered, by PostScript name (nil: the system font, San Francisco).
    public static var choices: [(name: String?, title: String)] {
        [(nil, "Sistema (San Francisco)"), ("HelveticaNeue", "Helvetica Neue"), ("AvenirNext-Regular", "Avenir Next"),
         ("Georgia", "Georgia"), ("TimesNewRomanPSMT", "Times New Roman"), ("Charter-Roman", "Charter"),
         ("Palatino-Roman", "Palatino"), ("Menlo-Regular", "Menlo")]
            .filter { $0.name == nil || UIFont(name: $0.name!, size: 12) != nil }
            + HandwritingFonts.bundled.filter { UIFont(name: $0.postScript, size: 12) != nil }.map { (Optional($0.postScript), $0.name) }
    }
    /// The default font's PostScript name; nil is the system font.
    public private(set) static var defaultName: String? = load()
    private static var defaultFamily: String? = defaultName.flatMap { UIFont(name: $0, size: 12)?.familyName }

    private static func load() -> String? {
        UserDefaults.standard.string(forKey: key).flatMap { UIFont(name: $0, size: 12) != nil ? $0 : nil }
    }

    /// Reads the setting again (after fonts are registered at launch).
    public static func reload() {
        defaultName = load()
        defaultFamily = defaultName.flatMap { UIFont(name: $0, size: 12)?.familyName }
    }

    public static func setDefault(_ name: String?) {
        UserDefaults.standard.set(name, forKey: key)
        reload()
    }

    public static func title(of name: String?) -> String { choices.first { $0.name == name }?.title ?? name ?? "Sistema" }

    /// Whether `font` is the default font (any weight or style of its family).
    static func isDefault(_ font: UIFont) -> Bool {
        guard let defaultFamily else { return font.fontName.hasPrefix(".") }
        return font.familyName == defaultFamily
    }
}
#endif
