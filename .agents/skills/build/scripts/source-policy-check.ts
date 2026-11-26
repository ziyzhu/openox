import { join } from "node:path";
import ts from "typescript";
import { ROOT, run, runCheck } from "../../../lib.ts";
import baseline from "./source-comment-baseline.json";

const testChecks = new Set([
  ".agents/skills/build/checks/cli/arguments.test.ts",
  ".agents/skills/build/checks/ios/agent-packaging.test.ts",
  ".agents/skills/build/checks/ios/template-cli.test.ts",
  ".agents/skills/build/checks/ios/template-launch-safety.test.ts",
  "apps/cli/src/agent-serve.test.ts",
  "packages/agent/test/bundle.test.ts",
]);
const sourceFile = /\.(?:swift|[cm]?[jt]s|[jt]sx)$/;
const testDirectory = /(?:^|\/)(?:__tests__|tests?|specs?)\//i;
const testFile = /[._-](?:test|spec)s?\.[^.]+$/i;
const swiftTestFile = /(?:Tests?|Specs?)\.swift$/;
const testModule = /^(?:(?:bun:test|node:test|vitest|jest|mocha|ava|tap|tape)(?:\/|$)|@(?:jest|vitest)\/)/;

type Findings = { comments: [number, number][]; tests: number[] };

function scriptFindings(file: string, source: string): Findings {
  const tree = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
  const scanner = ts.createScanner(ts.ScriptTarget.Latest, false, ts.LanguageVariant.Standard, source);
  const comments: Findings["comments"] = [];
  const tests: number[] = [];
  let end = 0;

  function visit(node: ts.Node) {
    if (ts.isStringLiteralLike(node) && testModule.test(node.text)) {
      const parent = node.parent;
      if (ts.isImportDeclaration(parent) || ts.isExportDeclaration(parent) || ts.isExternalModuleReference(parent) ||
        (ts.isCallExpression(parent) && /^(?:import|require)$/.test(parent.expression.getText(tree)))) {
        tests.push(node.getStart(tree));
      }
    }
    if (node.kind <= ts.SyntaxKind.LastToken) {
      const start = ts.isJsxText(node) ? node.pos : node.getStart(tree);
      scanner.resetTokenState(end);
      while (scanner.getTextPos() < start) {
        const token = scanner.scan();
        if (token === ts.SyntaxKind.SingleLineCommentTrivia || token === ts.SyntaxKind.MultiLineCommentTrivia) {
          comments.push([scanner.getTokenStart(), scanner.getTextPos()]);
        }
      }
      end = node.end;
      return;
    }
    for (const child of node.getChildren(tree)) {
      if (child.kind !== ts.SyntaxKind.JSDocComment) visit(child);
    }
  }
  visit(tree);
  return { comments, tests };
}

function swiftFindings(source: string): Findings {
  const comments: Findings["comments"] = [];
  const tests: number[] = [];
  const tokens = /\/\/[^\r\n]*|\/\*|(#*)("""|")|(#+)\/|(?<![\p{ID_Continue})\]"])\/(?![\s/*])(?:\\[^\r\n]|[^/\\\r\n])+?(?<!\s)\/(?![/*])|\bimport\s+(?:(?:class|enum|func|let|protocol|struct|typealias|var)\s+)?(?:Testing|XCTest)\b|@(?:Test|Suite|testable)\b|[()]/gu;
  const block = /\/\*|\*\//g;
  let cursor = 0;

  function code(interpolation = false) {
    let parentheses = interpolation ? 1 : 0;
    while (cursor < source.length) {
      tokens.lastIndex = cursor;
      const match = tokens.exec(source);
      if (!match) break;
      cursor = tokens.lastIndex;
      const [token, hashes, quote, regexHashes] = match;
      if (token.startsWith("//")) {
        comments.push([match.index, cursor]);
      } else if (token === "/*") {
        let depth = 1;
        block.lastIndex = cursor;
        for (let delimiter; depth > 0 && (delimiter = block.exec(source));) {
          depth += delimiter[0] === "/*" ? 1 : -1;
        }
        cursor = depth === 0 ? block.lastIndex : source.length;
        comments.push([match.index, cursor]);
      } else if (quote) {
        const escapes = new RegExp(`${quote}${hashes}|\\\\${hashes}([\\s\\S])`, "g");
        while (cursor < source.length) {
          escapes.lastIndex = cursor;
          const marker = escapes.exec(source);
          if (!marker) { cursor = source.length; break; }
          cursor = escapes.lastIndex;
          if (marker[1] === undefined) break;
          if (marker[1] === "(") code(true);
        }
      } else if (regexHashes) {
        const close = source.indexOf(`/${regexHashes}`, cursor);
        cursor = close < 0 ? source.length : close + regexHashes.length + 1;
      } else if (interpolation && token === "(") {
        parentheses++;
      } else if (interpolation && token === ")" && --parentheses === 0) {
        return;
      } else if (token.startsWith("@") || token.startsWith("import")) {
        tests.push(match.index);
      }
    }
    cursor = source.length;
  }

  code();
  return { comments, tests };
}

export async function check(): Promise<string> {
  const { stdout } = await run(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"], { capture: true });
  const failures: string[] = [];
  let count = 0;
  for (const path of new Set(stdout.split("\0"))) {
    if (!sourceFile.test(path) || path === "apps/ios/Resources/Pele.bundle/pele.js") continue;
    const file = Bun.file(join(ROOT, path));
    if (!await file.exists()) continue;
    count++;
    const source = await file.text();
    const { comments, tests } = path.endsWith(".swift") ? swiftFindings(source) : scriptFindings(path, source);
    const existing = [...((baseline as Record<string, string[]>)[path] ?? [])];
    const report = (offset: number, problem: string) => {
      const line = source.slice(0, offset).split(/\r\n|\r|\n/).length;
      failures.push(`${path}:${line}: ${problem}`);
    };
    for (const [start, end] of comments) {
      const comment = source.slice(start, end).replaceAll("\r\n", "\n");
      const index = existing.indexOf(comment);
      if (index < 0) report(start, "Code comments are not allowed");
      else existing.splice(index, 1);
    }
    if (!testChecks.has(path)) {
      const directory = path.replace(/^\.agents\/skills\/test\//, "");
      if (testDirectory.test(directory) || testFile.test(path) || swiftTestFile.test(path)) {
        report(0, "Unit test files are not allowed");
      } else {
        for (const offset of tests) report(offset, "Unit test frameworks are not allowed");
      }
    }
  }
  if (failures.length) throw new Error(`source policy failed:\n${failures.join("\n")}`);
  return `source policy ${count} files`;
}

if (import.meta.main) await runCheck(check);
