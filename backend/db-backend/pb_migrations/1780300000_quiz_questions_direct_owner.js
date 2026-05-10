/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    const questions = app.findCollectionByNameOrId("quiz_questions");

    try {
      questions.fields.addAt(
        0,
        new RelationField({
          name: "owner",
          required: false,
          maxSelect: 1,
          collectionId: users.id,
          cascadeDelete: false,
        }),
      );
    } catch (_) {}

    questions.listRule = "owner = @request.auth.id";
    questions.viewRule = "owner = @request.auth.id";
    questions.createRule =
      "@request.auth.id != '' && @request.body.owner = @request.auth.id";
    questions.updateRule = "owner = @request.auth.id";
    questions.deleteRule = "owner = @request.auth.id";
    app.save(questions);

    const rows = app.findRecordsByFilter("quiz_questions", "", "", 0, 0) || [];
    for (const question of rows) {
      const sessionId = question.getString("session");
      if (!sessionId) {
        continue;
      }
      try {
        const session = app.findRecordById("quiz_sessions", sessionId);
        const owner = session.getString("owner");
        if (owner) {
          question.set("owner", owner);
          app.save(question);
        }
      } catch (_) {}
    }
  },
  (app) => {
    const questions = app.findCollectionByNameOrId("quiz_questions");
    const ownerRule = "session.owner = @request.auth.id";
    questions.listRule = ownerRule;
    questions.viewRule = ownerRule;
    questions.createRule = ownerRule;
    questions.updateRule = ownerRule;
    questions.deleteRule = ownerRule;
    try {
      questions.fields.removeByName("owner");
    } catch (_) {}
    app.save(questions);
  },
);
