#!/usr/bin/env node
/**
 * scripts/check-design-tokens.mjs
 *
 * Prüft, dass neue Oberflächen nur zentrale Design-Tokens verwenden
 * (app/globals.css: Palette der shadcn-Tokens, --space-*, --type-*,
 * --weight-*, --line-*, --size-*, --radius-*):
 *
 *   CSS  – Abschnitte zwischen  /* <name>:start  und  /* <name>:end *\/
 *          in app/globals.css: keine Farbwerte (Hex, rgb(), oklch() …,
 *          Farbnamen), keine festen Längen bei Abständen, Schrift und Maßen.
 *   TSX  – Dateien der Abschnitte: style nur für CSS-Variablen (Datenwerte
 *          wie Balkenbreiten), keine Farbwerte, keine Tailwind-Palettenfarben
 *          oder Arbitrary Values.
 *
 * Aufruf: npm run check:tokens  (Exit-Code 1 bei Verstößen)
 */
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('..', import.meta.url));

/** Abschnitte, die nur Tokens verwenden dürfen. */
const SECTIONS = [
  {
    name: 'contracts',
    files: [
      'app/[locale]/dashboard/contracts',
      'app/[locale]/advisor/clients/[clientId]/contracts-section.tsx',
    ],
  },
  {
    name: 'budgets',
    files: [
      'app/[locale]/dashboard/budgets',
      'app/[locale]/advisor/clients/[clientId]/budget-section.tsx',
    ],
  },
];

const COLOR_LITERAL = /#[0-9a-fA-F]{3,8}\b|\b(?:rgba?|hsla?|oklch|oklab|lab|lch|hwb)\(/;
const COLOR_PROPERTIES =
  /^(?:color|background|background-color|border(?:-(?:top|right|bottom|left))?(?:-color)?|outline(?:-color)?|fill|stroke|box-shadow|text-decoration-color|caret-color|accent-color)$/;
const SIZE_PROPERTIES =
  /^(?:margin|padding)(?:-(?:top|right|bottom|left|block|inline)(?:-(?:start|end))?)?$|^(?:gap|row-gap|column-gap|font-size|line-height|font-weight|letter-spacing|top|right|bottom|left|inset|width|height|min-width|min-height|max-width|max-height|border-radius|border(?:-(?:top|right|bottom|left))?(?:-width)?|outline-width|outline-offset|text-underline-offset|grid-template-columns|grid-template-rows|flex-basis)$/;
/** Erlaubte Wörter in Farbwerten (nach Entfernen von var(--…)). */
const COLOR_KEYWORDS = new Set([
  'transparent', 'currentcolor', 'inherit', 'none', 'initial', 'unset',
  'solid', 'dashed', 'dotted', 'color-mix', 'in', 'oklch', 'srgb',
]);
const FIXED_LENGTH = /(?<![\w-])-?\d*\.?\d+(?:px|rem|em|pt|vh|vw|vmin|vmax|ch|ex)\b/;
const BARE_NUMBER = /(?<![\w.-])-?\d*\.?\d+(?![\w%.])/;
const TAILWIND_COLOR =
  /\b(?:bg|text|border|ring|fill|stroke|from|to|via|outline|decoration|shadow)-(?:slate|gray|zinc|neutral|stone|red|orange|amber|yellow|lime|green|emerald|teal|cyan|sky|blue|indigo|violet|purple|fuchsia|pink|rose|black|white)(?:-\d{2,3})?\b/;
const TAILWIND_ARBITRARY = /\b[\w-]+-\[[^\]]*\]/;

const problems = [];

