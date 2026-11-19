import Foundation
import MdCore
import Testing
@testable import Dewline

struct AgentFilesTests {
    @Test func theEngineNamesAgentFiles() {
        #expect(isAgentFile(URL(filePath: "/repo/.claude/skills/pdf/SKILL.md")))
        #expect(!isAgentFile(URL(filePath: "/repo/README.md")))
    }

    @Test func frontMatterShowsAsOneLine() {
        #expect(frontMatterLine(of: "---\nname: reviewer\ndescription: Reviews diffs\ntools:\n  - Read\n---\n# Body\n")
            == "name: reviewer · description: Reviews diffs · tools")
        #expect(frontMatterLine(of: "---\r\nalwaysApply: true\r\n---\r\n") == "alwaysApply: true")
        #expect(frontMatterLine(of: "# No front matter\n") == nil)
        #expect(frontMatterLine(of: "---\nname: unclosed\n") == nil)
        #expect(frontMatterLine(of: "---\n---\nbody") == nil)
    }
}
