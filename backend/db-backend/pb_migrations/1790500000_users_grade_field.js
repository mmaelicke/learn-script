/// <reference path="../pb_data/types.d.ts" />

/**
 * Adds optional `users.grade` (1–12) so prod matches local/schema expectations.
 * Idempotent: skips if a field named `grade` already exists (e.g. added in Admin UI).
 */
migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    for (const f of users.fields) {
      if (f.name === "grade") {
        return;
      }
    }
    users.fields.addAt(users.fields.length, new Field({
      help: "",
      hidden: false,
      id: "number1790500001",
      max: 12,
      min: 1,
      name: "grade",
      onlyInt: true,
      presentable: true,
      required: false,
      system: false,
      type: "number",
    }));
    app.save(users);
  },
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    try {
      users.fields.removeById("number1790500001");
      app.save(users);
    } catch (_) {}
  },
);
