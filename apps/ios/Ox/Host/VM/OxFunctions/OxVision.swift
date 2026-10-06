import Foundation
import JavaScriptCore

nonisolated enum OxVision {
    static let function = OxFunction(
        namespace: "vision",
        schema: {
            [("ox.vision.analyze", .object([
                "description": .string(ModelGuidance.text("ox.vision.analyze")),
                "inputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Artifact basename, artifacts/<filename>, or files/<folder-id>/<image> inside a selected folder."),
                        ]),
                    ]),
                    "required": .array([.string("source")]),
                ]),
                "outputSchema": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "filename": .object(["type": .string("string")]),
                        "mimeType": .object(["type": .string("string")]),
                        "pixelWidth": .object(["type": .string("integer")]),
                        "pixelHeight": .object(["type": .string("integer")]),
                        "recognizedText": .object(["type": .string("string")]),
                        "recognizedTextTruncated": .object(["type": .string("boolean")]),
                        "classifications": .object([
                            "type": .string("array"),
                            "items": .object([
                                "type": .string("object"),
                                "properties": .object([
                                    "label": .object(["type": .string("string")]),
                                    "confidence": .object(["type": .string("number")]),
                                ]),
                                "required": .array([.string("label"), .string("confidence")]),
                                "additionalProperties": .bool(false),
                            ]),
                        ]),
                        "processing": .object(["type": .string("string"), "const": .string("on-device")]),
                    ]),
                    "required": .array([
                        .string("filename"),
                        .string("mimeType"),
                        .string("pixelWidth"),
                        .string("pixelHeight"),
                        .string("recognizedText"),
                        .string("recognizedTextTruncated"),
                        .string("classifications"),
                        .string("processing"),
                    ]),
                    "additionalProperties": .bool(false),
                ]),
            ]))]
        },
        installNatives: { context, env in
            let analyze: @convention(block) (String, JSValue) -> JSValue = { source, purpose in
                env.call { try await $0.analyzeVision(filename: source, purpose: purpose.toString()!) }
            }
            context.setObject(analyze as AnyObject, forKeyedSubscript: "__nativeVisionAnalyze" as NSString)
        },
        jsFragment: """
          analyze: (value) => { const options = __oxOptions(value, 'ox.vision.analyze'); return __nativeVisionAnalyze(String(options.source), String(options.purpose)); }
        """
    )
}
