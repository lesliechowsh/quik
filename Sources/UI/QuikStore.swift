import Foundation
import Combine

final class QuikStore: ObservableObject {
    @Published private(set) var assessment = StallAssessment.idle()
    @Published private(set) var history: [Int] = []
    @Published private(set) var isSampling = false
    @Published var advanced: Bool = UserDefaults.standard.bool(forKey: QuikStore.advancedKey) {
        didSet { UserDefaults.standard.set(advanced, forKey: QuikStore.advancedKey) }
    }

    @Published var hudVisible: Bool = QuikStore.storedHUDVisible {
        didSet { UserDefaults.standard.set(hudVisible, forKey: QuikStore.hudVisibleKey) }
    }

    @Published var language: AppLanguage = AppLanguage.stored {
        didSet { AppLanguage.select(language) }
    }

    static let advancedKey = "advancedMode"
    static let hudVisibleKey = "hudVisible"

    static var storedHUDVisible: Bool {
        let defaults = UserDefaults.standard
        return defaults.object(forKey: hudVisibleKey) as? Bool ?? true
    }

    static var advancedMode: Bool { UserDefaults.standard.bool(forKey: advancedKey) }

    func apply(_ assessment: StallAssessment, _ history: [Int]) {
        self.assessment = assessment
        self.history = history
    }

    func setSampling(_ value: Bool) {
        isSampling = value
    }
}
