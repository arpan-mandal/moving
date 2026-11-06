#if MOTION_STANDALONE_TESTS
import Foundation

// The Command Line Tools SDK does not ship XCTest. These adapters run the exact
// same test methods without downloading or pretending to provide that framework.
@MainActor class XCTestCase {
    func setUpWithError() throws { }
    func tearDownWithError() throws { }
    func setUp() async throws { }
    func tearDown() async throws { }
}
struct XCTSkip: Error { let reason: String; init(_ reason: String) { self.reason = reason } }
struct TestFailure: Error { }
@MainActor var assertionFailures = 0
@MainActor func check(_ passed: Bool, _ message: String, file: StaticString, line: UInt) {
    if !passed { assertionFailures += 1; print("FAIL \(file):\(line): \(message)") }
}
@MainActor func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, _ message: String = "Expected true", file: StaticString = #filePath, line: UInt = #line) { do { check(try value(), message, file: file, line: line) } catch { check(false, error.localizedDescription, file: file, line: line) } }
@MainActor func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, _ message: String = "Expected false", file: StaticString = #filePath, line: UInt = #line) { do { check(try !value(), message, file: file, line: line) } catch { check(false, error.localizedDescription, file: file, line: line) } }
@MainActor func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, _ message: String = "Values differ", file: StaticString = #filePath, line: UInt = #line) { do { check(try a() == b(), message, file: file, line: line) } catch { check(false, error.localizedDescription, file: file, line: line) } }
@MainActor func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double, file: StaticString = #filePath, line: UInt = #line) { check(abs(a-b) <= accuracy, "\(a) differs from \(b)", file: file, line: line) }
@MainActor func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a != b, "Values unexpectedly equal", file: file, line: line) }
@MainActor func XCTAssertNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { check(value == nil, "Expected nil", file: file, line: line) }
@MainActor func XCTAssertNotNil<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) { check(value != nil, "Unexpected nil", file: file, line: line) }
@MainActor func XCTAssertLessThan<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a < b, "\(a) is not below \(b)", file: file, line: line) }
@MainActor func XCTAssertLessThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a <= b, "\(a) exceeds \(b)", file: file, line: line) }
@MainActor func XCTAssertGreaterThanOrEqual<T: Comparable>(_ a: T, _ b: T, file: StaticString = #filePath, line: UInt = #line) { check(a >= b, "\(a) is below \(b)", file: file, line: line) }
@MainActor func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try expression(); check(false, "Expected an error", file: file, line: line) } catch { }
}
@MainActor func XCTUnwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
    guard let value else { check(false, "Cannot unwrap nil", file: file, line: line); throw TestFailure() }; return value
}

@main struct StandaloneTests {
    @MainActor static func main() async {
        var completed = 0, skipped = 0
        let repository = RepositoryTests()
        let repositoryTests: [(String, () throws -> Void)] = [
            ("Persistence round trip and backup recovery", repository.testRoundTripAndBackupRecovery),
            ("Future format preservation", repository.testNewerVersionIsNeverSilentlyReplaced),
            ("Fresh library", repository.testFreshLibrary),
            ("Performance policies", repository.testPoliciesHaveRealDistinctLimits)
        ]
        for (name, test) in repositoryTests {
            let before = assertionFailures
            do { try repository.setUpWithError(); try test(); try repository.tearDownWithError() }
            catch { assertionFailures += 1; print("ERROR \(name): \(error)"); try? repository.tearDownWithError() }
            completed += 1; if before == assertionFailures { print("PASS \(name)") }
        }
        let media = MediaAndLibraryTests()
        let mediaTests: [(String, () async throws -> Void)] = [
            ("Image import, deduplication, metadata, assignment and persistence", media.testImageImportDeduplicationMetadataAndPersistence),
            ("Missing sources, relinking and invalid formats", media.testMissingFileRelinkAndInvalidMedia),
            ("Failed save rollback", media.testFailedSaveRollsBackState),
            ("Video metadata and concurrent resolution/fps conversion", media.testVideoMetadataAndConcurrentProxyGeneration),
            ("Rotated video metadata and orientation-preserving conversion", media.testRotatedVideoMetadataAndProxy),
            ("Cold launch and manual resume policy", media.testColdLaunchAndManualResumeAfterInterruption),
            ("Display detection, looping, pause, sleep/wake and restoration", media.testDisplayDetectionAndEngineLifecycle)
        ]
        for (name, test) in mediaTests {
            let before = assertionFailures
            do { try await media.setUp(); try await test(); try await media.tearDown() }
            catch let skip as XCTSkip { skipped += 1; print("SKIP \(name): \(skip.reason)"); try? await media.tearDown() }
            catch { assertionFailures += 1; print("ERROR \(name): \(error)"); try? await media.tearDown() }
            completed += 1; if before == assertionFailures { print("PASS \(name)") }
        }
        print("\(completed) tests, \(assertionFailures) failures, \(skipped) skipped")
        exit(assertionFailures == 0 ? 0 : 1)
    }
}
#endif
