struct RegexTemplate {
    let name: String
    let category: String
    let regex: String
    let example: String
}

let regexTemplates: [RegexTemplate] = [
    // Identifikatoren
    .init(name: "E-Mail-Adresse", category: "Identifikatoren",
          regex: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
          example: "max.muster@example.com"),
    .init(name: "URL", category: "Identifikatoren",
          regex: #"https?://[\w.-]+(?:/[\w./?=&%#-]*)?"#,
          example: "https://example.com/path?q=1"),
    .init(name: "IPv4-Adresse", category: "Identifikatoren",
          regex: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#, example: "192.168.1.1"),
    .init(name: "IBAN", category: "Identifikatoren",
          regex: #"[A-Z]{2}\d{2}[A-Z0-9]{1,30}"#,
          example: "DE89370400440532013000"),
    .init(name: "UUID", category: "Identifikatoren",
          regex: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
          example: "550e8400-e29b-41d4-a716-446655440000"),
    .init(name: "Hex-Farbe (#RRGGBB)", category: "Identifikatoren",
          regex: #"#(?:[0-9a-fA-F]{3}){1,2}\b"#, example: "#FF9900"),
    .init(name: "Versionsnummer (v1.2.3)", category: "Identifikatoren",
          regex: #"\bv?\d+\.\d+\.\d+\b"#, example: "v1.2.3"),
    .init(name: "Dateiname mit Endung", category: "Identifikatoren",
          regex: #"[\w.-]+\.[A-Za-z][A-Za-z0-9]{0,4}\b"#, example: "notiz.md"),
    // Datum & Zeit
    .init(name: "ISO-Datum (YYYY-MM-DD)", category: "Datum & Zeit",
          regex: #"\b(\d{4})-(\d{2})-(\d{2})\b"#, example: "2026-07-13"),
    .init(name: "Deutsches Datum (DD.MM.YYYY)", category: "Datum & Zeit",
          regex: #"\b(\d{2})\.(\d{2})\.(\d{4})\b"#, example: "13.07.2026"),
    .init(name: "Uhrzeit", category: "Datum & Zeit",
          regex: #"\b(\d{1,2}):(\d{2})(?::(\d{2}))?\b"#, example: "14:30:45"),
    .init(name: "ISO-Zeitstempel", category: "Datum & Zeit",
          regex: #"\b(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?\b"#,
          example: "2026-07-13 15:30:00"),
    // Text & Struktur
    .init(name: "Markdown-Link", category: "Text & Struktur",
          regex: #"\[([^\]]+)\]\(([^)]+)\)"#,
          example: "[OpenAI](https://openai.com)"),
    .init(name: "Markdown-Überschrift", category: "Text & Struktur",
          regex: #"^(#{1,6})\s+(.+)$"#, example: "## Überschrift"),
    .init(name: "HTML-Tag", category: "Text & Struktur",
          regex: #"<(/?)([a-zA-Z][a-zA-Z0-9]*)([^>]*)>"#,
          example: #"<a href="…">"#),
    .init(name: "HTML-/XML-Kommentar", category: "Text & Struktur",
          regex: #"<!--[\s\S]*?-->"#, example: "<!-- Notiz -->"),
    // Zahlen
    .init(name: "Ganzzahl", category: "Zahlen",
          regex: #"-?\d+"#, example: "-42"),
    .init(name: "Dezimalzahl (deutsch)", category: "Zahlen",
          regex: #"-?\d+(?:\.\d{3})*,\d+"#, example: "1.234,56"),
    .init(name: "Telefonnummer (DE)", category: "Zahlen",
          regex: #"(?:\+49|0)[\s/-]?\d{2,5}[\s/-]?\d{4,8}"#,
          example: "+49 30 12345678"),
]
