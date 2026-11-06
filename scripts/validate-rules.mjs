#!/usr/bin/env node
/**
 * Valida reglas de PolicyKit (.rules) sin necesidad de polkitd.
 *
 * Comprueba que el archivo usa sintaxis ES5 compatible con el motor duktape
 * que emplea polkit y que registra al menos una regla con polkit.addRule o
 * polkit.addAdminRule. No ejecuta las reglas con acciones reales.
 */
import { readFileSync } from "node:fs";
import vm from "node:vm";

const files = process.argv.slice(2);

if (files.length === 0) {
  console.error("Uso: node scripts/validate-rules.mjs <archivo.rules> [...]");
  process.exit(2);
}

/**
 * Elimina comentarios y literales de texto para que las comprobaciones de
 * sintaxis no confundan su contenido con código.
 */
function stripCommentsAndStrings(source) {
  let output = "";
  let index = 0;

  while (index < source.length) {
    const current = source[index];
    const next = source[index + 1];

    if (current === "/" && next === "/") {
      while (index < source.length && source[index] !== "\n") {
        index += 1;
      }
      continue;
    }

    if (current === "/" && next === "*") {
      index += 2;
      while (index < source.length && !(source[index] === "*" && source[index + 1] === "/")) {
        index += 1;
      }
      index += 2;
      continue;
    }

    if (current === '"' || current === "'") {
      const quote = current;
      output += '""';
      index += 1;
      while (index < source.length) {
        if (source[index] === "\\") {
          index += 2;
          continue;
        }
        if (source[index] === quote) {
          index += 1;
          break;
        }
        index += 1;
      }
      continue;
    }

    output += current;
    index += 1;
  }

  return output;
}

const ES5_INCOMPATIBLE = [
  {
    pattern: /\b(?:let|const)\s+[A-Za-z_$]/,
    message: "usa 'var' en lugar de 'let'/'const': duktape no los admite",
  },
  { pattern: /=>/, message: "las funciones flecha no son compatibles con duktape; usa function" },
  { pattern: /`/, message: "las plantillas de texto no son compatibles con duktape" },
  { pattern: /\bclass\s+[A-Za-z_$]/, message: "las clases no son compatibles con duktape" },
  { pattern: /\.\.\./, message: "el operador de propagación no es compatible con duktape" },
  { pattern: /\b(?:async|await)\b/, message: "async/await no es compatible con duktape" },
];

function findIncompatibleSyntax(source) {
  const code = stripCommentsAndStrings(source);

  for (const { pattern, message } of ES5_INCOMPATIBLE) {
    if (pattern.test(code)) {
      return message;
    }
  }

  return null;
}

const resultNames = [
  "YES",
  "NO",
  "AUTH_SELF",
  "AUTH_SELF_KEEP",
  "AUTH_ADMIN",
  "AUTH_ADMIN_KEEP",
  "NOT_HANDLED",
];

const results = Object.fromEntries(resultNames.map((name) => [name, name.toLowerCase()]));
Object.freeze(results);

let failed = false;

for (const file of files) {
  const rules = [];
  const adminRules = [];

  const sandbox = {
    polkit: {
      Result: results,
      addRule(callback) {
        if (typeof callback !== "function") {
          throw new TypeError("polkit.addRule debe recibir una función");
        }
        rules.push(callback);
      },
      addAdminRule(callback) {
        if (typeof callback !== "function") {
          throw new TypeError("polkit.addAdminRule debe recibir una función");
        }
        adminRules.push(callback);
      },
      log() {
        // Las reglas pueden llamar a polkit.log; no hace falta mostrarlo.
      },
    },
  };

  try {
    const source = readFileSync(file, "utf8");
    const incompatible = findIncompatibleSyntax(source);

    if (incompatible !== null) {
      throw new Error(incompatible);
    }

    const script = new vm.Script(source, { filename: file });
    script.runInNewContext(sandbox, { timeout: 2000 });

    if (rules.length === 0 && adminRules.length === 0) {
      throw new Error("el archivo no registra ninguna regla con polkit.addRule/addAdminRule");
    }

    console.log(`OK   ${file} (${rules.length} regla(s), ${adminRules.length} admin)`);
  } catch (error) {
    failed = true;
    const message = error instanceof Error ? error.message : String(error);
    console.error(`FALLO ${file}: ${message}`);
  }
}

process.exit(failed ? 1 : 0);
