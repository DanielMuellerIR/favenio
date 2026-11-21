enum GermanHitPresentation {
    static let fieldNames = [
        "name": "Name", "extension": "Endung", "relativePath": "Pfad",
        "content": "Inhalt", "metadata": "Metadaten", "size": "Größe",
        "modified": "Geändert", "created": "Erstellt", "width": "Breite", "height": "Höhe",
        "finderTags": "Finder-Tags", "finderComment": "Finder-Kommentar",
    ]

    static func describesLocation(_ evidence: CriterionEvidence) -> Bool {
        evidence.field == "content" || evidence.field == "metadata"
    }

    static func describe(_ evidence: CriterionEvidence) -> String {
        let place = evidence.documentPosition.map { " " + $0.title }
            ?? evidence.line.map { " Zeile \($0)" } ?? ""
        let metadata = evidence.metadataField.map { " \($0)" } ?? ""
        let value = evidence.field == "content" && evidence.negated
            ? "ohne „" + evidence.value + "“" : evidence.value
        return (fieldNames[evidence.field] ?? evidence.field) + place + metadata + ": "
            + value + (evidence.valueTruncated ? "…" : "")
    }
}

extension Hit {
    var locationText: String {
        if terms.count > 1 {
            let lines = terms.compactMap { term in
                term.line.map { term.documentPosition?.title ?? String($0) }
            }
            if lines.count == terms.count { return lines.joined(separator: ", ") }
            let values = terms.compactMap { term in
                term.field.map { $0 + ": " + (term.value ?? "") }
            }
            if values.count == terms.count { return values.joined(separator: " | ") }
        }
        if let field, let value { return field + ": " + value }
        if let documentPosition { return documentPosition.title }
        if let line { return String(line) }
        let locations = criteriaEvidence.filter(GermanHitPresentation.describesLocation)
        let facts = criteriaEvidence.filter { !GermanHitPresentation.describesLocation($0) }
        var descriptions = (locations + facts).prefix(3).map(GermanHitPresentation.describe)
        if criteriaEvidence.count > 3 {
            descriptions.append("+\(criteriaEvidence.count - 3) weitere")
        }
        return descriptions.joined(separator: " | ")
    }
}
