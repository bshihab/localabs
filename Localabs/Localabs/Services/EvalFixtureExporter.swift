import Foundation

#if DEBUG
/// Development scaffolding: exports a saved report as an eval fixture for
/// `evals/eval_faithfulness.py`.
///
/// A saved `StructuredReport` already holds both halves of a faithfulness
/// case — `rawText` is the OCR text VisionOCRService handed the model (the
/// only thing it was allowed to see), and the five section fields are what it
/// wrote from that. This just reshapes those into the JSON the eval harness
/// reads from `evals/cases/`.
///
/// Flow: History → long-press a report → **Export Eval Fixture (Dev)** →
/// save to Files / AirDrop to the dev Mac → drop the `.json` into
/// `evals/cases/` → `python eval_faithfulness.py --canary`.
///
/// PRIVACY: the exported fixture contains the report's real OCR text. The
/// eval sends it to a cloud judge, which is the one place Localabs data
/// deliberately leaves the device. Export reports you own or have redacted —
/// never a third party's labs.
///
/// Ships only in DEBUG builds. Remove alongside `LogoExportTool` when the
/// eval fixture set is settled.
enum EvalFixtureExporter {

    /// Writes `report` to a temp `.json` file in the harness's fixture shape
    /// and returns the URL, or nil if serialization/write fails.
    ///
    /// Returns a file URL rather than a String so the share sheet offers
    /// "Save to Files" and AirDrop instead of pasting the JSON as message
    /// body text.
    static func writeFixture(for report: StructuredReport) -> URL? {
        let slug = slug(for: report)

        var source: [String: Any] = ["ocr_text": report.rawText]

        // `lab_values` is optional in the fixture format — it gives the judge
        // a second, structured view of the same document. Only include values
        // extracted from THIS report; never synthesize any, or the judge would
        // be grading against facts the model never saw.
        if let values = report.labValues, !values.isEmpty {
            source["lab_values"] = values.map { value -> [String: Any] in
                var row: [String: Any] = [
                    "name": value.rawName,
                    "value": value.value,
                    "unit": value.unit,
                ]
                if let range = value.referenceRange, !range.isEmpty {
                    row["reference_range"] = range
                }
                return row
            }
        }

        // Keys match StructuredReport's Codable field names, which is what
        // the harness's SECTIONS list expects.
        let fixture: [String: Any] = [
            "id": slug,
            "source": source,
            "output": [
                "patientSummary": report.patientSummary,
                "doctorQuestions": report.doctorQuestions,
                "dietaryAdvice": report.dietaryAdvice,
                "medicalGlossary": report.medicalGlossary,
                "medicationNotes": report.medicationNotes,
            ],
        ]

        guard JSONSerialization.isValidJSONObject(fixture),
              let data = try? JSONSerialization.data(
                withJSONObject: fixture,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
              )
        else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(slug).json")

        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            print("[EvalFixtureExporter] write failed: \(error)")
            return nil
        }
    }

    /// Filename-safe case id, e.g. `cmp-panel-2026-03-14`. Falls back to the
    /// report's UUID prefix when the title has no usable characters, so two
    /// untitled reports never collide on one filename.
    private static func slug(for report: StructuredReport) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = formatter.string(from: report.effectiveDate)

        let name = report.displayTitle
            .lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, char in
                // Collapse runs of separators so "CMP  (fasting)" doesn't
                // become "cmp---fasting-".
                if char == "-" && result.hasSuffix("-") { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        let base = name.isEmpty ? String(report.id.uuidString.prefix(8)).lowercased() : name
        return "\(base)-\(date)"
    }
}
#endif
