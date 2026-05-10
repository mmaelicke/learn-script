/// <reference path="../pb_data/types.d.ts" />

migrate(
  (app) => {
    const questions = app.findCollectionByNameOrId("quiz_questions");
    questions.fields.add(
      new TextField({
        name: "answerComment",
        required: false,
        max: 4000,
      }),
    );
    questions.fields.add(
      new Field({
        help: "",
        hidden: false,
        max: 1,
        min: 0,
        name: "answerScore",
        onlyInt: false,
        presentable: false,
        required: false,
        system: false,
        type: "number",
      }),
    );
    questions.fields.add(
      new DateField({
        name: "checkedAt",
        required: false,
      }),
    );
    questions.fields.add(
      new TextField({
        name: "checkerKind",
        required: false,
        max: 64,
      }),
    );
    questions.fields.add(
      new TextField({
        name: "checkError",
        required: false,
        max: 2000,
      }),
    );
    app.save(questions);
  },
  (app) => {
    const questions = app.findCollectionByNameOrId("quiz_questions");
    for (const name of [
      "answerComment",
      "answerScore",
      "checkedAt",
      "checkerKind",
      "checkError",
    ]) {
      try {
        questions.fields.removeByName(name);
      } catch (_) {}
    }
    app.save(questions);
  },
);
