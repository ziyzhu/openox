import Foundation

@main
struct PublicSuffixListTests {
    static func main() {
        let list = WebsitePublicSuffixList.bundled
        let cases: [(String, String?)] = [
            ("login.example.com", "example.com"),
            ("api.example.co.uk", "example.co.uk"),
            ("example.com.cn", "example.com.cn"),
            ("co.uk", nil),
            ("com", nil),
            ("localhost", nil),
            ("", nil),
            ("a..com", nil),
            ("example.unknown", "example.unknown"),
            ("deep.example.unknown", "example.unknown"),
            ("notgithub.io", "notgithub.io"),
            ("github.io", nil),
            ("alice.github.io", "alice.github.io"),
            ("bob.github.io", "bob.github.io"),
            ("deep.alice.github.io", "alice.github.io"),
            ("alice.blogspot.com", "alice.blogspot.com"),
            ("a.ck", nil),
            ("a.b.ck", "a.b.ck"),
            ("deep.a.b.ck", "a.b.ck"),
            ("www.ck", "www.ck"),
            ("deep.www.ck", "www.ck"),
            ("foo.kawasaki.jp", nil),
            ("a.foo.kawasaki.jp", "a.foo.kawasaki.jp"),
            ("city.kawasaki.jp", "city.kawasaki.jp"),
            ("deep.city.kawasaki.jp", "city.kawasaki.jp"),
            ("xn--55qx5d.cn", nil), // 公司.cn: list entries are Unicode, lookup is IDNA ASCII.
            ("xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"),
        ]
        for (host, expected) in cases {
            check(list.effectiveTLDPlusOne(host) == expected, "lookup \(host)")
        }

        // Longest rule wins even when an exact rule overlaps a wildcard.
        let custom = WebsitePublicSuffixList(text: "// comment\r\ncom\r\n*.example\r\nlong.foo.example // inline\r\n!city.example\r\n公司.cn\r\n")
        check(custom.effectiveTLDPlusOne("a.long.foo.example") == "a.long.foo.example", "longest exact rule")
        check(custom.effectiveTLDPlusOne("deep.city.example") == "city.example", "exception rule")
        check(custom.effectiveTLDPlusOne("xn--85x722f.xn--55qx5d.cn") == "xn--85x722f.xn--55qx5d.cn", "IDNA list rule")
        print("Public Suffix List: \(cases.count + 3) boundary checks passed")
    }

    private static func check(_ condition: Bool, _ message: String) {
        guard !condition else { return }
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}
