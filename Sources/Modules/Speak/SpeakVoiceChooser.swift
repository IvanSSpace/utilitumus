import Foundation
import NaturalLanguage

/// Какой голос читает текст. Закреплённый на язык текста, если он ещё есть в системе; иначе «Авто» —
/// лучший голос этого языка. Голоса нет вовсе — nil, синтезатор возьмёт голос системы.
enum SpeakVoiceChooser {
    static func choose(for text: String, voices: [SpeakVoiceRow], pinned: [String: String], preferred: [String]) -> String? {
        guard let language = language(of: text) ?? preferred.first.map(SpeakVoiceRow.languageKey) else { return nil }
        // Закреплённый голос удалили из системы — откат на «Авто», закрепление остаётся: голос могут поставить снова.
        if let id = pinned[language], voices.contains(where: { $0.id == id }) { return id }
        return best(for: language, in: voices, preferred: preferred)?.id
    }

    /// Язык текста без региона: «ru», «en». Не понять — nil. Хватает начала текста.
    static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(2000)))
        guard let found = recognizer.dominantLanguage, found != .undetermined else { return nil }
        return SpeakVoiceRow.languageKey(found.rawValue)
    }

    /// Лучшее качество; при равном — регион из языков системы («en-GB» у того, кто выбрал британский); дальше по имени.
    static func best(for language: String, in voices: [SpeakVoiceRow], preferred: [String]) -> SpeakVoiceRow? {
        let regions = Set(preferred.map { $0.lowercased().replacingOccurrences(of: "_", with: "-") })
        func preferredRegion(_ voice: SpeakVoiceRow) -> Bool {
            regions.contains(voice.language.lowercased().replacingOccurrences(of: "_", with: "-"))
        }
        return voices.filter { $0.languageKey == language }.min { a, b in
            if a.quality != b.quality { return a.quality > b.quality }
            if preferredRegion(a) != preferredRegion(b) { return preferredRegion(a) }
            return (a.name, a.id) < (b.name, b.id)
        }
    }
}
