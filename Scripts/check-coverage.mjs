#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const resultBundle = process.argv[2];
if (!resultBundle) {
  console.error("Usage: Scripts/check-coverage.mjs <result.xcresult>");
  process.exit(2);
}

const repositoryRoot = resolve(import.meta.dirname, "..");
const configuration = JSON.parse(
  readFileSync(resolve(repositoryRoot, "Config/Coverage.json"), "utf8")
);
const report = JSON.parse(
  execFileSync("xcrun", ["xccov", "view", "--report", "--json", resultBundle], {
    cwd: repositoryRoot,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024
  })
);
const targets = new Map(report.targets.map((target) => [target.name, target]));
const failures = [];

function percentage(value) {
  return `${(value * 100).toFixed(2)}%`;
}

function requireCoverage(label, actual, minimum) {
  console.log(`${label}: ${percentage(actual)} (minimum ${percentage(minimum)})`);
  if (actual + Number.EPSILON < minimum) {
    failures.push(`${label}: ${percentage(actual)} < ${percentage(minimum)}`);
  }
}

function findFile(pathSuffix) {
  for (const target of targets.values()) {
    const file = target.files.find((candidate) => candidate.path.endsWith(pathSuffix));
    if (file) return file;
  }
  return undefined;
}

for (const [targetName, minimum] of Object.entries(configuration.targetThresholds)) {
  const target = targets.get(targetName);
  if (!target) {
    failures.push(`Missing coverage target: ${targetName}`);
    continue;
  }
  requireCoverage(`Target ${targetName}`, target.lineCoverage, minimum);
}

for (const scope of configuration.scopeThresholds ?? []) {
  const target = targets.get(scope.target);
  if (!target) {
    failures.push(`Missing coverage target for scope ${scope.name}: ${scope.target}`);
    continue;
  }
  const files = scope.files.map((pathSuffix) =>
    target.files.find((candidate) => candidate.path.endsWith(pathSuffix))
  );
  const missingFiles = scope.files.filter((_, index) => !files[index]);
  if (missingFiles.length > 0) {
    failures.push(`Missing files for scope ${scope.name}: ${missingFiles.join(", ")}`);
    continue;
  }
  const coveredLines = files.reduce((sum, file) => sum + file.coveredLines, 0);
  const executableLines = files.reduce((sum, file) => sum + file.executableLines, 0);
  requireCoverage(`Scope ${scope.name}`, coveredLines / executableLines, scope.minimum);
}

for (const [pathSuffix, minimum] of Object.entries(configuration.fileThresholds)) {
  const file = findFile(pathSuffix);
  if (!file) {
    failures.push(`Missing coverage file: ${pathSuffix}`);
    continue;
  }
  requireCoverage(`File ${pathSuffix}`, file.lineCoverage, minimum);
}

for (const expectation of configuration.functionThresholds) {
  const file = findFile(expectation.file);
  const fn = file?.functions.find((candidate) => candidate.name === expectation.name);
  if (!fn) {
    failures.push(`Missing coverage function: ${expectation.file} :: ${expectation.name}`);
    continue;
  }
  requireCoverage(`Function ${expectation.name}`, fn.lineCoverage, expectation.minimum);
}

if (failures.length > 0) {
  console.error("\nCoverage gate failed:");
  failures.forEach((failure) => console.error(`- ${failure}`));
  process.exit(1);
}

console.log("Coverage gate passed.");
