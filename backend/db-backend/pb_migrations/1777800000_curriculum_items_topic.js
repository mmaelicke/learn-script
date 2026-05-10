/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const items = app.findCollectionByNameOrId("curriculum_items");
    items.fields.add(
      new TextField({
        name: "topic",
        required: false,
        max: 300,
      }),
    );
    app.save(items);
  },
  (app) => {
    const items = app.findCollectionByNameOrId("curriculum_items");
    items.fields.removeByName("topic");
    app.save(items);
  },
);
