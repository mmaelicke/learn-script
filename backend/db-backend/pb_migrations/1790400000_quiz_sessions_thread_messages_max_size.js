/// <reference path="../pb_data/types.d.ts" />

/**
 * quiz_sessions.threadMessages was given maxSize: 0 in 1777701824_updated_quiz_sessions.js,
 * which rejects any non-empty JSON and breaks PATCH after the quiz agent runs.
 */
migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("quiz_sessions");
    try {
      const f = col.fields.getByName("threadMessages");
      if (f) {
        f.maxSize = 2000000;
      }
    } catch (_) {}
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("quiz_sessions");
    try {
      const f = col.fields.getByName("threadMessages");
      if (f) {
        f.maxSize = 0;
      }
    } catch (_) {}
    app.save(col);
  },
);
