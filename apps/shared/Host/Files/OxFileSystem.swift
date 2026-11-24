import Foundation
import JavaScriptCore

nonisolated enum OxFileSystem {
    static let actions = [Actions.fsStat, Actions.fsList, Actions.fsRead, Actions.fsAttach, Actions.visionAnalyze,
                          Actions.fsWrite, Actions.fsEdit, Actions.fsRm, Actions.fsMkdir, Actions.fsMove, Actions.fsCopy, Actions.fsGlob, Actions.fsGrep]

    static let textPageJS = """
        const __fsTextPage = (lines, page) => {
          const hints = (page.diagnostics ?? []).map(({ path, message }) => '[' + path + ': ' + message + ']');
          if (page.truncated) hints.push('[Results incomplete.]');
          if (page.nextCursor != null) hints.push('[Continue with cursor: ' + JSON.stringify(page.nextCursor) + ']');
          return [lines.join('\\n'), hints.join('\\n')].filter(Boolean).join('\\n\\n');
        };
        """

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
          stat: (value) => __nativeFS('stat', __oxOptions(value, 'ox.fs.stat')),
          ls: async (value) => {
            const page = await __nativeFS('list', __oxOptions(value, 'ox.fs.ls'));
            const lines = page.items.map(item => item.name + (item.type === 'directory' ? '/' : ''));
            return __fsTextPage(lines.length ? lines : ['(empty directory)'], page);
          },
          read: async (value) => {
            const page = await __nativeFS('read', __oxOptions(value, 'ox.fs.read'));
            if (page.type === 'image') return page;
            if (page.unsupported) return page.unsupported;
            const hints = page.diagnostics.map(entry => '[' + entry.message + ']');
            if (page.nextOffset != null) hints.push('[More lines in file. Use offset=' + page.nextOffset + ' to continue.]');
            if (page.nextByteOffset != null) hints.push('[More bytes in file. Use byteOffset=' + page.nextByteOffset + ' to continue.]');
            return hints.length ? page.text + '\\n\\n' + hints.join('\\n') : page.text;
          },
          attach: (value) => __nativeFS('attach', __oxOptions(value, 'ox.fs.attach')),
          write: async (value) => {
            await __nativeFS('write', __oxOptions(value, 'ox.fs.write'));
            return 'Successfully wrote to ' + value.path;
          },
          edit: async (value) => {
            await __nativeFS('edit', __oxOptions(value, 'ox.fs.edit'));
            return 'Successfully replaced ' + value.edits.length + ' block(s) in ' + value.path + '.';
          },
          rm: (value) => __nativeFS('rm', __oxOptions(value, 'ox.fs.rm')),
          mkdir: (value) => __nativeFS('mkdir', __oxOptions(value, 'ox.fs.mkdir')),
          move: (value) => __nativeFS('move', __oxOptions(value, 'ox.fs.move')),
          copy: (value) => __nativeFS('copy', __oxOptions(value, 'ox.fs.copy')),
          find: async (value) => {
            const page = await __nativeFS('glob', __oxOptions(value, 'ox.fs.find'));
            return __fsTextPage(page.paths.length ? page.paths : ['No files found matching pattern'], page);
          },
          grep: async (value) => {
            const page = await __nativeFS('grep', __oxOptions(value, 'ox.fs.grep'));
            const lines = page.matches.flatMap(({ path, line, text, before, after }) => [
              ...before.map((text, i) => path + '-' + (line - before.length + i) + '- ' + text),
              path + ':' + line + ': ' + text,
              ...after.map((text, i) => path + '-' + (line + i + 1) + '- ' + text),
            ]);
            return __fsTextPage(lines.length ? lines : ['No matches found'], page);
          }
        """
    )
}
