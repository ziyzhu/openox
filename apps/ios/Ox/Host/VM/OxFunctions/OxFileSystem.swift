import Foundation
import JavaScriptCore

nonisolated enum OxFileSystem {
    static let actions = [Actions.fsList, Actions.fsRead, Actions.fsAttach, Actions.visionAnalyze,
                          Actions.fsWrite, Actions.fsEdit, Actions.fsDelete, Actions.fsMkdir, Actions.fsRmdir, Actions.fsMove, Actions.fsCopy, Actions.fsGlob, Actions.fsGrep]

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
          list: (value) => __nativeFS('list', __oxOptions(value, 'ox.fs.list')),
          read: (value) => __nativeFS('read', __oxOptions(value, 'ox.fs.read')),
          attach: (value) => __nativeFS('attach', __oxOptions(value, 'ox.fs.attach')),
          write: (value) => __nativeFS('write', __oxOptions(value, 'ox.fs.write')),
          edit: (value) => __nativeFS('edit', __oxOptions(value, 'ox.fs.edit')),
          delete: (value) => __nativeFS('delete', __oxOptions(value, 'ox.fs.delete')),
          mkdir: (value) => __nativeFS('mkdir', __oxOptions(value, 'ox.fs.mkdir')),
          rmdir: (value) => __nativeFS('rmdir', __oxOptions(value, 'ox.fs.rmdir')),
          move: (value) => __nativeFS('move', __oxOptions(value, 'ox.fs.move')),
          copy: (value) => __nativeFS('copy', __oxOptions(value, 'ox.fs.copy')),
          glob: (value) => __nativeFS('glob', __oxOptions(value, 'ox.fs.glob')),
          grep: (value) => __nativeFS('grep', __oxOptions(value, 'ox.fs.grep'))
        """
    )
}
