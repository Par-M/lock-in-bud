import Foundation

enum JSONCoding {
    static func calendarDay(_ date: Date, timezone: String) -> String {
        let formatter = makeDateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: timezone) ?? .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func makeDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.isLenient = false
        return formatter
    }

    static func parseISO8601(_ string: String) -> Date? {
        if let date = parseISO8601Formatter(withFractionalSeconds: true).date(from: string)
            ?? parseISO8601Formatter(withFractionalSeconds: false).date(from: string) {
            return date
        }

        // Fallback for offsets like "+00:00"/"-05:00" (ISO8601DateFormatter only
        // handles "Z") and for naive datetimes the server can emit (no offset,
        // no fractional seconds) when serializing a date column as a datetime.
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd",
        ]
        let formatter = makeDateFormatter()
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }

    private static func parseISO8601Formatter(withFractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = parseISO8601(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unparseable date: \(string)"
            )
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let sinceFormatter: DateFormatter = {
        let formatter = makeDateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'Z'"
        return formatter
    }()

    static let dayFormatter: DateFormatter = {
        let formatter = makeDateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
