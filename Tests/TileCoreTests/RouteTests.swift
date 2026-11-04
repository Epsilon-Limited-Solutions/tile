import Foundation
import Testing
@testable import TileCore

struct RouteTests {
    private func parse(_ string: String) throws -> Route {
        try Route.parse(URL(string: string)!)
    }

    @Test func parsesEachRoute() throws {
        #expect(try parse("tile://apply?layout=left-half") == .apply(layout: "left-half"))
        #expect(try parse("tile://action?name=restore") == .action(name: "restore"))
        #expect(try parse("tile://arrange?id=work") == .arrange(id: "work"))
        #expect(try parse("tile://capture?name=work") == .capture(name: "work"))
        #expect(try parse("tile://selftest") == .selftest)
        #expect(try parse("tile://profile?id=desk") == .profile(id: "desk"))
        #expect(try parse("tile://profile") == .profile(id: nil))
    }

    @Test func parsesDebugCommandAndParams() throws {
        #expect(try parse("tile://debug/spaces") == .debug(command: "spaces", params: [:]))
        #expect(try parse("tile://debug/switch?display=2&desktop=3")
                == .debug(command: "switch", params: ["display": "2", "desktop": "3"]))
    }

    @Test func hostIsCaseInsensitive() throws {
        #expect(try parse("TILE://Apply?layout=full") == .apply(layout: "full"))
    }

    @Test func rejectsBadURLs() {
        #expect(throws: RouteError.notTileURL("https://example.com")) { try parse("https://example.com") }
        #expect(throws: RouteError.unknownRoute("nope")) { try parse("tile://nope") }
        #expect(throws: RouteError.unknownRoute("debug")) { try parse("tile://debug") }
        #expect(throws: RouteError.missingParameter(route: "apply", name: "layout")) { try parse("tile://apply") }
        #expect(throws: RouteError.missingParameter(route: "apply", name: "layout")) { try parse("tile://apply?layout=") }
    }
}
