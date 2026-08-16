public enum LanguageChoice: Hashable, Codable, Sendable {
    case automatic
    case identified(String)
}

public enum ApplicationLanguage: String, Codable, Sendable {
    case english
    case simplifiedChinese
}

public enum DestinationPrivacyClass: String, Codable, Sendable {
    case localOnDevice
    case localNetwork
    case cloud
    case unresolvedOrChanged
}
