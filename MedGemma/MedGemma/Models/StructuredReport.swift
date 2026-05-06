import Foundation

struct StructuredReport: Codable, Identifiable, Hashable {
    var id: UUID
    var timestamp: Date
    var patientSummary: String
    var doctorQuestions: String
    var dietaryAdvice: String
    var medicalGlossary: String
    var medicationNotes: String
    var rawText: String
    var imagePath: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        patientSummary: String = "",
        doctorQuestions: String = "",
        dietaryAdvice: String = "",
        medicalGlossary: String = "",
        medicationNotes: String = "",
        rawText: String = "",
        imagePath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.patientSummary = patientSummary
        self.doctorQuestions = doctorQuestions
        self.dietaryAdvice = dietaryAdvice
        self.medicalGlossary = medicalGlossary
        self.medicationNotes = medicationNotes
        self.rawText = rawText
        self.imagePath = imagePath
    }

    var imageURL: URL? {
        guard let imagePath else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("scans").appendingPathComponent(imagePath)
    }

    static func parse(from rawText: String) -> StructuredReport {
        let headers: [(key: String, patterns: [String])] = [
            ("patientSummary",   ["PATIENT SUMMARY"]),
            ("doctorQuestions",  ["QUESTIONS FOR YOUR DOCTOR", "QUESTIONS FOR THE DOCTOR"]),
            ("dietaryAdvice",    ["TARGETED DIETARY ADVICE", "DIETARY ADVICE"]),
            ("medicalGlossary",  ["MEDICAL GLOSSARY", "GLOSSARY"]),
            ("medicationNotes",  ["MEDICATION NOTES", "MEDICATIONS"]),
        ]

        var sections: [String: String] = [:]
        let lines = rawText.components(separatedBy: .newlines)
        var currentKey: String?
        var buffer: [String] = []

        func flush() {
            if let key = currentKey {
                let value = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                sections[key] = value
            }
            buffer.removeAll(keepingCapacity: true)
        }

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespaces)
            let upper = stripped.uppercased()

            var matchedKey: String?
            for header in headers {
                for pattern in header.patterns {
                    let withoutNumbering = upper
                        .replacingOccurrences(
                            of: #"^\s*\d+[\.\)]\s*"#,
                            with: "",
                            options: .regularExpression
                        )
                    if withoutNumbering.hasPrefix(pattern) {
                        matchedKey = header.key
                        break
                    }
                }
                if matchedKey != nil { break }
            }

            if let key = matchedKey {
                flush()
                currentKey = key
            } else {
                buffer.append(line)
            }
        }
        flush()

        return StructuredReport(
            patientSummary: sections["patientSummary"] ?? rawText.trimmingCharacters(in: .whitespacesAndNewlines),
            doctorQuestions: sections["doctorQuestions"] ?? "",
            dietaryAdvice: sections["dietaryAdvice"] ?? "",
            medicalGlossary: sections["medicalGlossary"] ?? "",
            medicationNotes: sections["medicationNotes"] ?? "",
            rawText: rawText
        )
    }
}
