/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const sessions = app.findCollectionByNameOrId("quiz_sessions");
    sessions.fields.add(
      new JSONField({
        name: "questionPlan",
        required: false,
        maxSize: 2000000,
      }),
    );
    sessions.fields.add(
      new JSONField({
        name: "evaluationSnapshots",
        required: false,
        maxSize: 2000000,
      }),
    );
    app.save(sessions);

    const questions = app.findCollectionByNameOrId("quiz_questions");
    questions.fields.add(
      new Field({
        help: "",
        hidden: false,
        max: null,
        min: null,
        name: "planIndex",
        onlyInt: true,
        presentable: false,
        required: false,
        system: false,
        type: "number",
      }),
    );
    questions.fields.add(
      new TextField({
        name: "curriculumItemId",
        required: false,
        max: 64,
      }),
    );
    questions.fields.add(
      new TextField({
        name: "requestId",
        required: false,
        max: 128,
      }),
    );
    questions.fields.add(
      new TextField({
        name: "stemNorm",
        required: false,
        max: 600,
      }),
    );

    const existing = questions.indexes || [];
    questions.indexes = [
      ...existing,
      "CREATE UNIQUE INDEX idx_quiz_questions_session_plan_idx ON quiz_questions (session, planIndex) WHERE planIndex > 0",
      "CREATE UNIQUE INDEX idx_quiz_questions_session_request ON quiz_questions (session, requestId) WHERE requestId IS NOT NULL AND requestId != ''",
    ];
    app.save(questions);
  },
  (app) => {
    const questions = app.findCollectionByNameOrId("quiz_questions");
    const existing = questions.indexes || [];
    questions.indexes = existing.filter(
      (idx) =>
        !idx.includes("idx_quiz_questions_session_plan_idx") &&
        !idx.includes("idx_quiz_questions_session_request"),
    );
    for (const name of ["planIndex", "curriculumItemId", "requestId", "stemNorm"]) {
      try {
        questions.fields.removeByName(name);
      } catch (_) {}
    }
    app.save(questions);

    const sessions = app.findCollectionByNameOrId("quiz_sessions");
    for (const name of ["questionPlan", "evaluationSnapshots"]) {
      try {
        sessions.fields.removeByName(name);
      } catch (_) {}
    }
    app.save(sessions);
  },
);
