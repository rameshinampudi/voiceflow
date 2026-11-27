import Foundation

/// A tiny assertion harness (no XCTest / swift-testing macros needed).
final class Checks {
    private(set) var passed = 0
    private(set) var failed = 0
    private var current = ""

    struct RequireFailed: Error {}

    func run(_ name: String, _ body: () throws -> Void) {
        current = name
        do { try body() } catch is RequireFailed {} catch { record(false, "threw \(error)", #filePath, #line) }
    }

    func runAsync(_ name: String, _ body: () async throws -> Void) async {
        current = name
        do { try await body() } catch is RequireFailed {} catch { record(false, "threw \(error)", #filePath, #line) }
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: String = #filePath, line: Int = #line) {
        record(condition, message(), file, line)
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, file: String = #filePath, line: Int = #line) {
        record(actual == expected, "got \(String(reflecting: actual)), expected \(String(reflecting: expected))", file, line)
    }

    func require<T>(_ value: T?, file: String = #filePath, line: Int = #line) throws -> T {
        guard let value else {
            record(false, "required value was nil", file, line)
            throw RequireFailed()
        }
        return value
    }

    func throwsError<E: Error & Equatable>(_ expected: E, file: String = #filePath, line: Int = #line, _ body: () throws -> Void) {
        do {
            try body()
            record(false, "expected \(expected) to be thrown", file, line)
        } catch let error as E {
            record(error == expected, "threw \(error), expected \(expected)", file, line)
        } catch {
            record(false, "threw \(error), expected \(expected)", file, line)
        }
    }

    func throwsErrorAsync<E: Error & Equatable>(_ expected: E, file: String = #filePath, line: Int = #line, _ body: () async throws -> Void) async {
        do {
            try await body()
            record(false, "expected \(expected) to be thrown", file, line)
        } catch let error as E {
            record(error == expected, "threw \(error), expected \(expected)", file, line)
        } catch {
            record(false, "threw \(error), expected \(expected)", file, line)
        }
    }

    private func record(_ ok: Bool, _ message: String, _ file: String, _ line: Int) {
        if ok {
            passed += 1
        } else {
            failed += 1
            print("✘ \(current) — \((file as NSString).lastPathComponent):\(line) \(message)")
        }
    }
}
