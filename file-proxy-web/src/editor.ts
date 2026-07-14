import type { Extension } from "@codemirror/state";
import { cpp } from "@codemirror/lang-cpp";
import { css } from "@codemirror/lang-css";
import { go } from "@codemirror/lang-go";
import { html } from "@codemirror/lang-html";
import { java } from "@codemirror/lang-java";
import { javascript } from "@codemirror/lang-javascript";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { php } from "@codemirror/lang-php";
import { python } from "@codemirror/lang-python";
import { rust } from "@codemirror/lang-rust";
import { sql } from "@codemirror/lang-sql";
import { yaml } from "@codemirror/lang-yaml";
import { StreamLanguage } from "@codemirror/language";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { shell } from "@codemirror/legacy-modes/mode/shell";

export const MAX_TEXT_FILE_SIZE = 5 * 1024 * 1024;

const textExtensions = new Set([
  "asm",
  "bash",
  "c",
  "cc",
  "cfg",
  "clj",
  "cmake",
  "conf",
  "cpp",
  "cs",
  "css",
  "csv",
  "cxx",
  "env",
  "go",
  "h",
  "hpp",
  "hs",
  "html",
  "htm",
  "ini",
  "java",
  "js",
  "json",
  "jsx",
  "kt",
  "kts",
  "less",
  "log",
  "lua",
  "m",
  "md",
  "mdx",
  "php",
  "pl",
  "properties",
  "py",
  "r",
  "rb",
  "rs",
  "sass",
  "scala",
  "scss",
  "sh",
  "sql",
  "svg",
  "swift",
  "toml",
  "ts",
  "tsx",
  "txt",
  "vue",
  "xml",
  "yaml",
  "yml",
  "zsh",
]);

const textNames = new Set([
  ".editorconfig",
  ".env",
  ".gitignore",
  ".npmrc",
  ".prettierrc",
  "cmakelists.txt",
  "dockerfile",
  "makefile",
]);

function fileName(path: string) {
  return path.split("/").pop()?.toLowerCase() ?? "";
}

export function isEditableTextPath(path: string) {
  const name = fileName(path);
  if (textNames.has(name)) return true;
  const extension = name.split(".").pop();
  return Boolean(extension && textExtensions.has(extension));
}

export function decodeTextFile(bytes: ArrayBuffer) {
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.includes("\0")) throw new Error("file contains binary data");
  return text;
}

export function languageExtensions(path: string): Extension[] {
  const name = fileName(path);
  const extension = name.split(".").pop();
  if (name === "dockerfile") return [StreamLanguage.define(dockerFile)];
  if (name === "makefile") return [StreamLanguage.define(shell)];
  switch (extension) {
    case "js":
    case "jsx":
      return [javascript({ jsx: true })];
    case "ts":
    case "tsx":
      return [javascript({ jsx: extension === "tsx", typescript: true })];
    case "json":
      return [json()];
    case "html":
    case "htm":
    case "xml":
    case "svg":
    case "vue":
      return [html()];
    case "css":
    case "scss":
    case "sass":
    case "less":
      return [css()];
    case "md":
    case "mdx":
      return [markdown()];
    case "py":
      return [python()];
    case "sql":
      return [sql()];
    case "yaml":
    case "yml":
      return [yaml()];
    case "java":
      return [java()];
    case "c":
    case "cc":
    case "cpp":
    case "cxx":
    case "h":
    case "hpp":
      return [cpp()];
    case "rs":
      return [rust()];
    case "go":
      return [go()];
    case "php":
      return [php()];
    case "hs":
      return [StreamLanguage.define(haskell)];
    case "sh":
    case "bash":
    case "zsh":
      return [StreamLanguage.define(shell)];
    default:
      return [];
  }
}
