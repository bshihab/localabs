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
    /// Additional page filenames for multi-page scans (PDFs or multiple
    /// photos). The first page's path stays in `imagePath` so existing
    /// saved reports decode unchanged.
    var additionalPagePaths: [String]?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        patientSummary: String = "",
        doctorQuestions: String = "",
        dietaryAdvice: String = "",
        medicalGlossary: String = "",
        medicationNotes: String = "",
        rawText: String = "",
        imagePath: String? = nil,
        additionalPagePaths: [String]? = nil
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
        self.additionalPagePaths = additionalPagePaths
    }

    var imageURL: URL? {
        guard let imagePath else { return nil }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("scans").appendingPathComponent(imagePath)
    }

    /// True when the report's AI generation didn't produce a normal
    /// 5-section output. Detected by checking whether the patient summary
    /// matches our specific failure / cancellation messages OR every
    /// section is empty despite OCR text being present. Used by the
    /// dashboard to surface a "Resume Analysis" call-to-action.
    var isIncomplete: Bool {
        let hasOCR = !rawText.isEmpty
        // The Localabs prompt instructs the model to always produce
        // all five sections in order. Any missing section overwhelmingly
        // means generation was interrupted mid-stream — pause, app
        // backgrounded, or n_ctx overflow. A legit report on any
        // scanned lab panel produces at least placeholder text for
        // every section (the AI will say "Not applicable" rather than
        // emit nothing). So "any section empty" is the most reliable
        // truncation signal we have without adding an explicit flag.
        let anySectionEmpty = patientSummary.isEmpty
            || doctorQuestions.isEmpty
            || dietaryAdvice.isEmpty
            || medicalGlossary.isEmpty
            || medicationNotes.isEmpty
        let hasFailureMarker = patientSummary.contains("interrupted")
            || patientSummary.contains("didn't complete")
            || patientSummary.contains("Analysis was")
            || patientSummary.contains("Paused before")
            || patientSummary.contains("Failed to extract")
        return hasOCR && (anySectionEmpty || hasFailureMarker)
    }

    /// All page image URLs in document order. Empty if the report has no
    /// saved scans (e.g., weekly Apple Health review). Multi-page reports
    /// have one URL per page in chronological scan order.
    var allImageURLs: [URL] {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let scansDir = docs.appendingPathComponent("scans")
        var urls: [URL] = []
        if let imagePath {
            urls.append(scansDir.appendingPathComponent(imagePath))
        }
        if let extras = additionalPagePaths {
            urls.append(contentsOf: extras.map { scansDir.appendingPathComponent($0) })
        }
        return urls
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
