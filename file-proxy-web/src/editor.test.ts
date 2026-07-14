import { describe, expect, it } from "vitest";
import {
  decodeTextFile,
  isEditableTextPath,
  languageExtensions,
  MAX_TEXT_FILE_SIZE,
} from "./editor";

describe("text editor selection", () => {
  it("recognizes common code, text, and extensionless configuration files", () => {
    expect(isEditableTextPath("src/Main.hs")).toBe(true);
    expect(isEditableTextPath("config/settings.yaml")).toBe(true);
    expect(isEditableTextPath("Dockerfile")).toBe(true);
    expect(isEditableTextPath("archive/image.png")).toBe(false);
  });

  it("decodes UTF-8 text but rejects binary content", () => {
    expect(decodeTextFile(new TextEncoder().encode("hello").buffer)).toBe(
      "hello",
    );
    expect(() =>
      decodeTextFile(new Uint8Array([0x61, 0, 0x62]).buffer),
    ).toThrow("binary data");
  });

  it("selects highlighters for supported source files", () => {
    expect(languageExtensions("Worker.hs")).toHaveLength(1);
    expect(languageExtensions("client.tsx")).toHaveLength(1);
    expect(languageExtensions("Dockerfile")).toHaveLength(1);
    expect(languageExtensions("notes.txt")).toHaveLength(0);
    expect(MAX_TEXT_FILE_SIZE).toBe(5 * 1024 * 1024);
  });
});
