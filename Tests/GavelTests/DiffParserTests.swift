import XCTest

@testable import Gavel

final class DiffParserTests: XCTestCase {

    private let multiFileFixture = """
    diff --git a/Sources/A.swift b/Sources/A.swift
    index 1111111..2222222 100644
    --- a/Sources/A.swift
    +++ b/Sources/A.swift
    @@ -10,7 +10,8 @@ struct A {
     context1
    -old line
    +new line
    +added line
     context2
    @@ -40,3 +41,3 @@
     c
    -x
    +y
     d
    diff --git a/B.txt b/B.txt
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/B.txt
    @@ -0,0 +1,2 @@
    +hello
    +world
    """

    func testMultiFileMultiHunk() {
        let files = DiffParser.parse(multiFileFixture)
        XCTAssertEqual(files.count, 2)

        let a = files[0]
        XCTAssertEqual(a.displayPath, "Sources/A.swift")
        XCTAssertEqual(a.hunks.count, 2)
        XCTAssertEqual(a.hunks[0].newStart, 10)
        XCTAssertEqual(a.hunks[1].newStart, 41)
        XCTAssertEqual(a.additions, 3)
        XCTAssertEqual(a.deletions, 2)
        XCTAssertFalse(a.isNew)

        let b = files[1]
        XCTAssertEqual(b.displayPath, "B.txt")
        XCTAssertTrue(b.isNew)
        XCTAssertEqual(b.additions, 2)
        XCTAssertEqual(b.deletions, 0)
    }

    func testLineNumbering() {
        let files = DiffParser.parse(multiFileFixture)
        let lines = files[0].hunks[0].lines
        XCTAssertEqual(lines[0].kind, .context)
        XCTAssertEqual(lines[0].newNumber, 10)
        XCTAssertEqual(lines[1].kind, .deletion)
        XCTAssertEqual(lines[1].oldNumber, 11)
        XCTAssertNil(lines[1].newNumber)
        XCTAssertEqual(lines[2].kind, .addition)
        XCTAssertEqual(lines[2].newNumber, 11)
        XCTAssertEqual(lines[3].newNumber, 12)
        XCTAssertEqual(lines[4].kind, .context)
        XCTAssertEqual(lines[4].oldNumber, 12)
        XCTAssertEqual(lines[4].newNumber, 13)
    }

    func testRename() {
        let fixture = """
        diff --git a/old.txt b/new.txt
        similarity index 90%
        rename from old.txt
        rename to new.txt
        index 1111111..2222222 100644
        --- a/old.txt
        +++ b/new.txt
        @@ -1,2 +1,2 @@
        -a
        +b
         c
        """
        let files = DiffParser.parse(fixture)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isRename)
        XCTAssertEqual(files[0].oldPath, "old.txt")
        XCTAssertEqual(files[0].newPath, "new.txt")
        XCTAssertEqual(files[0].hunks.count, 1)
    }

    func testBinaryNewFile() {
        let fixture = """
        diff --git a/img.png b/img.png
        new file mode 100644
        index 0000000..1111111
        Binary files /dev/null and b/img.png differ
        """
        let files = DiffParser.parse(fixture)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isBinary)
        XCTAssertTrue(files[0].isNew)
        XCTAssertTrue(files[0].hunks.isEmpty)
    }

    func testDeletedFile() {
        let fixture = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1111111..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -bye
        """
        let files = DiffParser.parse(fixture)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].isDeleted)
        XCTAssertEqual(files[0].displayPath, "gone.txt")
        XCTAssertEqual(files[0].deletions, 1)
    }

    func testNoNewlineMarker() {
        let fixture = """
        diff --git a/x.txt b/x.txt
        index 1111111..2222222 100644
        --- a/x.txt
        +++ b/x.txt
        @@ -1,1 +1,1 @@
        -a
        +b
        \\ No newline at end of file
        """
        let files = DiffParser.parse(fixture)
        XCTAssertEqual(files[0].hunks[0].lines.last?.kind, .meta)
    }

    func testEmptyInput() {
        XCTAssertTrue(DiffParser.parse("").isEmpty)
    }
}
