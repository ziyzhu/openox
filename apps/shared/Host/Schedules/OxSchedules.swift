import Foundation
import JavaScriptCore

nonisolated enum OxSchedules {
    static let function = OxFunction(
        namespace: "schedule",
        schema: {
            [
                entry(
                    "ox.schedule.create",
                    ModelGuidance.text("ox.schedule.create"),
                    input: object([
                        "name": text,
                        "prompt": longText,
                        "condition": longText,
                        "deadline": text,
                        "conversation": enumeration(["current", "new"]),
                        "services": .object(["type": .string("array"), "items": text, "maxItems": .int(100)]),
                        "intervalSeconds": integer(30, 31_536_000),
                        "frequency": enumeration(["once", "interval", "daily", "weekly"]),
                        "fireAt": text,
                        "hour": integer(0, 23),
                        "minute": integer(0, 59),
                        "weekday": enumeration(["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]),
                        "timeZone": text,
                    ], required: ["name", "prompt", "frequency"]),
                    output: schedule
                ),
                entry(
                    "ox.schedule.complete",
                    ModelGuidance.text("ox.schedule.complete"),
                    input: object([:]),
                    output: object(["id": id, "completed": boolean], required: ["id", "completed"])
                ),
                entry(
                    "ox.schedule.list",
                    ModelGuidance.text("ox.schedule.list"),
                    input: object([:]),
                    output: .object(["type": .string("array"), "items": schedule])
                ),
                entry(
                    "ox.schedule.delete",
                    ModelGuidance.text("ox.schedule.delete"),
                    input: object(["id": id], required: ["id"]),
                    output: object(["id": id, "deleted": boolean], required: ["id", "deleted"])
                ),
                entry(
                    "ox.schedule.enable",
                    ModelGuidance.text("ox.schedule.enable"),
                    input: object(["id": id, "enabled": boolean], required: ["id", "enabled"]),
                    output: schedule
                ),
                entry(
                    "ox.schedule.run",
                    ModelGuidance.text("ox.schedule.run"),
                    input: object(["id": id], required: ["id"]),
                    output: object(["id": id, "started": boolean], required: ["id", "started"])
                ),
            ]
        },
        installNatives: { context, env in
            let create: @convention(block) (JSValue, JSValue) -> JSValue = { options, purpose in
                let value = jsValueToJSON(options) ?? .object([:])
                return env.call { try await $0.createSchedule(options: value, purpose: purpose.toString()!) }
            }
            context.setObject(create as AnyObject, forKeyedSubscript: "__nativeScheduleCreate" as NSString)

            let complete: @convention(block) (JSValue) -> JSValue = { purpose in
                env.call { try await $0.completeSchedule(purpose: purpose.toString()!) }
            }
            context.setObject(complete as AnyObject, forKeyedSubscript: "__nativeScheduleComplete" as NSString)

            let list: @convention(block) (JSValue) -> JSValue = { purpose in
                env.call { try await $0.listSchedules(purpose: purpose.toString()!) }
            }
            context.setObject(list as AnyObject, forKeyedSubscript: "__nativeScheduleList" as NSString)

            let delete: @convention(block) (String, JSValue) -> JSValue = { id, purpose in
                env.call { try await $0.deleteSchedule(id: id, purpose: purpose.toString()!) }
            }
            context.setObject(delete as AnyObject, forKeyedSubscript: "__nativeScheduleDelete" as NSString)

            let enable: @convention(block) (String, Bool, JSValue) -> JSValue = { id, enabled, purpose in
                env.call { try await $0.enableSchedule(id: id, enabled: enabled, purpose: purpose.toString()!) }
            }
            context.setObject(enable as AnyObject, forKeyedSubscript: "__nativeScheduleEnable" as NSString)

            let run: @convention(block) (String, JSValue) -> JSValue = { id, purpose in
                env.call { try await $0.runSchedule(id: id, purpose: purpose.toString()!) }
            }
            context.setObject(run as AnyObject, forKeyedSubscript: "__nativeScheduleRun" as NSString)
        },
        jsFragment: """
          create: (value) => { const options = __oxOptions(value, 'ox.schedule.create'); return __nativeScheduleCreate(options, String(options.purpose)); },
          complete: (value) => { const options = __oxOptions(value, 'ox.schedule.complete'); return __nativeScheduleComplete(String(options.purpose)); },
          list: (value) => { const options = __oxOptions(value, 'ox.schedule.list'); return __nativeScheduleList(String(options.purpose)); },
          delete: (value) => { const options = __oxOptions(value, 'ox.schedule.delete'); return __nativeScheduleDelete(String(options.id), String(options.purpose)); },
          enable: (value) => { const options = __oxOptions(value, 'ox.schedule.enable'); return __nativeScheduleEnable(String(options.id), Boolean(options.enabled), String(options.purpose)); },
          run: (value) => { const options = __oxOptions(value, 'ox.schedule.run'); return __nativeScheduleRun(String(options.id), String(options.purpose)); }
        """
    )

    private static let text = string(max: 500)
    private static let longText = string(min: 0, max: 10_000)
    private static let id = string(max: 64)
    private static let boolean: JSONValue = .object(["type": .string("boolean")])
    private static let schedule = object([
        "id": id,
        "name": text,
        "prompt": longText,
        "condition": longText,
        "deadline": text,
        "conversationId": id,
        "status": enumeration(["active", "running", "paused", "completed", "expired"]),
        "enabled": boolean,
        "recurrence": text,
        "nextFireAt": text,
        "lastRunAt": text,
        "lastChatId": id,
        "lastOutcome": enumeration(["succeeded", "cancelled", "failed"]),
        "lastError": text,
    ], required: ["id", "name", "prompt", "status", "enabled", "recurrence"])

    private static func string(min: Int = 1, max: Int) -> JSONValue {
        .object(["type": .string("string"), "minLength": .int(min), "maxLength": .int(max)])
    }

    private static func integer(_ minimum: Int, _ maximum: Int) -> JSONValue {
        .object(["type": .string("integer"), "minimum": .int(minimum), "maximum": .int(maximum)])
    }

    private static func enumeration(_ values: [String]) -> JSONValue {
        .object(["type": .string("string"), "enum": .array(values.map(JSONValue.string))])
    }

    private static func entry(_ name: String, _ description: String, input: JSONValue, output: JSONValue) -> (String, JSONValue) {
        (name, .object(["description": .string(description), "inputSchema": input, "outputSchema": output]))
    }

    private static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty { schema["required"] = .array(required.map(JSONValue.string)) }
        return .object(schema)
    }
}
