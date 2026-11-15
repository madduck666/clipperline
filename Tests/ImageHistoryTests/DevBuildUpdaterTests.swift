#if !STANDALONE_TESTS
import AppKit
import XCTest
@testable import Tendedero

@MainActor final class DevBuildUpdaterTests: XCTestCase {
    private let installed = String(repeating: "a", count: 40)
    private var info: [String: Any] {
        ["ClipBoardLineDevBuild": installed, "ClipBoardLineDevRepository": "synthetic/fork"]
    }
    private func finish(_ updater: DevBuildUpdater) async throws {
        for _ in 0..<100 {
            if !updater.busy { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Developer update check did not complete")
    }
    func testSuccessiveChecksDiscoverANewReleaseDespiteCachedURLs() async throws {
        var published = installed
        var cachedBodies: [URL: Data] = [:]
        var requests: [URLRequest] = []
        let updater = DevBuildUpdater(info: info, fetch: { request in
            let url = try XCTUnwrap(request.url)
            requests.append(request)
            let data = cachedBodies[url] ?? Data(published.utf8)
            cachedBodies[url] = data
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        updater.check(); try await finish(updater)
        XCTAssertNil(updater.availableBuild)
        published = String(repeating: "b", count: 40)
        updater.check(); try await finish(updater)
        XCTAssertEqual(updater.availableBuild, published)
        XCTAssertNil(updater.error)
        XCTAssertEqual(requests.count, 2)
        XCTAssertNotEqual(requests[0].url, requests[1].url)
        for request in requests {
            XCTAssertEqual(request.url?.host, "github.com")
            XCTAssertEqual(request.url?.path, "/synthetic/fork/releases/download/dev-latest/ClipBoardLine-Dev-build.txt")
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        }
    }
    func testInvalidOrFailedResponseClearsAnEarlierOffer() async throws {
        var body = String(repeating: "b", count: 40), status = 200
        let updater = DevBuildUpdater(info: info, fetch: { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        })
        updater.check(); try await finish(updater)
        XCTAssertEqual(updater.availableBuild, body)
        body = "<html>Not found</html>"
        updater.check(); try await finish(updater)
        XCTAssertNil(updater.availableBuild); XCTAssertNotNil(updater.error)
        body = String(repeating: "c", count: 40); status = 503
        updater.check(); try await finish(updater)
        XCTAssertNil(updater.availableBuild); XCTAssertNotNil(updater.error)
    }
    func testRepeatedClickDoesNotOverlapAnActiveRequest() async throws {
        var calls = 0
        let updater = DevBuildUpdater(info: info, fetch: { request in
            calls += 1
            try await Task.sleep(nanoseconds: 30_000_000)
            return (Data(self.installed.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        updater.check(); updater.check(); updater.check()
        try await finish(updater)
        XCTAssertEqual(calls, 1)
    }
}
#endif
