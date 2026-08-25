import XCTest
@testable import PhrenKit

/// `.phren-team.yaml` is the only store marker that travels *inside* the repo
/// it describes, which is what makes it usable from a phone: `stores.yaml`
/// lives at the primary store's root, and a team store repo never contains
/// one. Shape is `readTeamBootstrap` (store-registry.ts:220) against the file
/// `phren team init` writes (cli/team.ts:80).
final class TeamBootstrapTests: XCTestCase {
    func testParsesWhatTeamInitWrites() throws {
        let bootstrap = try XCTUnwrap(TeamBootstrap.parse("""
        name: arc-team
        description: arc-team team knowledge
        default_role: team
        """))
        XCTAssertEqual(bootstrap.name, "arc-team")
        XCTAssertEqual(bootstrap.description, "arc-team team knowledge")
        XCTAssertEqual(bootstrap.defaultRole, "team")
        XCTAssertEqual(bootstrap.role, "team")
    }

    /// The CLI's one rejection rule: no string `name`, no bootstrap
    /// (store-registry.ts:227).
    func testNameIsRequired() {
        XCTAssertNil(TeamBootstrap.parse("description: no name\n"))
        XCTAssertNil(TeamBootstrap.parse(""))
        XCTAssertNil(TeamBootstrap.parse("name:\n"))
    }

    /// A bootstrap that names no role still means team — the file only exists
    /// in a store created by `phren team init`, which always writes
    /// `default_role: team`.
    func testMissingRoleStillMeansTeam() throws {
        let bootstrap = try XCTUnwrap(TeamBootstrap.parse("name: arc-team\n"))
        XCTAssertNil(bootstrap.defaultRole)
        XCTAssertEqual(bootstrap.role, "team")
    }

    /// store-registry.ts:231 — a `default_role` outside the three known roles
    /// is dropped rather than believed.
    func testUnknownRoleIsDropped() throws {
        let bootstrap = try XCTUnwrap(TeamBootstrap.parse("name: arc-team\ndefault_role: overlord\n"))
        XCTAssertNil(bootstrap.defaultRole)
        XCTAssertEqual(bootstrap.role, "team")

        let readonly = try XCTUnwrap(TeamBootstrap.parse("name: vendor-docs\ndefault_role: readonly\n"))
        XCTAssertEqual(readonly.role, "readonly")
    }

    func testReadsTolerantly() throws {
        let bootstrap = try XCTUnwrap(TeamBootstrap.parse("""
        # hand-edited
        name: "arc-team"
        description: 'Shared: the arc platform team'
        default_role: team
        future_key: something the app has never heard of
        """))
        XCTAssertEqual(bootstrap.name, "arc-team")
        // Split on the first colon, so an unquoted description containing one
        // survives here even though js-yaml would refuse the whole file.
        XCTAssertEqual(bootstrap.description, "Shared: the arc platform team")
        XCTAssertEqual(bootstrap.role, "team")

        // CRLF, and indented lines (which belong to a nested structure this
        // shape doesn't have) are ignored rather than mistaken for keys.
        let crlf = try XCTUnwrap(TeamBootstrap.parse("name: arc-team\r\n  nested: value\r\ndefault_role: team\r\n"))
        XCTAssertEqual(crlf.name, "arc-team")
        XCTAssertEqual(crlf.role, "team")
    }

    /// The registry is the fallback signal, and `role` is what routing keys
    /// off — not the `projects:` claim list, because the app always writes to
    /// a specific (store, project) pair, which is the CLI's store-qualified
    /// form (`resolveStoreForProject`, tools/types.ts:105).
    func testStoresManifestStillCarriesTheRole() {
        let manifest = StoresManifest.parse("""
        version: 1
        stores:
          - id: 365c6bb8
            name: phren
            path: ~/.phren
            role: primary
            sync: managed-git
          - id: 67d3e4c9
            name: work-shared
            path: ~/.phren-work-shared
            role: team
            sync: managed-git
            projects:
              - alpha
              - beta
        """)
        XCTAssertEqual(manifest.stores.map(\.role), ["primary", "team"])
        XCTAssertEqual(manifest.stores.first { $0.name == "work-shared" }?.projects, ["alpha", "beta"])
        // A project physically in the team store isn't "claimed elsewhere" —
        // which is exactly why claim badges can't answer the routing question.
        XCTAssertNil(manifest.claimingEntry(for: "alpha", physicalStoreName: "work-shared"))
        XCTAssertEqual(manifest.claimingEntry(for: "alpha", physicalStoreName: "phren")?.role, "team")
    }
}
