import Foundation

/// Grading rule (docs/DATA.md): question i counts when key[i] is not empty; it earns points[i] when the
/// answer is exactly one letter and that letter is in key[i].
enum Grading {
    static let letters = ["A", "B", "C", "D"]
    /// Shown for A–D on an Arabic quiz; answers and keys stay A–D everywhere else.
    static let arabicLetters = ["أ", "ب", "ج", "د"]

    /// How a letter (or several, "AC") is shown for the quiz's language ("ar", else English).
    static func display(_ letter: String, language: String?) -> String {
        guard language == "ar" else { return letter }
        return String(letter.map { ch -> Character in
            guard let i = letters.firstIndex(of: String(ch)) else { return ch }
            return Character(arabicLetters[i])
        })
    }

    /// Points earned per question (0 for wrong, blank or not counted).
    static func perQuestion(_ quiz: Quiz, answers: [String]) -> [Double] {
        (0..<max(quiz.questionCount, 0)).map { i in
            let accepted = i < quiz.key.count ? quiz.key[i] : ""
            let answer = i < answers.count ? answers[i] : ""
            return !accepted.isEmpty && isCorrect(answer: answer, key: accepted) ? quiz.point(i) : 0
        }
    }

    static func isCorrect(answer: String, key: String) -> Bool {
        answer.count == 1 && key.contains(answer)
    }

    static func grade(_ quiz: Quiz, answers: [String]) -> (earned: Double, possible: Double) {
        var earned = 0.0, possible = 0.0
        for i in 0..<quiz.questionCount {
            let accepted = i < quiz.key.count ? quiz.key[i] : ""
            if accepted.isEmpty { continue }
            let p = quiz.point(i)
            possible += p
            let answer = i < answers.count ? answers[i] : ""
            if isCorrect(answer: answer, key: accepted) { earned += p }
        }
        return (earned, possible)
    }

    /// Letters kept in A–D order, no duplicates.
    static func normalized(_ letters: String) -> String {
        self.letters.filter { letters.contains($0) }.joined()
    }
}
