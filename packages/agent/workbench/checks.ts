import { readFileSync } from "node:fs";
import { join } from "node:path";
import { bundledSkills } from "../src/core/bundled-skills";
import { contracts, repo, type Rendered, type Unit } from "./units";
import invariants from "./invariants.json";

export type Severity = "error" | "warning" | "info";
export interface Finding { check: string; severity: Severity; unit?: string; message: string }
export interface Coverage { id: string; fact: string; units: string[] }

const namespaces = ["conversation", "provider", "repository", "secret", "service", "user", "web", "fs", "output", "skill", "schedule", "vision"];
const alternativeGroups = ["storage.", "replies.", "language.", "runtime.login."];
const catalogNames =new Set(["ox", ...namespaces.map(name => `ox.${name}`), "ox.web.browser", ...Object.keys(contracts)]);

function hostNames() {
  const source = readFileSync(join(repo, "apps/shared/Host/VM/Actions.swift"), "utf8");
  return new Set([...source.matchAll(/"(ox(?:\.[A-Za-z][A-Za-z0-9]*)+)"/g)].map(match => match[1]!));
}

function sentences(text: string) {
  return text.replace(/```[\s\S]*?```/g, "").split(/(?<=[.!?])\s+/u).map(sentence => sentence.trim()).filter(sentence => sentence.length >= 60);
}

function names(units: Unit[], texts: Map<string, string>, known: Set<string>): Finding[] {
  const findings: Finding[] = [];
  for (const unit of units) {
    const found = new Set([...texts.get(unit.id)!.matchAll(/\box(?:\.[A-Za-z][A-Za-z0-9]*)+/g)].map(match => match[0]));
    for (const name of found) {
      if (catalogNames.has(name)) continue;
      findings.push(known.has(name)
        ? { check: "names", severity: "warning", unit: unit.id, message: `${name} exists on the host but is not in the catalog the model sees` }
        : { check: "names", severity: "error", unit: unit.id, message: `${name} is not a known function` });
    }
  }
  return findings;
}

function skillNames(units: Unit[], texts: Map<string, string>): Finding[] {
  return bundledSkills.flatMap(skill => {
    const capitalized = skill.name[0]!.toUpperCase() + skill.name.slice(1);
    const pattern = new RegExp(`(?<![.!?]\\s|^|\\n)\\b${capitalized}\\b`);
    return units.filter(unit => pattern.test(texts.get(unit.id)!)).map(unit => ({
      check: "skill-names", severity: "info" as const, unit: unit.id, message: `Refers to the \`${skill.name}\` skill as "${capitalized}"`,
    }));
  });
}

function duplicates(units: Unit[], texts: Map<string, string>): Finding[] {
  const owners = new Map<string, Set<string>>();
  for (const unit of units) for (const sentence of sentences(texts.get(unit.id)!)) owners.set(sentence, (owners.get(sentence) ?? new Set()).add(unit.id));
  const alternatives = (ids: Set<string>) => alternativeGroups.some(prefix => [...ids].every(id => id.startsWith(prefix)));
  return [...owners].filter(([, ids]) => ids.size > 1 && !alternatives(ids)).map(([sentence, ids]) => ({
    check: "duplicates", severity: "warning", unit: [...ids][0], message: `Repeated in ${[...ids].join(", ")}: "${sentence.slice(0, 140)}${sentence.length > 140 ? "…" : ""}"`,
  }));
}

function artifacts(rendered: Rendered): Finding[] {
  const prose = `${rendered.identity}\n${rendered.system}\n${rendered.execute}`.replace(/```[\s\S]*?```/g, block => (block.match(/\/\*\*[\s\S]*?\*\//g) ?? []).join("\n"));
  const patterns: [RegExp, string][] = [[/\S [,;:.](?=\s)/g, "Space before punctuation"], [/``/g, "Empty code span"], [/\(\s*,|,\s*\)/g, "Dangling comma"], [/\b(\w+) \1\b/gi, "Repeated word"]];
  return patterns.flatMap(([pattern, label]) => [...prose.matchAll(pattern)].map(match => {
    const start = Math.max(0, match.index! - 50);
    return { check: "artifacts", severity: "error" as const, message: `${label}: "…${prose.slice(start, match.index! + 50).replace(/\s+/g, " ")}…"` };
  }));
}

function coverage(units: Unit[], texts: Map<string, string>, appears: Record<string, boolean>): Coverage[] {
  const relevant = units.filter(unit => appears[unit.id] || unit.scope === "system" || unit.scope === "execute");
  return invariants.map(invariant => {
    const patterns = invariant.patterns.map(pattern => new RegExp(pattern, "i"));
    return { id: invariant.id, fact: invariant.fact, units: relevant.filter(unit => patterns.every(pattern => pattern.test(texts.get(unit.id)!))).map(unit => unit.id) };
  });
}

export function runChecks(units: Unit[], drafts: Map<string, string>, rendered: Rendered, appears: Record<string, boolean>) {
  const texts = new Map(units.map(unit => [unit.id, drafts.get(unit.id) ?? unit.current]));
  const findings = [...names(units, texts, hostNames()), ...skillNames(units, texts), ...duplicates(units, texts), ...artifacts(rendered)];
  return { findings, coverage: coverage(units, texts, appears) };
}
