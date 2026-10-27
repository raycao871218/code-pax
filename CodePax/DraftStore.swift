import Foundation

struct DraftAddress: Equatable {
    let server: String
    let session: String
    var key: String { server + ".draft." + session }
}

struct DraftRecord: Codable {
    var text: String = ""
    var revision: String = UUID().uuidString
}

struct DraftStore {
    var defaults: UserDefaults = .standard

    func load(_ address: DraftAddress) -> DraftRecord {
        guard let data = defaults.data(forKey: address.key),
              let record = try? JSONDecoder().decode(DraftRecord.self, from: data) else { return DraftRecord() }
        return record
    }

    func save(_ record: DraftRecord, at address: DraftAddress) {
        guard let data = try? JSONEncoder().encode(record) else { return }
        defaults.set(data, forKey: address.key)
    }
}

struct ReconnectSchedule {
    private(set) var failures = 0
    private(set) var nextAttempt = Date.distantPast
    mutating func failed(at date: Date = Date()) {
        let delay = min(30, pow(2, Double(min(failures + 1, 5))))
        failures += 1
        nextAttempt = date.addingTimeInterval(delay)
    }
    mutating func retryNow() { nextAttempt = .distantPast }
    mutating func reset() { self = Self() }
    func isDue(at date: Date = Date()) -> Bool { date >= nextAttempt }
}
