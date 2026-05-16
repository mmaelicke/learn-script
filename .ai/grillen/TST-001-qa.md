# TST-001: Q&A Protocol

1. **Q:** Was zeigt das Dropdown genau — alle drei Typen oder nur die relevanten?
   **A:** Nur `assessment` und `learn`. `deepen` wird explizit ausgelassen.

2. **Q:** Was ist die Schwelle für "Mehrheit" (ab wann wechselt der Default auf `learn`)?
   **A:** 70% der selektierten Items haben `hasEndedAssessment == true`.

3. **Q:** Wann wird der Assessment-Status der Items berechnet (beim Rendern oder beim Klick)?
   **A:** Beim Rendern — Sessions sind bereits im Screen-State vorhanden und werden übergeben. Kein extra Fetch nötig.

4. **Q:** Was passiert beim Klick auf einen Dropdown-Eintrag — direkt starten oder Bestätigung?
   **A:** Direkt starten, kein Dialog.

5. **Q:** Wie verhält sich der Button-Text — statisch "Lern-Deck" oder dynamisch?
   **A:** Dynamisch: Button-Text wechselt mit der Dropdown-Auswahl zu "Assessment starten" bzw. "Lernen starten".

6. **Q:** Bleibt das Single-Unit-Verhalten unverändert?
   **A:** Ja, das automatische Verhalten bleibt. Allerdings sollen neue Button-Icons bei Single-Unit-Buttons gespiegelt werden.

7. **Q:** Welche Icons sollen `assessment` und `learn` repräsentieren?
   **A:** `Icons.quiz_outlined` für Assessment, `Icons.school_outlined` für Learn.

8. **Q:** Wie viele Fragen bei Multi-Unit Assessment?
   **A:** `clamp(anzahl_items, 3, 12)` — also grob 1 pro Unit, mindestens 3, maximal 12. Das Backend hardcodet aktuell 5 und muss angepasst werden.
