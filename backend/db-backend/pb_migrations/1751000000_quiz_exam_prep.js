/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const users = app.findCollectionByNameOrId("users");
    const ownerRule = "session.owner = @request.auth.id";
    const questionOwnerRule = "owner = @request.auth.id";

    const quizSessions = new Collection({
      type: "base",
      name: "quiz_sessions",
      listRule: "owner = @request.auth.id",
      viewRule: "owner = @request.auth.id",
      createRule:
        "@request.auth.id != '' && @request.body.owner = @request.auth.id",
      updateRule: "owner = @request.auth.id",
      deleteRule: "owner = @request.auth.id",
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
          name: "status",
          type: "text",
          required: true,
          min: 1,
          max: 32,
        },
        {
          name: "curriculumItemIds",
          type: "json",
          required: true,
        },
        {
          name: "questionCount",
          type: "number",
          required: false,
        },
        {
          name: "timeLimitSeconds",
          type: "number",
          required: false,
        },
        {
          name: "threadMessages",
          type: "json",
          required: false,
        },
      ],
      indexes: [
        "CREATE INDEX idx_quiz_sessions_scope ON quiz_sessions (owner, subject, grade)",
      ],
    });
    app.save(quizSessions);

    const sessions = app.findCollectionByNameOrId("quiz_sessions");

    const quizQuestions = new Collection({
      type: "base",
      name: "quiz_questions",
      listRule: questionOwnerRule,
      viewRule: questionOwnerRule,
      createRule:
        "@request.auth.id != '' && @request.body.owner = @request.auth.id",
      updateRule: questionOwnerRule,
      deleteRule: questionOwnerRule,
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
          name: "session",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: sessions.id,
          cascadeDelete: true,
        },
        {
          name: "toolCallId",
          type: "text",
          required: false,
          max: 128,
        },
        {
          name: "kind",
          type: "text",
          required: true,
          min: 1,
          max: 64,
        },
        {
          name: "content",
          type: "json",
          required: true,
        },
      ],
      indexes: [
        "CREATE INDEX idx_quiz_questions_session ON quiz_questions (session)",
        "CREATE UNIQUE INDEX idx_quiz_questions_session_tool ON quiz_questions (session, toolCallId)",
      ],
    });
    app.save(quizQuestions);

    const questions = app.findCollectionByNameOrId("quiz_questions");

    const quizAnswers = new Collection({
      type: "base",
      name: "quiz_answers",
      listRule: ownerRule,
      viewRule: ownerRule,
      createRule: ownerRule,
      updateRule: ownerRule,
      deleteRule: ownerRule,
      fields: [
        {
          name: "session",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: sessions.id,
          cascadeDelete: true,
        },
        {
          name: "question",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: questions.id,
          cascadeDelete: true,
        },
        {
          name: "payload",
          type: "json",
          required: true,
        },
        {
          name: "correct",
          type: "bool",
          required: false,
        },
        {
          name: "idempotencyKey",
          type: "text",
          required: false,
          max: 128,
        },
      ],
      indexes: [
        "CREATE UNIQUE INDEX idx_quiz_answers_session_question ON quiz_answers (session, question)",
      ],
    });
    app.save(quizAnswers);

    const quizMessages = new Collection({
      type: "base",
      name: "quiz_messages",
      listRule: ownerRule,
      viewRule: ownerRule,
      createRule: ownerRule,
      updateRule: ownerRule,
      deleteRule: ownerRule,
      fields: [
        {
          name: "session",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: sessions.id,
          cascadeDelete: true,
        },
        {
          name: "seq",
          type: "number",
          required: true,
        },
        {
          name: "eventType",
          type: "text",
          required: true,
          min: 1,
          max: 64,
        },
        {
          name: "payload",
          type: "json",
          required: true,
        },
        {
          name: "question",
          type: "relation",
          required: false,
          maxSelect: 1,
          collectionId: questions.id,
          cascadeDelete: false,
        },
        {
          name: "toolCallId",
          type: "text",
          required: false,
          max: 128,
        },
      ],
      indexes: [
        "CREATE UNIQUE INDEX idx_quiz_messages_session_seq ON quiz_messages (session, seq)",
      ],
    });
    app.save(quizMessages);

    const quizOutcomes = new Collection({
      type: "base",
      name: "quiz_session_outcomes",
      listRule: ownerRule,
      viewRule: ownerRule,
      createRule: ownerRule,
      updateRule: ownerRule,
      deleteRule: ownerRule,
      fields: [
        {
          name: "session",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: sessions.id,
          cascadeDelete: true,
        },
        {
          name: "details",
          type: "json",
          required: true,
        },
      ],
      indexes: [
        "CREATE UNIQUE INDEX idx_quiz_outcomes_session ON quiz_session_outcomes (session)",
      ],
    });
    app.save(quizOutcomes);
  },
  (app) => {
    try {
      app.delete(app.findCollectionByNameOrId("quiz_session_outcomes"));
    } catch (_) {}
    try {
      app.delete(app.findCollectionByNameOrId("quiz_messages"));
    } catch (_) {}
    try {
      app.delete(app.findCollectionByNameOrId("quiz_answers"));
    } catch (_) {}
    try {
      app.delete(app.findCollectionByNameOrId("quiz_questions"));
    } catch (_) {}
    try {
      app.delete(app.findCollectionByNameOrId("quiz_sessions"));
    } catch (_) {}
  },
);
