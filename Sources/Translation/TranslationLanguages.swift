import Foundation

/// Languages offered by the translation panel and settings, sorted by speaker count.
enum TranslationLanguages {
    struct Option: Identifiable {
        let code: String
        let name: String
        var id: String { code }
    }

    static var all: [Option] {
        [
            Option(code: "auto", name: L10n.Translation.langAuto),
            Option(code: "zh", name: L10n.Translation.langZh),
            Option(code: "en", name: L10n.Translation.langEn),
            Option(code: "es", name: L10n.Translation.langEs),
            Option(code: "hi", name: L10n.Translation.langHi),
            Option(code: "ar", name: L10n.Translation.langAr),
            Option(code: "bn", name: L10n.Translation.langBn),
            Option(code: "pt", name: L10n.Translation.langPt),
            Option(code: "ru", name: L10n.Translation.langRu),
            Option(code: "ja", name: L10n.Translation.langJa),
            Option(code: "pa", name: L10n.Translation.langPa),
            Option(code: "de", name: L10n.Translation.langDe),
            Option(code: "jv", name: L10n.Translation.langJv),
            Option(code: "ko", name: L10n.Translation.langKo),
            Option(code: "fr", name: L10n.Translation.langFr),
            Option(code: "te", name: L10n.Translation.langTe),
            Option(code: "mr", name: L10n.Translation.langMr),
            Option(code: "ta", name: L10n.Translation.langTa),
            Option(code: "ur", name: L10n.Translation.langUr),
            Option(code: "vi", name: L10n.Translation.langVi),
            Option(code: "it", name: L10n.Translation.langIt),
            Option(code: "th", name: L10n.Translation.langTh),
            Option(code: "ms", name: L10n.Translation.langMs),
            Option(code: "tr", name: L10n.Translation.langTr),
            Option(code: "nl", name: L10n.Translation.langNl),
            Option(code: "pl", name: L10n.Translation.langPl),
            Option(code: "uk", name: L10n.Translation.langUk),
        ]
    }
}
