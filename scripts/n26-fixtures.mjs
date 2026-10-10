#!/usr/bin/env node
/**
 * Testdateien für den PDF-Import (N26): erzeugt aus den pseudonymisierten
 * Beschreibungen tests/fixtures/n26/*.json PDFs im Layout der
 * N26-Kontoauszüge (Hauptkonto und Spaces, Buchungsseiten,
 * Zusammenfassungen, Anmerkung; Positionen wie im Original). Die
 * Originalauszüge werden nie eingecheckt.
 *
 *   node scripts/n26-fixtures.mjs
 *
 * JSON: { provisional, number, period: [von, bis], created, holder: { name,
 * address }, sections: [{ kind: main|space, name, opened, iban, bic,
 * opening: "+914,08€", closing? (nur zum Erzeugen fehlerhafter Auszüge),
 * bookings: [{ counterparty, date, amount, type?, iban?, bic?, purpose?,
 * value, breakAfter? }] }] }. Ein- und Ausgänge sowie der neue Stand werden
 * aus den Buchungen berechnet. Eine Buchung, die nicht mehr auf die Seite
 * passt, beginnt auf der nächsten; breakAfter: n erzwingt dagegen einen
 * Seitenumbruch nach ihrer n-ten Zeile (Verwendungszweck über zwei Seiten).
 */
import { readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'tests', 'fixtures', 'n26');

const PAGE = { width: 595.275, height: 841.875 };
const SIZE = { title: 16, meta: 10.5, big: 12, small: 10, team: 12.5 };
const LEFT = 43.8;
const DATE_X = 390;
const AMOUNT_X = 495;
const BOTTOM = 110;

// WinAnsiEncoding für die wenigen Zeichen außerhalb von Latin-1.
const WIN_ANSI = { '€': 0x80, '‚': 0x82, '„': 0x84, '…': 0x85, '‘': 0x91, '’': 0x92, '“': 0x93, '”': 0x94, '•': 0x95, '–': 0x96, '—': 0x97 };

function pdfString(text) {
  let out = '';
  for (const char of text) {
    const code = WIN_ANSI[char] ?? char.codePointAt(0);
    if (code > 255) {
      throw new Error(`Zeichen nicht darstellbar: ${char}`);
    }
    const c = String.fromCharCode(code);
    out += c === '\\' || c === '(' || c === ')' ? `\\${c}` : c;
  }
  return `(${out})`;
}

const cents = (text) => {
  const match = /^([+-])?([\d.]+),(\d{2})€$/.exec(text);
  if (!match) {
    throw new Error(`Betrag: ${text}`);
  }
  const value = Number(match[2].replace(/\./g, '')) * 100 + Number(match[3]);
  return match[1] === '-' ? -value : value;
};

const euro = (value, sign = true) => {
  const abs = Math.abs(value);
  const whole = String(Math.floor(abs / 100)).replace(/\B(?=(\d{3})+(?!\d))/g, '.');
  const text = `${whole},${String(abs % 100).padStart(2, '0')}€`;
  return value < 0 ? `-${text}` : value > 0 && sign ? `+${text}` : text;
};

/** Text auf Zeilen von höchstens max Zeichen umbrechen (an Leerzeichen). */
function wrap(text, max) {
  const lines = [];
  let line = '';
  for (const word of text.split(/\s+/).filter(Boolean)) {
    if (line && line.length + 1 + word.length > max) {
      lines.push(line);
      line = word;
    } else {
      line = line ? `${line} ${word}` : word;
    }
  }
  if (line) {
    lines.push(line);
  }
  return lines;
}

