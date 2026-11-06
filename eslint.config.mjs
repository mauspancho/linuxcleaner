const sharedRules = {
  curly: ["error", "all"],
  eqeqeq: ["error", "always"],
  "no-undef": "error",
  "no-unused-vars": ["error", { args: "after-used" }],
};

export default [
  {
    ignores: [".tools/**", "node_modules/**", "dist/**"],
  },
  {
    files: ["**/*.rules"],
    languageOptions: {
      // polkit evalúa las reglas con duktape: se exige sintaxis ES5.
      ecmaVersion: 5,
      sourceType: "script",
      globals: {
        polkit: "readonly",
      },
    },
    rules: {
      ...sharedRules,
      "no-eval": "error",
      "no-implied-eval": "error",
      "no-new-func": "error",
      "no-var": "off",
      "prefer-const": "off",
    },
  },
  {
    files: ["**/*.mjs"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: {
        Buffer: "readonly",
        console: "readonly",
        process: "readonly",
        setTimeout: "readonly",
        clearTimeout: "readonly",
        URL: "readonly",
      },
    },
    rules: sharedRules,
  },
];
