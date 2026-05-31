import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import { chmodSync, copyFileSync, existsSync, mkdirSync, rmSync } from "node:fs";
import path from "node:path";

const require = createRequire(import.meta.url);
const root = path.resolve(import.meta.dirname, "..");
const targetTriple = getTargetTriple();
const codexBinary = resolveCodexBinary(targetTriple);
const outDir = path.join(root, "src-tauri", "binaries");
const outPath = path.join(outDir, process.platform === "win32" ? `codex-${targetTriple}.exe` : `codex-${targetTriple}`);

mkdirSync(outDir, { recursive: true });
rmSync(outPath, { force: true });
copyFileSync(codexBinary, outPath);
chmodSync(outPath, 0o755);

console.log(`Prepared Codex sidecar: ${path.relative(root, outPath)}`);

function getTargetTriple() {
  try {
    return execFileSync("rustc", ["-Vv"], { encoding: "utf8" })
      .split("\n")
      .find((line) => line.startsWith("host: "))
      ?.replace("host: ", "")
      .trim() ?? fallbackTargetTriple();
  } catch {
    return fallbackTargetTriple();
  }
}

function fallbackTargetTriple() {
  const table = {
    "darwin-arm64": "aarch64-apple-darwin",
    "darwin-x64": "x86_64-apple-darwin",
    "linux-arm64": "aarch64-unknown-linux-musl",
    "linux-x64": "x86_64-unknown-linux-musl",
    "win32-arm64": "aarch64-pc-windows-msvc",
    "win32-x64": "x86_64-pc-windows-msvc",
  };
  const target = table[`${process.platform}-${process.arch}`];
  if (!target) throw new Error(`Unsupported platform: ${process.platform} ${process.arch}`);
  return target;
}

function resolveCodexBinary(triple) {
  if (process.env.CODEX_BINARY) return assertFile(process.env.CODEX_BINARY);

  const packageByTarget = {
    "aarch64-apple-darwin": "@openai/codex-darwin-arm64",
    "x86_64-apple-darwin": "@openai/codex-darwin-x64",
    "aarch64-unknown-linux-musl": "@openai/codex-linux-arm64",
    "x86_64-unknown-linux-musl": "@openai/codex-linux-x64",
    "aarch64-pc-windows-msvc": "@openai/codex-win32-arm64",
    "x86_64-pc-windows-msvc": "@openai/codex-win32-x64",
  };

  const platformPackage = packageByTarget[triple];
  if (!platformPackage) throw new Error(`No Codex package mapping for ${triple}`);

  const packageJson = require.resolve(`${platformPackage}/package.json`);
  const binaryName = process.platform === "win32" ? "codex.exe" : "codex";
  const packageRoot = path.dirname(packageJson);
  const candidates = [
    path.join(packageRoot, "vendor", triple, "bin", binaryName),
    path.join(packageRoot, "vendor", triple, "codex", binaryName),
  ];

  const binary = candidates.find((candidate) => existsSync(candidate));
  if (!binary) throw new Error(`Codex binary not found. Checked: ${candidates.join(", ")}`);
  return binary;
}

function assertFile(filePath) {
  if (!existsSync(filePath)) throw new Error(`Codex binary not found: ${filePath}`);
  return filePath;
}