function build(spec) {
  const pages = [];
  const prefix = spec.provisional ? 'Vorläufiger ' : '';
  const nr = spec.number ? ` Nr. ${spec.number}` : '';
  const period = `${spec.period[0]} bis ${spec.period[1]}`;

  const newPage = (section, kind) => {
    const page = { texts: [], section };
    const t = (text, x, y, size, font = 'F1') => page.texts.push({ text, x, y, size, font });
    const space = section?.kind === 'space';
    let y;
    if (kind === 'notes') {
      t('Kontoauszug', LEFT, 790, SIZE.title);
      t(period, LEFT, 756.5, SIZE.meta);
      y = 704.4;
    } else if (space) {
      const title = kind === 'summary' ? `Spaces Zusammenfassung${nr}` : `${prefix}Space Kontoauszug${nr}`;
      t(title, LEFT, 790, SIZE.title);
      t(`Space: ${section.name}`, LEFT, 756.5, SIZE.meta);
      t(`Datum geöffnet: ${section.opened}`, LEFT, 739.7, SIZE.meta);
      t(period, LEFT, 722.9, SIZE.meta);
      y = 670.8;
    } else {
      const first = kind === 'bookings' && !pages.some((p) => p.section === section);
      const title = kind === 'summary' ? `Zusammenfassung${nr}` : `${prefix}Kontoauszug${nr}`;
      t(title, LEFT, first ? 784 : 790, SIZE.title);
      t(period, LEFT, first ? 750.5 : 756.5, SIZE.meta);
      y = first ? 698.4 : 704.4;
    }
    if (kind !== 'notes') {
      t('Beschreibung', 44.5, y, SIZE.big);
      if (kind === 'bookings') {
        t('Verbuchungsdatum', 341.7, y, SIZE.big);
        t('Betrag', 515.1, y, SIZE.big);
      }
    }
    page.t = t;
    page.y = y - 26.7;
    pages.push(page);
    return page;
  };

  for (const section of spec.sections) {
    let page = newPage(section, 'bookings');
    let first = true;
    let incoming = 0;
    let outgoing = 0;
    for (const booking of section.bookings) {
      const amount = cents(booking.amount);
      if (amount > 0) {
        incoming += amount;
      } else {
        outgoing += amount;
      }
      // Zeilen der Buchung mit Abstand zur vorigen Zeile.
      const lines = [];
      wrap(booking.counterparty, 44).forEach((text, i) => lines.push({ text, size: SIZE.big, gap: i === 0 ? 0 : 13.8, head: i === 0 }));
      const small = [];
      if (booking.type) {
        small.push(booking.type);
      }
      if (booking.iban) {
        small.push(`IBAN: ${booking.iban}${booking.bic ? ` • BIC: ${booking.bic}` : ''}`);
      }
      if (booking.purpose) {
        small.push(...wrap(booking.purpose, 54));
      }
      small.push(`Wertstellung ${booking.value}`);
      small.forEach((text, i) => lines.push({ text, size: SIZE.small, gap: i === 0 ? 13.3 : 16 }));

      const height = lines.reduce((sum, line) => sum + line.gap, 0);
      const startGap = first ? 0 : 26.1;
      if (booking.breakAfter === undefined && page.y - startGap - height < BOTTOM) {
        page = newPage(section, 'bookings');
        first = true;
      }
      let y = page.y - (first ? 0 : 26.1);
      for (const [i, line] of lines.entries()) {
        if (i > 0) {
          y -= line.gap;
        }
        if (i === booking.breakAfter || y < BOTTOM) {
          page = newPage(section, 'bookings');
          y = page.y;
        }
        page.t(line.text, LEFT, y, line.size);
        if (line.head) {
          page.t(booking.date, DATE_X, y - 1.9, line.size);
          page.t(booking.amount, AMOUNT_X, y - 1.9, line.size);
        }
      }
      page.y = y;
      first = false;
    }

    const opening = cents(section.opening);
    const closing = section.closing ? cents(section.closing) : opening + incoming + outgoing;
    const summary = newPage(section, 'summary');
    const rows = [
      ['Dein alter Kontostand', euro(opening)],
      ['Ausgehende Transaktionen', euro(outgoing)],
      ['Einkommende Transaktionen', euro(incoming)],
      ['Dein neuer Kontostand', euro(closing)],
    ];
    let y = summary.y;
    for (const [label, value] of rows) {
      summary.t(label, LEFT, y, SIZE.big);
      summary.t(value, AMOUNT_X, y, SIZE.big);
      y -= 26.1;
    }
  }

  const notes = newPage(spec.sections[0], 'notes');
  let y = 675.8;
  for (const text of [
    'Es kann zu Abweichungen zwischen diesem Dokument und der Anzeige in deiner App oder',
    'dem Onlinebanking kommen, da Transaktionen in Echtzeit dargestellt werden, die tatsächliche',
    'Durchführung hingegen 1-2 Tage in Anspruch nehmen kann. Auf diesem Dokument werden',
    'nur vollständig durchgeführte Transaktionen abgebildet.',
  ]) {
    notes.t(text, LEFT, y, SIZE.big);
    y -= 19.3;
  }
  notes.t('Anmerkung', 44.5, 704.4, SIZE.big);
  notes.t('Dein N26 Team', LEFT, y - 30, SIZE.team, 'F2');

  // Seitenfuß
  pages.forEach((page, index) => {
    const section = page.section;
    page.t(spec.holder.name, 42.8, 69.3, SIZE.small);
    page.t('Erstellt am', 505.2, 69.3, SIZE.small);
    page.t(spec.holder.address, 42.8, 53.5, SIZE.small);
    page.t(spec.created, 504.8, 53.5, SIZE.small);
    page.t(`${section.kind === 'space' ? 'Space ' : ''}IBAN: ${section.iban} • BIC: ${section.bic}`, 42.8, 37.5, SIZE.small);
    if (spec.number) {
      page.t(`Nr. ${spec.number}`, 496.8, 37.5, SIZE.small);
    }
    page.t(`${index + 1} / ${pages.length}`, 525, 21.3, SIZE.small);
  });

  return pages;
}

