import Foundation

extension Scenario {
    static let markdown = Scenario(name: "markdown", steps: [
        .say("""
        # Mock markdown

        Paragraph with **bold**, *italic*, and `inline code`.

        - bullet one
        - bullet two with a [link](https://example.com)
        - bullet three

        - **nested group one**
          - nested item with enough text to wrap onto another line
          - nested item two
        - **nested group two**
          - nested item three

        1. ordered one
        2. ordered two
        3. ordered three
        4. ordered four
        5. ordered five
        6. ordered six
        7. ordered seven
        8. ordered eight
        9. ordered item with enough text to wrap onto another line
        10. ordered ten

        ```swift
        let answer = 42
        print(answer)
        ```

        > A blockquote, for good measure.

        | col a | col b |
        | ----- | ----- |
        | one   | two   |
        """),
        .stop(.stop)
    ])

    static let interleaved = Scenario(name: "interleave", steps: [
        .think("First, restate the question to make sure I understand it."),
        .say("Let me work through this in a few passes.\n\n"),
        .think("Pass two: weigh the options against each other."),
        .say("The trade-off comes down to latency versus cost.\n\n"),
        .think("Pass three: land on a recommendation."),
        .say("I'd go with the cheaper option — the latency difference is imperceptible here."),
        .stop(.stop)
    ])

    static let cjk = Scenario(name: "cjk", steps: [
        .say("""
        # 中文与表情符号 🍑

        这是一段**混合**的文字，用来测试 CJK 排版、换行，以及 emoji 🎉 的渲染。

        - 第一项：阳光 ☀️
        - 第二项：成熟的桃子 🍑
        - 第三项：`等宽代码`

        > 混合标点测试（故意保留半角标点）：Hello,世界!

        | 名称 | 描述 | 链接 | 状态 |
        | ---- | ---- | ---- | ---- |
        | 桃子 | 香甜、多汁、适合做甜点 | [官网](https://example.com/peach) | ✅ 成熟 |
        | 阳光 | 明亮，适合户外散步 | [天气](https://example.com/weather) | ☀️ 晴朗 |
        | 等宽代码 | `let fruit = "🍑"` | [文档](https://example.com/docs) | ⌘ 可复制 |
        | 世界 | 你好，世界！ | [地图](https://example.com/map) | 🌏 在线 |
        """),
        .stop(.stop)
    ])

    static let longOutput = Scenario(name: "long", steps: [
        .say(String(repeating: "Lorem ipsum dolor sit amet, consectetur adipiscing elit. ", count: 120)),
        .stop(.stop)
    ])

    static let thinkingOnly = Scenario(name: "thinking", steps: [
        .think("""
        **Weighing the request**

        Long internal reasoning that should collapse in the UI by default. Step one, step two, step three.

        **Settling on an answer**

        The sections above mirror how reasoning summaries arrive: each part opens with a bold headline.
        """),
        .say("Done."),
        .stop(.stop)
    ])

    static let slowThinking = Scenario(name: "thinkslow", steps: [
        .think("Reasoning slowly so the live thinking row stays on screen."),
        .wait(.seconds(4)),
        .think("Still working — the loader should sit centered on this line."),
        .wait(.seconds(4)),
        .say("Done."),
        .stop(.stop)
    ])

    private static let streamingMarkdown = """
        ## Streaming markdown demo

        Watch the leading edge: every word fades in softly, and **bold**, *italic*, and `inline code` \
        style themselves from the opening marker instead of snapping when the closer arrives.

        - bullets render as bullets from their first word
        - the dot and indent never reflow
        - only the last item's tail fades

        1. ordered lists too
        2. numbers appear immediately

        ```swift
        let answer = 42
        print("code streams inside its container", answer)
        ```

        > A quote keeps its bar and muted color while streaming.

        | fruit | color | taste |
        | --- | --- | --- |
        | peach | pink | sweet |
        | lime | green | sharp |

        A closing paragraph after the blank line: the settled blocks above must not move by a single pixel \
        while these words fade in at the tail.
        """

    static let fastStream = Scenario(name: "faststream", steps: [
        .say(streamingMarkdown),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(0))

    static let characterStream = Scenario(name: "characterstream", steps: [
        .say("The opening phrase is almost full: extraordinaryphenomenon arrives next."),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(80)).characterStreaming()

    static let focusedStream = Scenario(name: "focusstream") { _ in
        let prefix = (1...20).map { "Focus setup line \($0)." }.joined(separator: "\n")
        let continuation = (1...18).map { "Focus continuation line \($0)." }.joined(separator: "\n")
        return [
            .say("\(prefix)\nFocus checkpoint."),
            .wait(.seconds(4)),
            .say("\(continuation)\nFocus continuation complete."),
            .stop(.stop),
        ]
    }.pacing(betweenDeltas: .milliseconds(0))

    static let selectableCodeStream = Scenario(name: "selectcode", steps: [
        .say("""
        ```swift
        let answer = 42
        """),
        .wait(.seconds(8)),
        .say("""
        print(answer)
        ```
        """),
        .stop(.stop),
    ])

    static let backgroundStream = Scenario(name: "background", steps: [
        .wait(.seconds(3)),
        .say(String(repeating: "Background streaming must preserve the reader's position. ", count: 15)),
        .stop(.stop),
    ])

    static let errorMidstream = Scenario(name: "error", steps: [
        .say("Starting some work…"),
        .fail(message: "mock provider failure", reason: .error)
    ])

    static let slowFirstToken = Scenario(name: "slow", steps: [
        .wait(.seconds(3)),
        .say("Sorry that took a moment."),
        .stop(.stop)
    ])

    static let truncated = Scenario(name: "truncated", steps: [
        .say(String(repeating: "This answer keeps going and going until the model hits its token ceiling ", count: 12)),
        .stop(.length)
    ])

    static let longProse = Scenario(name: "longprose", steps: [
        .say(longMarkdown(sections: 120, codeEvery: nil)),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(2))

    static let longMixed = Scenario(name: "longmixed", steps: [
        .say(longMarkdown(sections: 120, codeEvery: 10)),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(2))

    static let burstStream = Scenario(name: "burststream", steps: [
        .say(longMarkdown(sections: 8, codeEvery: 4)),
        .stop(.stop)
    ]).pacing(betweenDeltas: .milliseconds(150)).bursts(of: 8)

    private static func longMarkdown(sections: Int, codeEvery: Int?) -> String {
        (1...sections).map { index in
            let code = codeEvery.map { index.isMultiple(of: $0) } == true
                ? "```swift\nlet section = \(index)\nprint(\"section \\(section) settled\")\n```\n\n"
                : ""
            return """
            ## Section \(index): streaming layout

            Section \(index) opens with **bold claims**, *quiet asides*, `inline code`, and a \
            [reference link](https://example.com/\(index)) so every inline style appears. The paragraph runs long \
            enough to wrap several times on a phone and keeps the text system busy measuring lines.

            - First point for section \(index) with **emphasis** and enough words to wrap onto a second line
            - Second point that mentions `value\(index)` inline
              - Nested detail one under the second point
              - Nested detail two with *italic* text
            - Third point closing the list

            1. Ordered step one for section \(index)
            2. Ordered step two with a longer explanation that wraps across lines on narrow screens
            3. Ordered step three

            \(code)A closing paragraph for section \(index) ties the points together before the next heading.


            """
        }.joined()
    }

    static let empty = Scenario(name: "empty", steps: [
        .stop(.stop)
    ])
}
