import Foundation
import JavaScriptCore

nonisolated enum OxFileSystem {
    static let actions = [Actions.fsList, Actions.fsRead, Actions.fsAttach, Actions.visionAnalyze,
                          Actions.fsWrite, Actions.fsEdit, Actions.fsDelete, Actions.fsGlob, Actions.fsGrep]

    static let function = OxFunction(
        namespace: "fs",
        schema: { ModelGuidance.fileSystemSchemas },
        installNatives: { context, env in
            let operation: @convention(block) (String, JSValue) -> JSValue = { name, arguments in
                let value = jsValueToJSON(arguments)
                return env.call { try await $0.fileSystemOperation(name: name, arguments: value ?? .null) }
            }
            context.setObject(operation as AnyObject, forKeyedSubscript: "__nativeFS" as NSString)
        },
        jsFragment: """
          list: (value) => __nativeFS('list', value ?? {}),
          read: (value) => __nativeFS('read', value),
          attach: (value) => __nativeFS('attach', value),
          write: (value) => __nativeFS('write', value),
          edit: (value) => __nativeFS('edit', value),
          delete: (value) => __nativeFS('delete', value),
          glob: (value) => __nativeFS('glob', value),
          grep: (value) => __nativeFS('grep', value)
        """
    )
}
