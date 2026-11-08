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
                let waitsForUser = action == "showPage" && fields["waitForUserInteraction"]?.boolValue == true
                return env.call(suspendingTimeout: waitsForUser || action == "waitForNavigation") {
                    try await $0.browserOperation(action: action, arguments: .object(fields), purpose: purpose)
                }
            }
            ctx.setObject(browser as AnyObject, forKeyedSubscript: "__nativeWebBrowser" as NSString)
        },
        jsFragment: """
          fetch: (value) => { const options = __oxOptions(value, 'ox.web.fetch'); return __nativeWebFetch(String(options.url), options.options ?? null, String(options.purpose)); },
          browser: {
            navigate: (value) => __nativeWebBrowser('navigate', __oxOptions(value, 'ox.web.browser.navigate')),
            reload: (value) => __nativeWebBrowser('reload', __oxOptions(value, 'ox.web.browser.reload')),
            stopLoading: (value) => __nativeWebBrowser('stopLoading', __oxOptions(value, 'ox.web.browser.stopLoading')),
            goBack: (value) => __nativeWebBrowser('goBack', __oxOptions(value, 'ox.web.browser.goBack')),
            goForward: (value) => __nativeWebBrowser('goForward', __oxOptions(value, 'ox.web.browser.goForward')),
            getNavigationHistory: (value) => __nativeWebBrowser('getNavigationHistory', __oxOptions(value, 'ox.web.browser.getNavigationHistory')),
            getPageState: (value) => __nativeWebBrowser('getPageState', __oxOptions(value, 'ox.web.browser.getPageState')),
            waitForNavigation: (value) => __nativeWebBrowser('waitForNavigation', __oxOptions(value, 'ox.web.browser.waitForNavigation')),
            showPage: (value) => __nativeWebBrowser('showPage', __oxOptions(value, 'ox.web.browser.showPage')),
            executeScript: (value) => __nativeWebBrowser('executeScript', __oxOptions(value, 'ox.web.browser.executeScript')),
            exportPdf: (value) => __nativeWebBrowser('exportPdf', __oxOptions(value, 'ox.web.browser.exportPdf')),
            injectScript: (value) => __nativeWebBrowser('injectScript', __oxOptions(value, 'ox.web.browser.injectScript')),
            clearScripts: (value) => __nativeWebBrowser('clearScripts', __oxOptions(value, 'ox.web.browser.clearScripts')),
            startCapture: (value) => __nativeWebBrowser('startCapture', __oxOptions(value, 'ox.web.browser.startCapture')),
            markCapture: (value) => __nativeWebBrowser('markCapture', __oxOptions(value, 'ox.web.browser.markCapture')),
            listCapturedEvents: (value) => __nativeWebBrowser('listCapturedEvents', __oxOptions(value, 'ox.web.browser.listCapturedEvents')),
            readCapturedEvent: (value) => __nativeWebBrowser('readCapturedEvent', __oxOptions(value, 'ox.web.browser.readCapturedEvent')),
            stopCapture: (value) => __nativeWebBrowser('stopCapture', __oxOptions(value, 'ox.web.browser.stopCapture'))
          }
        """
    )
}
