/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const col = app.findCollectionByNameOrId("quiz_sessions");
    col.fields.add(
      new Field({
        name: "sessionKind",
        type: "text",
        required: false,
        min: 0,
        max: 32,
      }),
    );
    col.fields.add(
      new Field({
        name: "progressBasis",
        type: "text",
        required: false,
        min: 0,
        max: 32,
      }),
    );
    app.save(col);
  },
  (app) => {
    const col = app.findCollectionByNameOrId("quiz_sessions");
    try {
      col.fields.removeByName("sessionKind");
    } catch (_) {}
    try {
      col.fields.removeByName("progressBasis");
    } catch (_) {}
    app.save(col);
  },
);
