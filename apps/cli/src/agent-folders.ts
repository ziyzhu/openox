import { mkdir, readdir, readFile, realpath, rename, stat, writeFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import { agentLog } from "./agent-log.ts";

export class FolderAccessError extends Error {}

export class FolderStore {
  private folders: string[] = [];
  private saving: Promise<void> = Promise.resolve();
  private readonly path: string;
  private readonly directory: string;

  constructor(directory: string) {
    this.directory = directory;
    this.path = join(directory, "folders.json");
  }

  async load(): Promise<void> {
    const stored = await readFile(this.path, "utf8").then(JSON.parse, () => undefined);
    if (stored?.format === 1 && Array.isArray(stored.folders)) this.folders = stored.folders.filter((folder: unknown) => typeof folder === "string");
  }

  list(): readonly string[] { return this.folders; }

  async add(requested: string): Promise<string> {
    const folder = await readableFolder(requested);
    if (!this.folders.includes(folder)) {
      this.folders = [...this.folders, folder];
      await this.persist();
    }
    agentLog("folders.add", { folders: this.folders.length });
    return folder;
  }

  async remove(requested: string): Promise<void> {
    const resolved = await realpath(resolve(requested)).catch(() => resolve(requested));
    const remaining = this.folders.filter((folder) => folder !== resolved && folder !== requested);
    if (remaining.length === this.folders.length) throw new FolderAccessError(`${requested} is not an authorized folder`);
    this.folders = remaining;
    await this.persist();
    agentLog("folders.remove", { folders: this.folders.length });
  }

  private persist(): Promise<void> {
    this.saving = this.saving.then(() => this.save(), () => this.save());
    return this.saving;
  }

  private async save(): Promise<void> {
    await mkdir(this.directory, { recursive: true });
    const temporary = `${this.path}.${process.pid}.tmp`;
    await writeFile(temporary, `${JSON.stringify({ format: 1, folders: this.folders }, null, 2)}\n`);
    await rename(temporary, this.path);
  }
}

async function readableFolder(requested: string): Promise<string> {
  const folder = await realpath(resolve(requested)).catch(() => undefined);
  const directory = folder && await stat(folder).then((info) => info.isDirectory(), () => false);
  if (!folder || !directory) throw new FolderAccessError(`${requested} is not a folder`);
  try {
    await readdir(folder);
  } catch (error) {
    const code = (error as NodeJS.ErrnoException).code;
    agentLog("folders.denied", { code });
    throw new FolderAccessError(code === "EPERM" || code === "EACCES"
      ? `macOS denied access to ${folder}; allow ox in System Settings › Privacy & Security, then add it again`
      : `${folder} cannot be read (${code ?? "unknown error"})`);
  }
  return folder;
}
