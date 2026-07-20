import XCTest
@testable import DBKit

final class SSHConfigFileTests: XCTestCase {

    private let sample = """
        # comment
        Host bastion
            HostName bastion.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_bastion

        Host db-*
            User dbadmin
            IdentityFile ~/.ssh/id_shared

        Host *
            IdentityFile ~/.ssh/id_default
        """

    func testResolvesAllDirectives() {
        let blocks = SSHConfigFile.parse(sample)
        let resolved = SSHConfigFile.resolve("bastion", in: blocks)
        XCTAssertEqual(resolved.hostName, "bastion.example.com")
        XCTAssertEqual(resolved.user, "deploy")
        XCTAssertEqual(resolved.port, 2222)
        XCTAssertEqual(resolved.identityFile, "~/.ssh/id_bastion")
    }

    /// A wildcard block fills in what the alias itself didn't set, and an alias with
    /// no HostName resolves to itself — both match ssh's behaviour.
    func testWildcardFillsGapsAndAliasIsItsOwnHostname() {
        let blocks = SSHConfigFile.parse(sample)
        let resolved = SSHConfigFile.resolve("db-prod", in: blocks)
        XCTAssertEqual(resolved.hostName, "db-prod")
        XCTAssertEqual(resolved.user, "dbadmin")
        XCTAssertNil(resolved.port)
        XCTAssertEqual(resolved.identityFile, "~/.ssh/id_shared")
    }

    /// OpenSSH keeps the first value it obtains, so an earlier block wins.
    func testFirstValueWins() {
        let blocks = SSHConfigFile.parse("""
            Host a
                User first
            Host *
                User second
            """)
        XCTAssertEqual(SSHConfigFile.resolve("a", in: blocks).user, "first")
    }

    func testOnlyFirstIdentityFileIsUsed() {
        let blocks = SSHConfigFile.parse("""
            Host a
                IdentityFile ~/.ssh/one
                IdentityFile ~/.ssh/two
            """)
        XCTAssertEqual(SSHConfigFile.resolve("a", in: blocks).identityFile, "~/.ssh/one")
    }

    func testKeywordSyntaxVariants() {
        let blocks = SSHConfigFile.parse("""
            Host a
              HOSTNAME = quoted.example.com
              user\t tabbed
            """)
        let resolved = SSHConfigFile.resolve("a", in: blocks)
        XCTAssertEqual(resolved.hostName, "quoted.example.com")
        XCTAssertEqual(resolved.user, "tabbed")
    }

    func testIncludeIsExpandedInPlace() {
        let blocks = SSHConfigFile.parse("""
            Include work/*
            Host home
                HostName home.example.com
            """) { pattern in
            pattern == "work/*" ? ["Host office\n    HostName office.example.com"] : []
        }
        XCTAssertEqual(SSHConfigFile.resolve("office", in: blocks).hostName, "office.example.com")
        XCTAssertEqual(SSHConfigFile.resolve("home", in: blocks).hostName, "home.example.com")
    }

    func testNegatedPatternExcludes() {
        XCTAssertTrue(SSHConfigFile.matches("db-prod", patterns: ["db-*"]))
        XCTAssertFalse(SSHConfigFile.matches("db-prod", patterns: ["db-*", "!db-prod"]))
    }

    func testGlob() {
        XCTAssertTrue(SSHConfigFile.glob("db-*", matches: "db-prod"))
        XCTAssertTrue(SSHConfigFile.glob("*", matches: "anything"))
        XCTAssertTrue(SSHConfigFile.glob("h?st", matches: "host"))
        XCTAssertFalse(SSHConfigFile.glob("db-*", matches: "web-prod"))
        XCTAssertFalse(SSHConfigFile.glob("h?st", matches: "haste"))
    }

    /// Only literal names are offered in the picker — wildcards aren't hosts.
    func testAliasesSkipWildcards() {
        XCTAssertEqual(SSHConfigFile.aliases(in: SSHConfigFile.parse(sample)), ["bastion"])
    }
}
