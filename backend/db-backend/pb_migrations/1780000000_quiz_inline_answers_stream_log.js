/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const questions = app.findCollectionByNameOrId("quiz_questions");
    questions.fields.add(
      new JSONField({
        name: "answerPayload",
        required: false,
        maxSize: 2000000,
      }),
    );
    questions.fields.add(
      new BoolField({
        name: "answerCorrect",
        required: false,
      }),
    );
    questions.fields.add(
      new TextField({
        name: "answerIdempotencyKey",
        required: false,
        max: 128,
      }),
    );
    questions.fields.add(
      new DateField({
        name: "answeredAt",
        required: false,
      }),
    );
    app.save(questions);

    const answers = app.findRecordsByFilter("quiz_answers", "", "", 0, 0) || [];
    for (const ans of answers) {
      if (!ans) {
        continue;
      }
      const qid = ans.getString("question");
      if (!qid) {
        continue;
      }
      let q;
      try {
        q = app.findRecordById("quiz_questions", qid);
      } catch (_) {
        continue;
      }
      const payload = ans.get("payload");
      if (payload !== null && payload !== undefined) {
        q.set("answerPayload", payload);
      }
      const correct = ans.get("correct");
      if (correct !== null && correct !== undefined) {
        q.set("answerCorrect", !!correct);
      }
      const idem = ans.get("idempotencyKey");
      if (idem !== null && idem !== undefined && idem !== "") {
        q.set("answerIdempotencyKey", String(idem));
      }
      app.save(q);
    }

    try {
      app.delete(app.findCollectionByNameOrId("quiz_messages"));
    } catch (_) {}
    try {
      app.delete(app.findCollectionByNameOrId("quiz_answers"));
    } catch (_) {}

    const sessions = app.findCollectionByNameOrId("quiz_sessions");
    sessions.fields.add(
      new FileField({
        name: "streamLog",
        required: false,
        maxSelect: 1,
        maxSize: 52428800,
        mimeTypes: [
          "application/x-ndjson",
          "application/json",
          "text/plain",
          "application/octet-stream",
        ],
      }),
    );
    sessions.fields.add(
      new DateField({
        name: "streamLogAt",
        required: false,
      }),
    );
    app.save(sessions);
  },
  (app) => {
    const sessions = app.findCollectionByNameOrId("quiz_sessions");
    try {
      sessions.fields.removeByName("streamLog");
    } catch (_) {}
    try {
      sessions.fields.removeByName("streamLogAt");
    } catch (_) {}
    app.save(sessions);

    const questions = app.findCollectionByNameOrId("quiz_questions");
    for (const name of [
      "answerPayload",
      "answerCorrect",
      "answerIdempotencyKey",
      "answeredAt",
    ]) {
      try {
        questions.fields.removeByName(name);
      } catch (_) {}
    }
    app.save(questions);
  },
);
