/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    const items = app.findCollectionByNameOrId("curriculum_items");

    const ownerRule = "owner = @request.auth.id";
    const mutRule = "@request.auth.id != '' && owner = @request.auth.id";

    let topics = new Collection({
      type: "base",
      name: "curriculum_topics",
      listRule: ownerRule,
      viewRule: ownerRule,
      createRule: mutRule,
      updateRule: mutRule,
      deleteRule: ownerRule,
      fields: [
        {
          name: "owner",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: users.id,
          cascadeDelete: false,
        },
        {
          name: "grade",
          type: "number",
          required: true,
        },
        {
          name: "subject",
          type: "text",
          required: true,
          min: 1,
          max: 200,
        },
        {
          name: "title",
          type: "text",
          required: true,
          min: 1,
          max: 300,
        },
        {
          name: "titleNorm",
          type: "text",
          required: true,
          min: 1,
          max: 300,
        },
        {
          name: "sortOrder",
          type: "number",
          required: true,
        },
        {
          name: "frozen",
          type: "bool",
          required: false,
        },
      ],
      indexes: [
        "CREATE INDEX idx_curriculum_topics_scope ON curriculum_topics (owner, subject, grade, sortOrder)",
      ],
    });

    app.save(topics);

    topics = app.findCollectionByNameOrId("curriculum_topics");
    topics.fields.add(
      new RelationField({
        name: "parent",
        required: false,
        maxSelect: 1,
        collectionId: topics.id,
        cascadeDelete: false,
      }),
    );
    app.save(topics);

    items.fields.add(
      new RelationField({
        name: "topicId",
        required: true,
        maxSelect: 1,
        collectionId: topics.id,
        cascadeDelete: false,
      }),
    );
    try {
      items.fields.removeByName("parent");
    } catch (_) {}
    try {
      items.fields.removeByName("topic");
    } catch (_) {}
    app.save(items);
  },
  (app) => {
    const items = app.findCollectionByNameOrId("curriculum_items");
    try {
      items.fields.removeByName("topicId");
    } catch (_) {}
    items.fields.add(
      new TextField({
        name: "topic",
        required: false,
        max: 300,
      }),
    );
    app.save(items);

    const refreshedItems = app.findCollectionByNameOrId("curriculum_items");
    refreshedItems.fields.add(
      new RelationField({
        name: "parent",
        required: false,
        maxSelect: 1,
        collectionId: refreshedItems.id,
        cascadeDelete: false,
      }),
    );
    app.save(refreshedItems);

    try {
      app.delete(app.findCollectionByNameOrId("curriculum_topics"));
    } catch (_) {}
  },
);
