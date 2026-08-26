import { fileURLToPath } from "node:url";

export const repositoryRoot = fileURLToPath(new URL("./dist/repository/", import.meta.url));
