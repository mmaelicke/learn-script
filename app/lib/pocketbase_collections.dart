/// PocketBase auth collection (matches backend `USERS_COLLECTION`).
const String kUsersCollection = 'users';

/// Curriculum capture uploads (see db-backend migrations).
const String kCapturesCollection = 'captures';

/// Ordered topic tree for a user/grade/subject scope.
const String kCurriculumTopicsCollection = 'curriculum_topics';

/// Lesson-sized content units attached to exactly one topic.
const String kCurriculumItemsCollection = 'curriculum_items';

/// Chat-like learn deck sessions.
const String kQuizSessionsCollection = 'quiz_sessions';

/// Canonical learn deck questions with inline answer/check state.
const String kQuizQuestionsCollection = 'quiz_questions';
