import Foundation

func expect(_ condition: Bool, _ message: String) {
    if !condition {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

func edit(_ oldText: String, _ newText: String) -> ExactTextReplacement.Edit {
    ExactTextReplacement.Edit(oldText: oldText, newText: newText)
}

func failure(_ edits: [ExactTextReplacement.Edit], _ text: String) -> ExactTextReplacement.Failure? {
    do {
        _ = try ExactTextReplacement.apply(edits, to: text)
        return nil
    } catch {
        return error as? ExactTextReplacement.Failure
    }
}

@main
struct ExactTextReplacementTests {
    static func main() throws {
        let lf = try ExactTextReplacement.apply([edit("two", "2"), edit("four", "4")], to: "one\ntwo\nthree\nfour\n")
        expect(lf == .init(text: "one\n2\nthree\n4\n", firstChangedLine: 2), "applies disjoint edits against the original: \(lf)")

        let crlf = try ExactTextReplacement.apply([edit("a\nb", "a\nB\nc")], to: "x\r\na\r\nb\r\n")
        expect(crlf == .init(text: "x\r\na\r\nB\r\nc\r\n", firstChangedLine: 2), "matches LF edits in CRLF files and restores CRLF: \(crlf)")

        let crlfEdit = try ExactTextReplacement.apply([edit("a\r\nb", "ab")], to: "a\nb\n")
        expect(crlfEdit.text == "ab\n", "matches CRLF edits in LF files: \(crlfEdit)")

        let append = try ExactTextReplacement.apply([edit("", "c\n")], to: "a\nb\n")
        expect(append == .init(text: "a\nb\nc\n", firstChangedLine: 3), "appends with empty oldText: \(append)")

        expect(failure([], "a") == .emptyEdits, "rejects empty edits")
        expect(failure([edit("", "x"), edit("a", "b")], "a") == .appendAmbiguous, "rejects append mixed with replacements")
        expect(failure([edit("a", "b"), edit("z", "y")], "a") == .missing(index: 1), "reports missing edit index")
        expect(failure([edit("a", "b")], "a a") == .ambiguous(index: 0, matches: 2), "reports ambiguous edit index")
        expect(failure([edit("cd", "x"), edit("abc", "y")], "abcd") == .overlapping(1, 0), "reports overlapping edit indexes")
        expect(failure([edit("a", "a")], "a") == .unchanged, "rejects edits that change nothing")
        expect(failure([edit("", "")], "a") == .unchanged, "rejects empty appends")
        expect(ExactTextReplacement.count("a", in: "aXa") == 2, "counts matches")
        expect(ExactTextReplacement.count("", in: "a") == 0, "counts no matches for empty text")
    }
}
