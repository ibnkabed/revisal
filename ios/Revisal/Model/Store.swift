import CryptoKit
import Foundation
import SwiftUI

/// Everything Revisal keeps, in one JSON file (docs/DATA.md).
struct StoreFile: Codable {
    var books: [Book] = []
    var sets: [ReviewSet] = []
    var bankSeen: [String: [String]] = [:]    // Bank.seenKey -> question ids seen in the current round
    var settings = Settings()
    var explanations: [String: String] = [:]  // bank question id -> the explanation the student asked for

    enum CodingKeys: String, CodingKey { case books, sets, bankSeen, settings, explanations }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        books = (try? c.decodeIfPresent([Book].self, forKey: .books)) ?? []
        sets = (try? c.decodeIfPresent([ReviewSet].self, forKey: .sets)) ?? []
        bankSeen = (try? c.decodeIfPresent([String: [String]].self, forKey: .bankSeen)) ?? [:]
        settings = (try? c.decodeIfPresent(Settings.self, forKey: .settings)) ?? Settings()
        explanations = (try? c.decodeIfPresent([String: String].self, forKey: .explanations)) ?? [:]
    }
}

struct StoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Local store: Application Support/Revisal/ store.json, books/<id>.pdf, texts/<unitId>.txt (a unit's text,
/// kept because reading scanned pages costs a provider call).
@MainActor
final class Store: ObservableObject {
    @Published private(set) var db: StoreFile

    /// Reviews kept in the history.
    static let keptSets = 200

    let folder: URL
    private var booksFolder: URL { folder.appendingPathComponent("books", isDirectory: true) }
    private var textsFolder: URL { folder.appendingPathComponent("texts", isDirectory: true) }

    static var dataFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Revisal", isDirectory: true)
    }

    init(folder: URL = Store.dataFolder) {
        self.folder = folder
        db = StoreFile()
        load()
    }

    private func load() {
        for dir in [folder, booksFolder, textsFolder] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: folder.appendingPathComponent("store.json")),
           let file = try? JSONDecoder().decode(StoreFile.self, from: data) {
            db = file
        } else {
            db = StoreFile()
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(db) else { return }
        try? data.write(to: folder.appendingPathComponent("store.json"), options: .atomic)
    }

    func bookURL(_ id: String) -> URL {
        booksFolder.appendingPathComponent("\(id).pdf")
    }

    private func textURL(_ unitId: String) -> URL {
        textsFolder.appendingPathComponent("\(unitId).txt")
    }

    // MARK: - Books and units

    var books: [Book] { db.books.sorted { $0.addedAt > $1.addedAt } }

    func book(_ id: String?) -> Book? {
        guard let id else { return nil }
        return db.books.first { $0.id == id }
    }

    /// Copies the PDF in; a book of at most BookRules.maxPages pages gets one unit, the whole book.
    func addBook(from url: URL) throws -> Book {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard data.starts(with: Array("%PDF-".utf8)) else { throw StoreError(message: "الملف ليس PDF") }
        let id = SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
        if let existing = db.books.first(where: { $0.id == id }) { return existing }
        try data.write(to: bookURL(id), options: .atomic)
        let pages = BookText.pageCount(bookURL(id))
        guard pages > 0 else {
            try? FileManager.default.removeItem(at: bookURL(id))
            throw StoreError(message: "تعذّر فتح ملف PDF")
        }
        var book = Book(id: id, name: url.deletingPathExtension().lastPathComponent, pages: pages,
                        size: data.count, addedAt: Stamp.now())
        if pages <= BookRules.maxPages {
            book.units = [Unit(name: "الملف كله", pageFrom: 1, pageTo: pages)]
        }
        db.books.append(book)
        save()
        return book
    }

    func updateBook(_ id: String, name: String, subject: String) {
        guard let i = db.books.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty { db.books[i].name = String(n.prefix(80)) }
        db.books[i].subject = String(subject.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        save()
    }

    func deleteBook(_ id: String) {
        guard let book = book(id) else { return }
        for u in book.units { try? FileManager.default.removeItem(at: textURL(u.id)) }
        db.books.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: bookURL(id))
        save()
    }

    func addUnit(_ bookId: String, name: String, from a: Int, to b: Int) throws {
        guard let i = db.books.firstIndex(where: { $0.id == bookId }) else { return }
        try BookRules.checkRange(from: a, to: b, pages: db.books[i].pages)
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = n.isEmpty ? "الوحدة \(db.books[i].units.count + 1)" : String(n.prefix(60))
        db.books[i].units.append(Unit(name: title, pageFrom: a, pageTo: b))
        save()
    }

    /// A changed page range forgets the unit's text and skills (they belonged to the old pages).
    func updateUnit(_ bookId: String, _ unit: Unit) throws {
        guard let i = db.books.firstIndex(where: { $0.id == bookId }),
              let j = db.books[i].units.firstIndex(where: { $0.id == unit.id }) else { return }
        try BookRules.checkRange(from: unit.pageFrom, to: unit.pageTo, pages: db.books[i].pages)
        var u = unit
        let old = db.books[i].units[j]
        if old.pageFrom != u.pageFrom || old.pageTo != u.pageTo {
            u.skills = []
            u.asked = [:]
            try? FileManager.default.removeItem(at: textURL(u.id))
        }
        db.books[i].units[j] = u
        save()
    }

    func deleteUnits(_ bookId: String, at offsets: IndexSet) {
        guard let i = db.books.firstIndex(where: { $0.id == bookId }) else { return }
        for j in offsets { try? FileManager.default.removeItem(at: textURL(db.books[i].units[j].id)) }
        db.books[i].units.remove(atOffsets: offsets)
        save()
    }

    func unitText(_ unitId: String) -> String? {
        try? String(contentsOf: textURL(unitId), encoding: .utf8)
    }

    func saveUnitText(_ unitId: String, _ text: String) {
        try? text.write(to: textURL(unitId), atomically: true, encoding: .utf8)
    }

    // MARK: - Reviews

    func reviewSet(_ id: String?) -> ReviewSet? {
        guard let id else { return nil }
        return db.sets.first { $0.id == id }
    }

    /// Newest first: a track's reviews, or one book's.
    func history(_ track: Track, bookId: String? = nil) -> [ReviewSet] {
        db.sets.filter { $0.source.track == track && (bookId == nil || $0.source.bookId == bookId) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func add(_ set: ReviewSet) {
        db.sets.append(set)
        if db.sets.count > Self.keptSets {
            db.sets = Array(db.sets.sorted { $0.createdAt < $1.createdAt }.suffix(Self.keptSets))
        }
        save()
    }

    func choose(_ setId: String, question index: Int, option: Int) {
        guard let i = db.sets.firstIndex(where: { $0.id == setId }), index < db.sets[i].choices.count,
              db.sets[i].choices[index] == nil else { return }
        db.sets[i].choices[index] = option
        save()
    }

    func explanation(_ questionId: String) -> String? { db.explanations[questionId] }

    func saveExplanation(_ questionId: String, _ text: String) {
        db.explanations[questionId] = text
        save()
    }

    func finish(_ setId: String) {
        guard let i = db.sets.firstIndex(where: { $0.id == setId }), db.sets[i].finishedAt == nil else { return }
        db.sets[i].finishedAt = Stamp.now()
        save()
    }

    func deleteSet(_ id: String) {
        db.sets.removeAll { $0.id == id }
        save()
    }

    /// A curriculum unit after a review was written for it (skills, counts, stems).
    func recordUnit(_ bookId: String, _ unit: Unit) {
        guard let i = db.books.firstIndex(where: { $0.id == bookId }),
              let j = db.books[i].units.firstIndex(where: { $0.id == unit.id }) else { return }
        db.books[i].units[j] = unit
        save()
    }

    // MARK: - Question banks

    func bankSeen(_ track: Track) -> Set<String> {
        Set(db.bankSeen[Bank.seenKey(track)] ?? [])
    }

    func setBankSeen(_ track: Track, _ ids: Set<String>) {
        db.bankSeen[Bank.seenKey(track)] = ids.sorted()
        save()
    }

    // MARK: - Settings and backup

    func updateSettings(_ s: Settings) {
        db.settings = s
        save()
    }

    func exportBackup() throws -> URL {
        save()
        return try Backup.export(folder: folder)
    }

    func restoreBackup(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        try Backup.restore(url, into: folder)
        load()
    }
}
