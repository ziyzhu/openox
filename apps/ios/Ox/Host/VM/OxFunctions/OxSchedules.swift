import Foundation
import JavaScriptCore

nonisolated enum OxSchedules {
    static let function = OxFunction(
        namespace: "schedule",
        schema: {
            [
                entry(
                    "ox.schedule.create",
                    "Schedule a frozen snapshot of one Profile-owned skill after explicit user confirmation: `await ox.schedule.create({ skill, argument?, frequency, fireAt?, hour?, minute?, weekday?, timeZone?, purpose })`. Use `fireAt` for `once`; use `hour` and `minute` for `daily`; add a weekday name for `weekly`. Times are best-effort on iOS.",
                    input: object([
                        "skill": text,
                        "argument": longText,
                        "frequency": enumeration(["once", "daily", "weekly"]),
                        "fireAt": text,
                        "hour": integer(0, 23),
                        "minute": integer(0, 59),
                        "weekday": enumeration(["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]),
                        "timeZone": text,
                    ], required: ["skill", "frequency"]),
                    output: schedule
                ),
                entry(
                    "ox.schedule.list",
                    "List scheduled skill invocations for the active Profile: `await ox.schedule.list({ purpose })`.",
                    input: object([:]),
                    output: .object(["type": .string("array"), "items": schedule])
                ),
                entry(
                    "ox.schedule.delete",
                    "Delete one scheduled skill after explicit user confirmation: `await ox.schedule.delete({ id, purpose })`.",
                    input: object(["id": id], required: ["id"]),
                    output: object(["id": id, "deleted": boolean], required: ["id", "deleted"])
                ),
                entry(
                    "ox.schedule.enable",
                    "Enable or disable one scheduled skill after explicit user confirmation: `await ox.schedule.enable({ id, enabled, purpose })`.",
                    input: object(["id": id, "enabled": boolean], required: ["id", "enabled"]),
                    output: schedule
                ),
                entry(
                    "ox.schedule.run",
                    "Run one scheduled skill snapshot now after explicit user confirmation: `await ox.schedule.run({ id, purpose })`.",
                    input: object(["id": id], required: ["id"]),
                    output: object(["id": id, "started": boolean], required: ["id", "started"])
                ),
            ]
        },
        installNatives: { context, env in
            let create: @convention(block) (String, JSValue, String, JSValue, JSValue, JSValue, JSValue, JSValue, JSValue) -> JSValue = {
                skill, argument, frequency, fireAt, hour, minute, weekday, timeZone, purpose in
                env.call {
                    try await $0.createScheduledSkill(
                        skillName: skill,
                        argument: optionalString(argument),
                        frequency: frequency,
                        fireAt: optionalString(fireAt),
                        hour: jsValueToJSON(hour)?.intValue,
                        minute: jsValueToJSON(minute)?.intValue,
                        weekday: optionalString(weekday),
                        timeZone: optionalString(timeZone),
                        purpose: purpose.toString()!
                    )
                }
            }
            context.setObject(create as AnyObject, forKeyedSubscript: "__nativeScheduleCreate" as NSString)

            let list: @convention(block) (JSValue) -> JSValue = { purpose in
                env.call { try await $0.listScheduledSkills(purpose: purpose.toString()!) }
            }
            context.setObject(list as AnyObject, forKeyedSubscript: "__nativeScheduleList" as NSString)

            let delete: @convention(block) (String, JSValue) -> JSValue = { id, purpose in
                env.call { try await $0.deleteScheduledSkill(id: id, purpose: purpose.toString()!) }
            }
            context.setObject(delete as AnyObject, forKeyedSubscript: "__nativeScheduleDelete" as NSString)

            let enable: @convention(block) (String, Bool, JSValue) -> JSValue = { id, enabled, purpose in
                env.call { try await $0.enableScheduledSkill(id: id, enabled: enabled, purpose: purpose.toString()!) }
            }
            context.setObject(enable as AnyObject, forKeyedSubscript: "__nativeScheduleEnable" as NSString)

            let run: @convention(block) (String, JSValue) -> JSValue = { id, purpose in
                env.call { try await $0.runScheduledSkill(id: id, purpose: purpose.toString()!) }
            }
            context.setObject(run as AnyObject, forKeyedSubscript: "__nativeScheduleRun" as NSString)
        },
        jsFragment: """
          create: (value) => { const options = __oxOptions(value, 'ox.schedule.create'); return __nativeScheduleCreate(String(options.skill), options.argument ?? null, String(options.frequency), options.fireAt ?? null, options.hour ?? null, options.minute ?? null, options.weekday ?? null, options.timeZone ?? null, String(options.purpose)); },
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
        "skill": text,
        "argument": longText,
        "enabled": boolean,
        "recurrence": text,
        "nextFireAt": text,
        "lastRunAt": text,
        "lastChatId": id,
    ], required: ["id", "skill", "argument", "enabled", "recurrence"])

    private static func optionalString(_ value: JSValue) -> String? {
        jsValueToJSON(value)?.stringValue
    }

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
