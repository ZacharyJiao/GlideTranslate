enum OnboardingStep: Int, CaseIterable, Sendable {
    case privacyModel
    case localOllama
    case shortcut
    case accessibility
    case complete

    var next: Self {
        let steps = Self.allCases
        guard let index = steps.firstIndex(of: self), index + 1 < steps.count else {
            return .complete
        }
        return steps[index + 1]
    }
}