function writePdf(pages) {
  const objects = [];
  const add = (body) => {
    objects.push(body);
    return objects.length;
  };
  const catalog = add(null);
  const pagesId = add(null);
  const f1 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
  const f2 = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>');
  const kids = [];
  for (const page of pages) {
    const content = page.texts
      .map((t) => `BT /${t.font} ${t.size} Tf 1 0 0 1 ${t.x.toFixed(2)} ${t.y.toFixed(2)} Tm ${pdfString(t.text)} Tj ET`)
      .join('\n');
    const stream = add(`<< /Length ${Buffer.byteLength(content, 'latin1')} >>\nstream\n${content}\nendstream`);
    kids.push(
      add(
        `<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 ${PAGE.width} ${PAGE.height}] ` +
          `/Resources << /Font << /F1 ${f1} 0 R /F2 ${f2} 0 R >> >> /Contents ${stream} 0 R >>`,
      ),
    );
  }
  objects[catalog - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`;
  objects[pagesId - 1] = `<< /Type /Pages /Kids [${kids.map((k) => `${k} 0 R`).join(' ')}] /Count ${kids.length} >>`;

  let out = '%PDF-1.4\n%\xe2\xe3\xcf\xd3\n';
  const offsets = [];
  objects.forEach((body, i) => {
    offsets.push(Buffer.byteLength(out, 'latin1'));
    out += `${i + 1} 0 obj\n${body}\nendobj\n`;
  });
  const xref = Buffer.byteLength(out, 'latin1');
  out += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`;
  out += offsets.map((o) => `${String(o).padStart(10, '0')} 00000 n \n`).join('');
  out += `trailer\n<< /Size ${objects.length + 1} /Root ${catalog} 0 R >>\nstartxref\n${xref}\n%%EOF\n`;
  return Buffer.from(out, 'latin1');
}

for (const file of readdirSync(DIR).filter((name) => name.endsWith('.json')).sort()) {
  const spec = JSON.parse(readFileSync(join(DIR, file), 'utf8'));
  const target = join(DIR, file.replace(/\.json$/, '.pdf'));
  writeFileSync(target, writePdf(build(spec)));
  console.log(`${file} → ${target.split('/').slice(-3).join('/')}`);
}
