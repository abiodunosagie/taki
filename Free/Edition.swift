/// What this build of Taki includes. The free edition: live agents, dev servers, Claude limits
/// and token use, and up to two terminal tabs. Everything else is Taki Pro.
enum Edition {
    static let isPro = false
    static let name = "Taki"
    /// Terminal tabs open at once.
    static let maxTerminals = 2
    static let upgradeURL = "https://icowebagency.com/taki"
}
