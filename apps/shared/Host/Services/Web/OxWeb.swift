import Foundation
import JavaScriptCore

nonisolated enum OxWeb {
    static let function = OxFunction(
        namespace: "web",
        schema: {
            [(
                "ox.web.fetch",
                .object([
                    "description": .string(ModelGuidance.text("ox.web.fetch")),
                    "inputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "url": .object([
                                "type": .string("string"),
                                "minLength": .int(1),
                                "description": .string("Public HTTP or HTTPS resource URL."),
                            ]),
                            "options": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "maxBytes": .object([
                                        "type": .string("integer"),
                                        "minimum": .int(1),
                                        "maximum": .int(FileLimits.fileBytes),
                                        "description": .string("Maximum text or feed field bytes to return. Feeds default to 64 KiB and at most 100 entries."),
                                    ]),
                                    "maxPages": .object([
                                        "type": .string("integer"),
                                        "minimum": .int(1),
                                        "description": .string("Maximum PDF pages to read as text."),
                                    ]),
                                ]),
                                "additionalProperties": .bool(false),
                            ]),
                            "purpose": .object([
                                "type": .string("string"),
                                "minLength": .int(1),
                                "description": .string("Short (<10 words) description of why you're fetching the resource, shown to the user as the step label."),
                            ]),
                        ]),
                        "required": .array([.string("url"), .string("purpose")]),
                        "additionalProperties": .bool(false),
                    ]),
                    "outputSchema": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "ok": .object(["type": .string("boolean")]),
                            "status": .object(["type": .string("integer")]),
                            "statusText": .object(["type": .string("string")]),
                            "url": .object(["type": .string("string")]),
                            "redirected": .object(["type": .string("boolean")]),
                            "headers": .object([
                                "type": .string("object"),
                                "additionalProperties": .object(["type": .string("string")]),
                            ]),
                            "kind": .object([
                                "type": .string("string"),
                                "enum": .array(["image", "pdf", "text", "html", "file", "feed"].map(JSONValue.string)),
                            ]),
                            "feed": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "entries": .object([
                                        "type": .string("array"),
                                        "maxItems": .int(100),
                                        "items": .object([
                                            "type": .string("object"),
                                            "additionalProperties": .object(["type": .string("string")]),
                                        ]),
                                    ]),
                                ]),
                                "required": .array([.string("entries")]),
                                "additionalProperties": .object(["type": .string("string")]),
                            ]),
                            "filename": .object(["type": .string("string")]),
                            "bytes": .object(["type": .string("integer")]),
                            "text": .object(["type": .array([.string("string"), .string("null")])]),
                            "truncated": .object(["type": .string("boolean")]),
                            "attached": .object(["type": .string("boolean"), "const": .bool(false), "description": .string("Always false; use ox.fs.attach with url to attach the original file explicitly.")]),
                            "unsupported": .object(["type": .array([.string("string"), .string("null")])]),
                        ]),
                        "required": .array([
                            .string("ok"), .string("status"), .string("statusText"),
                            .string("url"), .string("redirected"), .string("headers"),
                            .string("kind"), .string("filename"), .string("bytes"),
                            .string("text"), .string("truncated"), .string("attached"),
                            .string("unsupported"),
                        ]),
                        "additionalProperties": .bool(false),
                    ]),
                ])
            )] + BrowserFunctionCatalog.actions.map { ($0.name, $0.functionSchema) }
        },
        installNatives: { ctx, env in
            let fetch: @convention(block) (String, JSValue, JSValue) -> JSValue = { url, options, purpose in
                let purpose = purpose.toString()!
                return env.call {
                    try await $0.fetchWeb(url: url, options: jsValueToJSON(options), purpose: purpose)
                }
            }
            ctx.setObject(fetch as AnyObject, forKeyedSubscript: "__nativeWebFetch" as NSString)
            let browser: @convention(block) (String, JSValue) -> JSValue = { action, options in
                var fields = jsValueToJSON(options)?.objectValue ?? [:]
                let purpose = fields.removeValue(forKey: "purpose")?.stringValue ?? ""
                let arguments = JSONValue.object(fields)
                return env.call(suspendingTimeout: action == "waitForURL" || action == "showPage") {
                    try await $0.browserOperation(action: action, arguments: arguments, purpose: purpose)
                }
            }
            ctx.setObject(browser as AnyObject, forKeyedSubscript: "__nativeWebBrowser" as NSString)
        },
        jsFragment: """
          fetch: (value) => { const options = __oxOptions(value, 'ox.web.fetch'); return __nativeWebFetch(String(options.url), options.options ?? null, String(options.purpose)); },
          browser: {
            newPage: (value) => __nativeWebBrowser('newPage', __oxOptions(value, 'ox.web.browser.newPage')),
            pages: (value) => __nativeWebBrowser('pages', __oxOptions(value, 'ox.web.browser.pages')),
            frames: (value) => __nativeWebBrowser('frames', __oxOptions(value, 'ox.web.browser.frames')),
            close: (value) => __nativeWebBrowser('close', __oxOptions(value, 'ox.web.browser.close')),
            goto: (value) => __nativeWebBrowser('goto', __oxOptions(value, 'ox.web.browser.goto')),
            reload: (value) => __nativeWebBrowser('reload', __oxOptions(value, 'ox.web.browser.reload')),
            goBack: (value) => __nativeWebBrowser('goBack', __oxOptions(value, 'ox.web.browser.goBack')),
            goForward: (value) => __nativeWebBrowser('goForward', __oxOptions(value, 'ox.web.browser.goForward')),
            snapshot: (value) => __nativeWebBrowser('snapshot', __oxOptions(value, 'ox.web.browser.snapshot')),
            waitForURL: (value) => __nativeWebBrowser('waitForURL', __oxOptions(value, 'ox.web.browser.waitForURL')),
            showPage: (value) => __nativeWebBrowser('showPage', __oxOptions(value, 'ox.web.browser.showPage')),
            evaluate: (value) => __nativeWebBrowser('evaluate', __oxOptions(value, 'ox.web.browser.evaluate')),
            pdf: (value) => __nativeWebBrowser('pdf', __oxOptions(value, 'ox.web.browser.pdf')),
            screenshot: (value) => __nativeWebBrowser('screenshot', __oxOptions(value, 'ox.web.browser.screenshot')),
            addInitScript: (value) => __nativeWebBrowser('addInitScript', __oxOptions(value, 'ox.web.browser.addInitScript')),
            startCapture: (value) => __nativeWebBrowser('startCapture', __oxOptions(value, 'ox.web.browser.startCapture')),
            markCapture: (value) => __nativeWebBrowser('markCapture', __oxOptions(value, 'ox.web.browser.markCapture')),
            listCapturedEvents: (value) => __nativeWebBrowser('listCapturedEvents', __oxOptions(value, 'ox.web.browser.listCapturedEvents')),
            readCapturedEvent: (value) => __nativeWebBrowser('readCapturedEvent', __oxOptions(value, 'ox.web.browser.readCapturedEvent')),
            stopCapture: (value) => __nativeWebBrowser('stopCapture', __oxOptions(value, 'ox.web.browser.stopCapture'))
          }
        """
    )
}
