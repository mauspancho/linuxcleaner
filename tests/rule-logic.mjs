#!/usr/bin/env node
/**
 * Comprueba la lógica de la regla de PolicyKit sin ejecutar polkitd.
 *
 * Carga el archivo .rules en un contexto aislado, captura la función
 * registrada con polkit.addRule y la invoca con acciones y sujetos simulados.
 */
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const RULE_FILE = new URL("../polkit/50-linuxcleaner.rules", import.meta.url);
const PROGRAM = "/usr/local/bin/linuxcleaner";
const COMMAND_LINE = `${PROGRAM} --privileged-clean`;

const resultNames = [
  "YES",
  "NO",
  "AUTH_SELF",
  "AUTH_SELF_KEEP",
  "AUTH_ADMIN",
  "AUTH_ADMIN_KEEP",
  "NOT_HANDLED",
];

const results = Object.freeze(
  Object.fromEntries(resultNames.map((name) => [name, name.toLowerCase()])),
);

const rules = [];
const sandbox = {
  polkit: {
    Result: results,
    addRule(callback) {
      rules.push(callback);
    },
    addAdminRule() {
      // La regla de LinuxCleaner no registra reglas de administración globales.
    },
    log() {
      // Las reglas pueden llamar a polkit.log; no hace falta mostrarlo.
    },
  },
};

const source = readFileSync(RULE_FILE, "utf8");
vm.runInNewContext(source, sandbox, { filename: RULE_FILE.pathname, timeout: 2000 });

assert.equal(rules.length, 1, "La regla debe registrar exactamente una función");

const [rule] = rules;

function makeAction({
  id = "org.freedesktop.policykit.exec",
  program = PROGRAM,
  commandLine = COMMAND_LINE,
} = {}) {
  return {
    id,
    lookup(key) {
      if (key === "program") {
        return program;
      }
      if (key === "command_line") {
        return commandLine;
      }
      return null;
    },
  };
}

function makeSubject({ local = true, active = true, groups = [] } = {}) {
  return {
    local,
    active,
    isInGroup(group) {
      return groups.includes(group);
    },
  };
}

const exactAction = makeAction();

assert.equal(
  rule(exactAction, makeSubject({ groups: ["wheel"] })),
  results.YES,
  "Un miembro de wheel debe ser autorizado",
);
assert.equal(
  rule(exactAction, makeSubject({ groups: ["sudo"] })),
  results.YES,
  "Un miembro de sudo debe ser autorizado",
);
assert.equal(
  rule(exactAction, makeSubject({ groups: ["admin"] })),
  results.YES,
  "Un miembro de admin debe ser autorizado",
);
assert.equal(
  rule(exactAction, makeSubject({ groups: ["users"] })),
  results.AUTH_ADMIN,
  "Un usuario sin grupo administrativo debe autenticarse",
);
assert.equal(
  rule(exactAction, makeSubject({ local: false, groups: ["wheel"] })),
  results.NOT_HANDLED,
  "Una sesión no local no debe autorizarse automáticamente",
);
assert.equal(
  rule(exactAction, makeSubject({ active: false, groups: ["wheel"] })),
  results.NOT_HANDLED,
  "Una sesión inactiva no debe autorizarse automáticamente",
);
assert.equal(
  rule(makeAction({ id: "org.freedesktop.other" }), makeSubject({ groups: ["wheel"] })),
  results.NOT_HANDLED,
  "Otra acción de PolicyKit no debe coincidir",
);
assert.equal(
  rule(makeAction({ program: "/usr/bin/otro" }), makeSubject({ groups: ["wheel"] })),
  results.NOT_HANDLED,
  "Otro programa no debe coincidir",
);
assert.equal(
  rule(makeAction({ commandLine: `${PROGRAM}` }), makeSubject({ groups: ["wheel"] })),
  results.NOT_HANDLED,
  "La ausencia de --privileged-clean no debe coincidir",
);
assert.equal(
  rule(
    makeAction({ commandLine: `${PROGRAM} --privileged-clean --extra` }),
    makeSubject({ groups: ["wheel"] }),
  ),
  results.NOT_HANDLED,
  "Los argumentos adicionales no deben coincidir",
);

console.log("OK   Lógica de la regla de PolicyKit");
