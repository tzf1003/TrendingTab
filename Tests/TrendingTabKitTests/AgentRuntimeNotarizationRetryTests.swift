import Foundation
import XCTest
@testable import TrendingTabIntelligence

final class AgentRuntimeNotarizationRetryTests: XCTestCase {
    private actor Probe {
        var calls = 0
        var waits: [Duration] = []
        let failures: Int
        let failure: AgentRuntimeNotarizationFailure

        init(failures: Int, status: Int32 = 68, output: String = "Error Domain=NSURLErrorDomain Code=-1005") {
            self.failures = failures
            self.failure = AgentRuntimeNotarizationFailure(status: status, output: output)
        }
        func run() throws -> Data {
            calls += 1
            if calls <= failures { throw failure }
            return Data("validated".utf8)
        }
        func wait(_ delay: Duration) { waits.append(delay) }
    }

    func testRecoversAfterThreeTransportFailures() async throws {
        let probe = Probe(failures: 3)
        let result = try await AgentRuntimeNotarizationRetry.validate(run: { try await probe.run() }, wait: { await probe.wait($0) })
        XCTAssertEqual(result, Data("validated".utf8))
        let calls = await probe.calls
        let waits = await probe.waits
        XCTAssertEqual(calls, 4)
        XCTAssertEqual(waits, [.seconds(5), .seconds(15), .seconds(30)])
    }

    func testPersistentNetworkFailureStopsAfterFiveAttempts() async throws {
        let probe = Probe(failures: 10)
        do {
            _ = try await AgentRuntimeNotarizationRetry.validate(run: { try await probe.run() }, wait: { await probe.wait($0) })
            XCTFail("A persistent transport failure must stop installation")
        } catch let failure as AgentRuntimeNotarizationFailure { XCTAssertEqual(failure.status, 68) }
        let calls = await probe.calls
        let waits = await probe.waits
        XCTAssertEqual(calls, 5)
        XCTAssertEqual(waits, [.seconds(5), .seconds(15), .seconds(30), .seconds(60)])
    }

    func testTicketFailuresAreNotRetried() async throws {
        for (status, output) in [(Int32(68), "The ticket validation failed."), (65, "Record not found"),
                                 (1, "Error Domain=NSURLErrorDomain Code=-1005")] {
            let probe = Probe(failures: 10, status: status, output: output)
            do {
                _ = try await AgentRuntimeNotarizationRetry.validate(run: { try await probe.run() }, wait: { await probe.wait($0) })
                XCTFail("A failed trust decision must stop installation")
            } catch is AgentRuntimeNotarizationFailure { }
            let calls = await probe.calls
            let waits = await probe.waits
            XCTAssertEqual(calls, 1)
            XCTAssertTrue(waits.isEmpty)
        }
    }

    func testCancellationDuringBackoffStopsBeforeAnotherCommand() async throws {
        let probe = Probe(failures: 10)
        do {
            _ = try await AgentRuntimeNotarizationRetry.validate(run: { try await probe.run() }, wait: { _ in throw CancellationError() })
            XCTFail("Cancellation must stop retries")
        } catch is CancellationError { }
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
    }
}
