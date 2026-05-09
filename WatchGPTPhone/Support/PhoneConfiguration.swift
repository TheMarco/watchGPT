import Foundation

enum AssistantLanguage: String, CaseIterable, Identifiable {
    case auto
    case arabic
    case bulgarian
    case catalan
    case chinese
    case croatian
    case czech
    case danish
    case dutch
    case english
    case estonian
    case finnish
    case french
    case german
    case greek
    case hebrew
    case hindi
    case hungarian
    case indonesian
    case italian
    case japanese
    case korean
    case latvian
    case lithuanian
    case malay
    case norwegian
    case polish
    case portuguese
    case romanian
    case russian
    case slovak
    case slovenian
    case spanish
    case swedish
    case thai
    case turkish
    case ukrainian
    case vietnamese

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .arabic: return "العربية"
        case .bulgarian: return "Български"
        case .catalan: return "Català"
        case .chinese: return "中文"
        case .croatian: return "Hrvatski"
        case .czech: return "Čeština"
        case .danish: return "Dansk"
        case .dutch: return "Nederlands"
        case .english: return "English"
        case .estonian: return "Eesti"
        case .finnish: return "Suomi"
        case .french: return "Français"
        case .german: return "Deutsch"
        case .greek: return "Ελληνικά"
        case .hebrew: return "עברית"
        case .hindi: return "हिन्दी"
        case .hungarian: return "Magyar"
        case .indonesian: return "Bahasa Indonesia"
        case .italian: return "Italiano"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        case .latvian: return "Latviešu"
        case .lithuanian: return "Lietuvių"
        case .malay: return "Bahasa Melayu"
        case .norwegian: return "Norsk"
        case .polish: return "Polski"
        case .portuguese: return "Português"
        case .romanian: return "Română"
        case .russian: return "Русский"
        case .slovak: return "Slovenčina"
        case .slovenian: return "Slovenščina"
        case .spanish: return "Español"
        case .swedish: return "Svenska"
        case .thai: return "ไทย"
        case .turkish: return "Türkçe"
        case .ukrainian: return "Українська"
        case .vietnamese: return "Tiếng Việt"
        }
    }

    var promptName: String? {
        switch self {
        case .auto: return nil
        case .arabic: return "Arabic"
        case .bulgarian: return "Bulgarian"
        case .catalan: return "Catalan"
        case .chinese: return "Chinese"
        case .croatian: return "Croatian"
        case .czech: return "Czech"
        case .danish: return "Danish"
        case .dutch: return "Dutch"
        case .english: return "English"
        case .estonian: return "Estonian"
        case .finnish: return "Finnish"
        case .french: return "French"
        case .german: return "German"
        case .greek: return "Greek"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .hungarian: return "Hungarian"
        case .indonesian: return "Indonesian"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .latvian: return "Latvian"
        case .lithuanian: return "Lithuanian"
        case .malay: return "Malay"
        case .norwegian: return "Norwegian"
        case .polish: return "Polish"
        case .portuguese: return "Portuguese"
        case .romanian: return "Romanian"
        case .russian: return "Russian"
        case .slovak: return "Slovak"
        case .slovenian: return "Slovenian"
        case .spanish: return "Spanish"
        case .swedish: return "Swedish"
        case .thai: return "Thai"
        case .turkish: return "Turkish"
        case .ukrainian: return "Ukrainian"
        case .vietnamese: return "Vietnamese"
        }
    }
}

enum PhoneConfiguration {
    static let openAIAPIKeyKey = "openAIAPIKey"
    static let realtimeVoiceKey = "openAIRealtimeVoice"
    static let assistantLanguageKey = "openAIAssistantLanguage"

    static let availableVoices = [
        "alloy",
        "ash",
        "ballad",
        "coral",
        "echo",
        "sage",
        "shimmer",
        "verse",
        "marin",
        "cedar"
    ]

    static let defaultRealtimeVoice = "marin"
    static let availableTTSVoices = [
        "alloy",
        "ash",
        "ballad",
        "coral",
        "echo",
        "fable",
        "onyx",
        "nova",
        "sage",
        "shimmer",
        "verse"
    ]
    static let realtimeModel = "gpt-realtime"
    static let regularVoiceModel = "gpt-5.5"
    static let regularReasoningEffort = "low"
    static let transcriptionModel = "gpt-4o-mini-transcribe"
    static let ttsModel = "gpt-4o-mini-tts"
    static let realtimeEagerness = "low"
    static let realtimeInstructions =
        "You are WatchGPT, a fast, warm realtime voice assistant running on Apple Watch. Match the user's spoken language whenever you are confident which language it is. If there is any uncertainty — short utterances, unfamiliar accents, background noise, silent input — respond in English. Do not speak any language other than English unless you have clearly heard the user speak that language in this session. Never switch to a third language unprompted. You only receive microphone audio and text transcripts. You do not have camera, screen, location, sensor, or visual access, so never claim you can see the user, their room, their watch, or anything around them. If asked what you can perceive, say you can hear the user's voice only. Speak naturally, keep replies concise unless asked for depth, and avoid long lists unless they are genuinely useful."

    private static let openAIAPIKeyInfoKey = "WATCHGPT_OPENAI_API_KEY"

    static var realtimeEndpointURL: URL? {
        URL(string: "wss://api.openai.com/v1/realtime?model=\(realtimeModel)")
    }

    static var defaultOpenAIAPIKey: String {
        bundleString(for: openAIAPIKeyInfoKey, fallback: "")
    }

    static var openAIAPIKey: String {
        let stored = UserDefaults.standard.string(forKey: openAIAPIKeyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return stored.isEmpty ? defaultOpenAIAPIKey : stored
    }

    static var realtimeVoice: String {
        let stored = UserDefaults.standard.string(forKey: realtimeVoiceKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if stored.isEmpty || !availableVoices.contains(stored) {
            return defaultRealtimeVoice
        }

        return stored
    }

    static var ttsVoice: String {
        let voice = realtimeVoice
        return availableTTSVoices.contains(voice) ? voice : "coral"
    }

    static var assistantLanguage: AssistantLanguage {
        let raw = UserDefaults.standard.string(forKey: assistantLanguageKey) ?? AssistantLanguage.auto.rawValue
        return AssistantLanguage(rawValue: raw) ?? .auto
    }

    static var effectiveInstructions: String {
        guard let promptName = assistantLanguage.promptName else {
            return realtimeInstructions
        }
        return realtimeInstructions
            + " Always respond in \(promptName), regardless of the user's input language."
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            openAIAPIKeyKey: defaultOpenAIAPIKey,
            realtimeVoiceKey: defaultRealtimeVoice,
            assistantLanguageKey: AssistantLanguage.auto.rawValue
        ])
    }

    private static func bundleString(for key: String, fallback: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if trimmed.isEmpty || trimmed.hasPrefix("$(") {
            return fallback
        }

        return trimmed
    }
}
