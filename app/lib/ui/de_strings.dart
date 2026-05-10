/// German UI copy (code and comments stay English).
abstract final class DeStrings {
  static const digitizingTitle = 'Notizen digitalisieren';
  static const subjectLabel = 'Fach / Thema';
  static const subjectHint = 'Vorhandenes wählen oder neues eingeben';
  static const photosSection = 'Fotos';
  static const addPhotoTooltip = 'Foto aus Galerie hinzufügen';
  static const deletePhotoTooltip = 'Foto entfernen';
  static const submitUpload = 'Hochladen und verarbeiten';
  static const uploading = 'Wird hochgeladen…';
  static const discardTitle = 'Fotos verwerfen?';
  static const discardBody = 'Alle Fotos in diesem Stapel gehen verloren.';
  static const discardConfirm = 'Verwerfen';
  static const cancel = 'Abbrechen';
  static const overviewStubTitle = 'Übersicht';
  static String overviewStubBody(String subject) =>
      'Übersicht für „$subject“ — Inhalt folgt.';
  static const fabAddNote = 'Notiz aufnehmen';
  static const uploadErrorTitle = 'Upload fehlgeschlagen';
  static const uploadErrorDismiss = 'Schließen';
  static const uploadNeedSignIn = 'Zum Hochladen ist eine gültige Anmeldung nötig.';
  static const pickImageError = 'Bild konnte nicht gewählt werden.';
}