function checkCss(css, section) {
  const start = css.indexOf(`/* ${section}:start`);
  const end = css.indexOf(`/* ${section}:end */`);
  if (start === -1 || end === -1 || end < start) {
    problems.push(`app/globals.css: Abschnitt „${section}“ (/* ${section}:start … ${section}:end */) fehlt`);
    return 0;
  }
  const offset = css.slice(0, start).split('\n').length;
  const lines = css.slice(start, end).split('\n');
  // Aufbau: Nach dem Entfernen der Kommentare (Zeilen bleiben erhalten) darf
  // nur CSS übrig sein – sonst endete ein Kommentar zu früh (z. B. „*/“ im
  // Text) und hat die folgende Regel verschluckt.
  const stripped = css
    .slice(start, end)
    .replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, ' '))
    .split('\n');
  stripped.forEach((raw, index) => {
    const line = raw.trim();
    const isCss =
      line === '' ||
      line === '}' ||
      /\{$/.test(line) ||
      /,$/.test(line) ||
      /^[a-z-]+\s*:\s*[^{}]+;$/.test(line);
    if (!isCss) {
      problems.push(`app/globals.css:${offset + index} (${section}): kein CSS – Kommentar zu früh beendet? „${line}“`);
    }
  });
  let declarations = 0;
  lines.forEach((raw, index) => {
    const line = raw.replace(/\/\*.*?\*\//g, '').trim();
    const match = /^([a-z-]+)\s*:\s*(.+?);?$/.exec(line);
    if (!match || line.endsWith('{')) {
      return;
    }
    declarations += 1;
    const [, property, value] = match;
    const where = `app/globals.css:${offset + index} (${section})`;
    if (COLOR_LITERAL.test(value)) {
      problems.push(`${where}: Farbwert statt Token in „${line}“`);
    }
    const withoutVars = value.replace(/var\(--[\w-]+\)/g, ' ');
    if (COLOR_PROPERTIES.test(property)) {
      const words = withoutVars
        .replace(/-?\d*\.?\d+%/g, ' ')
        .split(/[\s(),]+/)
        .filter(Boolean)
        .filter((word) => !COLOR_KEYWORDS.has(word.toLowerCase()) && !/^-?\d*\.?\d+$/.test(word));
      // Bei border/outline/box-shadow sind Längen Sache der Größenprüfung.
      const colorWords = words.filter((word) => !FIXED_LENGTH.test(word));
      if (colorWords.length > 0) {
        problems.push(`${where}: feste Farbe „${colorWords.join(' ')}“ in „${line}“`);
      }
    }
    if (SIZE_PROPERTIES.test(property) || COLOR_PROPERTIES.test(property)) {
      if (FIXED_LENGTH.test(withoutVars)) {
        problems.push(`${where}: feste Länge statt Token in „${line}“`);
      }
      if (/^(?:font-weight|line-height)$/.test(property) && BARE_NUMBER.test(withoutVars.replace(/\b0\b/g, ''))) {
        problems.push(`${where}: fester Schriftwert statt Token in „${line}“`);
      }
    }
  });
  return declarations;
}

function listFiles(path) {
  const absolute = join(ROOT, path);
  if (statSync(absolute).isFile()) {
    return [absolute];
  }
  return readdirSync(absolute).flatMap((entry) => listFiles(join(path, entry)));
}

function checkTsx(file) {
  const source = readFileSync(file, 'utf8');
  const name = relative(ROOT, file);
  source.split('\n').forEach((line, index) => {
    const where = `${name}:${index + 1}`;
    // style nur für CSS-Variablen (Datenwerte wie Balkenbreiten), einzeilig:
    // style={{ '--name': … }}. Alles andere gehört in Klassen mit Tokens.
    const style = /\bstyle\s*=\s*\{(.*)$/.exec(line);
    if (style) {
      const object = /^\{(.*?)\}(?:\s+as\s+\w+)?\}/.exec(style[1]);
      const keys = object ? [...object[1].matchAll(/(?:^|,)\s*([^:,]+?)\s*:/g)].map((match) => match[1]) : [];
      if (!object || keys.length === 0 || keys.some((key) => !/^'--[\w-]+'$/.test(key))) {
        problems.push(`${where}: style-Attribut – nur CSS-Variablen ('--…') erlaubt, sonst Klassen mit Tokens`);
      }
    }
    if (COLOR_LITERAL.test(line)) {
      problems.push(`${where}: Farbwert im Code`);
    }
    if (TAILWIND_COLOR.test(line)) {
      problems.push(`${where}: Tailwind-Palettenfarbe statt Token`);
    }
    if (/className=/.test(line) && TAILWIND_ARBITRARY.test(line)) {
      problems.push(`${where}: Tailwind-Arbitrary-Value statt Token`);
    }
  });
}

const css = readFileSync(join(ROOT, 'app/globals.css'), 'utf8');
for (const section of SECTIONS) {
  const declarations = checkCss(css, section.name);
  const files = section.files.flatMap(listFiles).filter((file) => /\.(tsx?|jsx?)$/.test(file));
  files.forEach(checkTsx);
  console.log(`${section.name}: ${declarations} CSS-Deklarationen, ${files.length} Dateien geprüft`);
}

if (problems.length > 0) {
  console.error(`\n${problems.length} Verstöße gegen die Design-Tokens:\n${problems.map((p) => `  – ${p}`).join('\n')}`);
  process.exit(1);
}
console.log('✓ Nur zentrale Design-Tokens verwendet');
