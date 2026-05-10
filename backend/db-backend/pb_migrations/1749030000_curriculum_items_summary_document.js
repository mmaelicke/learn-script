/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const items = app.findCollectionByNameOrId("curriculum_items");
    items.fields.add(
      new TextField({
        name: "summaryDocument",
        required: false,
        max: 500000,
      }),
    );
    app.save(items);
  },
  (app) => {
    const items = app.findCollectionByNameOrId("curriculum_items");
    items.fields.removeByName("summaryDocument");
    app.save(items);
  },
);
