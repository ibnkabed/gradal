import Foundation

/// Grading rule from shared/PROTOCOL.md (identical on the PC).
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

    /// Points earned per question (0 for wrong, blank or dropped).
    static func perQuestion(_ quiz: Quiz, answers: [String], version: Int) -> [Double] {
        let k = key(quiz, version: version)
        return (0..<max(quiz.questionCount, 0)).map { i in
            let accepted = i < k.count ? k[i] : ""
            let answer = i < answers.count ? answers[i] : ""
            return !accepted.isEmpty && isCorrect(answer: answer, key: accepted) ? quiz.point(i) : 0
        }
    }

    /// keys[version] if that key exists, else keys[0].
    static func key(_ quiz: Quiz, version: Int) -> [String] {
        let v = version
        if v >= 0 && v < quiz.keys.count { return quiz.keys[v] }
        return quiz.keys.first ?? []
    }

    static func isCorrect(answer: String, key: String) -> Bool {
        answer.count == 1 && key.contains(answer)
    }

    static func grade(_ quiz: Quiz, answers: [String], version: Int) -> (earned: Double, possible: Double) {
        let k = key(quiz, version: version)
        var earned = 0.0, possible = 0.0
        for i in 0..<quiz.questionCount {
            let accepted = i < k.count ? k[i] : ""
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
