/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users");

    const ownerRule = "owner = @request.auth.id";
    const mutRule =
      "@request.auth.id != '' && owner = @request.auth.id";

    const captures = new Collection({
      type: "base",
      name: "captures",
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
          name: "file",
          type: "file",
          required: true,
          maxSelect: 1,
          maxSize: 52428800,
          mimeTypes: [
            "image/jpeg",
            "image/png",
            "image/webp",
            "image/gif",
            "application/pdf",
          ],
        },
        {
          name: "sortOrder",
          type: "number",
          required: true,
        },
        {
          name: "transcript",
          type: "text",
          required: false,
          max: 500000,
        },
        {
          name: "indexingStatus",
          type: "text",
          required: false,
          max: 64,
        },
      ],
      indexes: [
        "CREATE INDEX idx_captures_scope ON captures (owner, subject, grade, sortOrder)",
      ],
    });

    app.save(captures);

    let items = new Collection({
      type: "base",
      name: "curriculum_items",
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
          required: false,
          max: 500,
        },
        {
          name: "sortOrder",
          type: "number",
          required: false,
        },
        {
          name: "captureIds",
          type: "json",
          required: false,
        },
        {
          name: "summaryDirty",
          type: "bool",
          required: false,
        },
      ],
      indexes: [
        "CREATE INDEX idx_curriculum_items_scope ON curriculum_items (owner, subject, grade)",
      ],
    });

    app.save(items);

    items = app.findCollectionByNameOrId("curriculum_items");
    items.fields.add(
      new RelationField({
        name: "parent",
        required: false,
        maxSelect: 1,
        collectionId: items.id,
        cascadeDelete: false,
      }),
    );
    app.save(items);
  },
  (app) => {
    try {
      app.delete(app.findCollectionByNameOrId("curriculum_items"));
    } catch (_) {}
    try {
      app.delete(app.findCollectionByNameOrId("captures"));
    } catch (_) {}
  },
);
