#!/usr/bin/env python3
"""Generate Scedra/Localizable.xcstrings with en/es/fr/de."""

import json
from pathlib import Path

# key -> (comment, en, es, fr, de)
STRINGS: dict[str, tuple[str, str, str, str, str]] = {}


def add(key: str, en: str, es: str, fr: str, de: str, comment: str = "") -> None:
    STRINGS[key] = (comment, en, es, fr, de)


# --- Tabs / chrome already localized, plus German ---
add("Capture", "Capture", "Captura", "Saisie", "Erfassen", "Tab title for speaking, photo, or typing an appointment.")
add("Calendar", "Calendar", "Calendario", "Calendrier", "Kalender", "Tab and screen title for the day timeline.")
add("Review", "Review", "Revisar", "Vérifier", "Prüfen", "Button and screen title for checking a draft before save.")
add("Settings", "Settings", "Ajustes", "Réglages", "Einstellungen", "Settings screen and gear accessibility label.")
add("Today", "Today", "Hoy", "Aujourd’hui", "Heute", "Home list heading and jump-to-today button.")
add("Confirm", "Confirm", "Confirmar", "Confirmer", "Bestätigen", "Review footer — save this appointment.")
add("Cancel", "Cancel", "Cancelar", "Annuler", "Abbrechen", "Dismiss a photo session or a delete alert.")
add("Navigate", "Navigate", "Navegar", "Itinéraire", "Route", "Open maps directions to the appointment.")
add("Leave now", "Leave now", "Salir ahora", "Partir maintenant", "Jetzt losfahren", "Navigate button once leave-by has arrived.")
add("Driving", "Driving", "En coche", "En voiture", "Mit dem Auto", "Per-appointment travel toggle. Notes still store English Driving.")
add("Public transport", "Public transport", "Transporte público", "Transports en commun", "Öffentliche Verkehrsmittel", "Per-appointment travel toggle. Notes still store English Public transport.")
add("Leave by %@", "Leave by %@", "Salir a las %@", "Partir à %@", "Los um %@", "Today list clock when travel is known. Time is already locale-formatted. Stored notes stay English Leave by.")
add("leaveByInline %@", "leave by %@", "salir a las %@", "partir à %@", "los um %@", "Leave-by phrase inside the Review travel line.")
add("Look", "Look", "Apariencia", "Apparence", "Aussehen", "Settings label for the theme row.")
add("Hear", "Hear", "Escuchar", "Écouter", "Anhören", "Review button that speaks the draft summary.")
add("View original", "View original", "Ver original", "Voir l’original", "Original anzeigen", "Review button that shows spoken, typed, or OCR source.")
add("Choose photo", "Choose photo", "Elegir foto", "Choisir une photo", "Foto wählen", "Capture button that opens the photo picker.")
add("Start listen", "Start listen", "Empezar a escuchar", "Commencer l’écoute", "Zuhören starten", "Capture button that starts the microphone.")
add("Stop", "Stop", "Detener", "Arrêter", "Stopp", "Capture button that hangs up the microphone.")
add("Done", "Done", "Hecho", "OK", "Fertig", "Dismiss Settings, details, or the keyboard.")

# --- Travel display (the screenshot bug) ---
add(
    "Calendar block %@, including the drive there and back",
    "Calendar block %@, including the drive there and back",
    "Bloque de calendario %@, trayecto de ida y vuelta incluido",
    "Bloc calendrier %@, trajet aller-retour compris",
    "Kalenderblock %@, Hin- und Rückfahrt inklusive",
    "Details/Review caption for a drive-padded EventKit block. Window is already locale-formatted.",
)
add(
    "Calendar block %@, including the transit there and back",
    "Calendar block %@, including the transit there and back",
    "Bloque de calendario %@, transporte de ida y vuelta incluido",
    "Bloc calendrier %@, transports aller-retour compris",
    "Kalenderblock %@, Hin- und Rückfahrt mit ÖPNV inklusive",
    "Details/Review caption for a transit-padded EventKit block.",
)
add(
    "Calendar block %@, including the walk there and back",
    "Calendar block %@, including the walk there and back",
    "Bloque de calendario %@, ida y vuelta a pie incluida",
    "Bloc calendrier %@, marche aller-retour comprise",
    "Kalenderblock %@, Hin- und Rückweg zu Fuß inklusive",
    "Details/Review caption for a walk-padded EventKit block.",
)
add(
    "~%lld min drive there · ~%lld min back · ~%lld min round trip",
    "~%lld min drive there · ~%lld min back · ~%lld min round trip",
    "~%lld min en coche · ~%lld min de vuelta · ~%lld min ida y vuelta",
    "~%lld min en voiture · ~%lld min retour · ~%lld min aller-retour",
    "~%lld Min. mit dem Auto · ~%lld Min. zurück · ~%lld Min. Hin und zurück",
    "Live and saved drive line on Review and details.",
)
add(
    "~%lld min transit there · ~%lld min back · ~%lld min round trip",
    "~%lld min transit there · ~%lld min back · ~%lld min round trip",
    "~%lld min en transporte · ~%lld min de vuelta · ~%lld min ida y vuelta",
    "~%lld min en transports · ~%lld min retour · ~%lld min aller-retour",
    "~%lld Min. mit Bahn/Bus · ~%lld Min. zurück · ~%lld Min. Hin und zurück",
    "Live and saved transit line on Review and details.",
)
add(
    "~%lld min walk there · ~%lld min back · ~%lld min round trip",
    "~%lld min walk there · ~%lld min back · ~%lld min round trip",
    "~%lld min a pie · ~%lld min de vuelta · ~%lld min ida y vuelta",
    "~%lld min à pied · ~%lld min retour · ~%lld min aller-retour",
    "~%lld Min. zu Fuß · ~%lld Min. zurück · ~%lld Min. Hin und zurück",
    "Live and saved walk line on Review and details.",
)
add("~%lld min drive there", "~%lld min drive there", "~%lld min en coche", "~%lld min en voiture", "~%lld Min. mit dem Auto")
add("~%lld min transit there", "~%lld min transit there", "~%lld min en transporte", "~%lld min en transports", "~%lld Min. mit Bahn/Bus")
add("~%lld min walk there", "~%lld min walk there", "~%lld min a pie", "~%lld min à pied", "~%lld Min. zu Fuß")
add("~%lld min drive", "~%lld min drive", "~%lld min en coche", "~%lld min en voiture", "~%lld Min. mit dem Auto")
add("~%lld min transit", "~%lld min transit", "~%lld min en transporte", "~%lld min en transports", "~%lld Min. mit Bahn/Bus")
add("~%lld min walk", "~%lld min walk", "~%lld min a pie", "~%lld min à pied", "~%lld Min. zu Fuß")
add("~%lld min drive each way", "~%lld min drive each way", "~%lld min en coche por trayecto", "~%lld min en voiture dans chaque sens", "~%lld Min. mit dem Auto je Strecke")
add("~%lld min transit each way", "~%lld min transit each way", "~%lld min en transporte por trayecto", "~%lld min en transports dans chaque sens", "~%lld Min. mit Bahn/Bus je Strecke")
add("~%lld min walk each way", "~%lld min walk each way", "~%lld min a pie por trayecto", "~%lld min à pied dans chaque sens", "~%lld Min. zu Fuß je Strecke")
add("~%lld min drive there · ~%lld min back", "~%lld min drive there · ~%lld min back", "~%lld min en coche · ~%lld min de vuelta", "~%lld min en voiture · ~%lld min retour", "~%lld Min. mit dem Auto · ~%lld Min. zurück")
add("~%lld min transit there · ~%lld min back", "~%lld min transit there · ~%lld min back", "~%lld min en transporte · ~%lld min de vuelta", "~%lld min en transports · ~%lld min retour", "~%lld Min. mit Bahn/Bus · ~%lld Min. zurück")
add("~%lld min walk there · ~%lld min back", "~%lld min walk there · ~%lld min back", "~%lld min a pie · ~%lld min de vuelta", "~%lld min à pied · ~%lld min retour", "~%lld Min. zu Fuß · ~%lld Min. zurück")

add("Asking Apple Maps for drive time…", "Asking Apple Maps for drive time…", "Consultando Apple Maps para el tiempo en coche…", "Demande du temps de trajet en voiture à Plans…", "Apple Karten fragt die Autofahrtzeit ab…")
add("Asking Apple Maps for transit time…", "Asking Apple Maps for transit time…", "Consultando Apple Maps para el tiempo en transporte…", "Demande du temps en transports à Plans…", "Apple Karten fragt die ÖPNV-Zeit ab…")
add("Set a home address in Settings to estimate drive time", "Set a home address in Settings to estimate drive time", "Añade una dirección de casa en Ajustes para estimar el trayecto", "Indiquez une adresse chez vous dans Réglages pour estimer le trajet", "Legen Sie in den Einstellungen eine Heimatadresse fest, um die Fahrzeit zu schätzen")
add("Couldn't pin this place, so no drive time", "Couldn't pin this place, so no drive time", "No se pudo localizar este sitio, así que no hay tiempo de trayecto", "Impossible de localiser ce lieu, donc pas de temps de trajet", "Dieser Ort ließ sich nicht finden, daher keine Fahrzeit")
add("Apple Maps could not get a drive time.", "Apple Maps could not get a drive time.", "Apple Maps no pudo obtener un tiempo en coche.", "Plans n’a pas pu obtenir un temps de trajet en voiture.", "Apple Karten konnte keine Autofahrtzeit ermitteln.")
add("No transit route", "No transit route", "Sin ruta de transporte", "Pas d’itinéraire en transports", "Keine ÖPNV-Verbindung")
add("couldn't get a drive back", "couldn't get a drive back", "no hay tiempo de vuelta en coche", "impossible d’obtenir le retour en voiture", "Rückfahrt mit dem Auto nicht ermittelt")
add("couldn't get a transit back", "couldn't get a transit back", "no hay tiempo de vuelta en transporte", "impossible d’obtenir le retour en transports", "Rückfahrt mit ÖPNV nicht ermittelt")
add("from Home", "from Home", "desde casa", "depuis chez vous", "von zu Hause")
add("from current location", "from current location", "desde la ubicación actual", "depuis la position actuelle", "vom aktuellen Standort")
add("No transit route here, so this is drive time", "No transit route here, so this is drive time", "Aquí no hay transporte, así que es tiempo en coche", "Pas de transports ici, donc c’est le temps en voiture", "Hier gibt es keinen ÖPNV, das ist Autofahrtzeit")
add("leave-by includes your %lld min leaving-home buffer", "leave-by includes your %lld min leaving-home buffer", "la hora de salida incluye tus %lld min extra para salir de casa", "l’heure de départ inclut vos %lld min pour sortir de chez vous", "Loszeit inkl. Ihrer %lld Min. Puffer zum Losfahren")
add("Appointment %@", "Appointment %@", "Cita %@", "Rendez-vous %@", "Termin %@", "Today row caption under leave-by.")
add("All day", "All day", "Todo el día", "Toute la journée", "Ganztägig")

# --- Capture / modes ---
add("Voice", "Voice", "Voz", "Voix", "Sprache")
add("Photo", "Photo", "Foto", "Photo", "Foto")
add("Type mode", "Type", "Escribir", "Saisie", "Tippen", "Capture mode for typing an appointment.")
add("Drive", "Drive", "Coche", "Voiture", "Auto")
add("Transit", "Transit", "Transporte", "Transports", "ÖPNV")
add("Walk", "Walk", "A pie", "À pied", "Zu Fuß")
add("Hi", "Hi", "Hola", "Salut", "Hi")
add("Hi, %@", "Hi, %@", "Hola, %@", "Salut, %@", "Hi, %@")
add("Hi, %@. Settings", "Hi, %@. Settings", "Hola, %@. Ajustes", "Salut, %@. Réglages", "Hi, %@. Einstellungen")
add("Scedra", "Scedra", "Scedra", "Scedra", "Scedra")
add("Saved to Calendar", "Saved to Calendar", "Guardado en Calendario", "Enregistré dans Calendrier", "Im Kalender gespeichert")
add("Listening… speak the appointment", "Listening… speak the appointment", "Escuchando… di la cita", "Écoute… dictez le rendez-vous", "Hört zu… sagen Sie den Termin")
add("Listening… tap Stop when you’re done", "Listening… tap Stop when you’re done", "Escuchando… toca Detener cuando termines", "Écoute… touchez Arrêter quand vous avez fini", "Hört zu… tippen Sie auf Stopp, wenn Sie fertig sind")
add("Spoken text appears here — or type if listening fails", "Spoken text appears here — or type if listening fails", "El texto hablado aparece aquí — o escribe si falla la escucha", "Le texte dicté apparaît ici — ou tapez si l’écoute échoue", "Gesprochener Text erscheint hier — oder tippen, wenn das Zuhören scheitert")
add("Photo text appears here — type if nothing is found", "Photo text appears here — type if nothing is found", "El texto de la foto aparece aquí — escribe si no se encuentra nada", "Le texte de la photo apparaît ici — tapez si rien n’est trouvé", "Fototext erscheint hier — tippen, wenn nichts gefunden wird")
add("dentist tomorrow at 2 at Stanford", "dentist tomorrow at 2 at Stanford", "dentista mañana a las 2 en Stanford", "dentiste demain à 14 h à Stanford", "Zahnarzt morgen um 14 Uhr in Stanford")
add("Reading text…", "Reading text…", "Leyendo el texto…", "Lecture du texte…", "Text wird gelesen…")
add("Tap an appointment for details. Tap the trash to delete.", "Tap an appointment for details. Tap the trash to delete.", "Toca una cita para ver detalles. Toca la papelera para borrar.", "Touchez un rendez-vous pour les détails. Touchez la corbeille pour supprimer.", "Tippen Sie auf einen Termin für Details. Tippen Sie auf den Papierkorb zum Löschen.")
add("Checking Calendar access…", "Checking Calendar access…", "Comprobando el acceso a Calendario…", "Vérification de l’accès à Calendrier…", "Kalenderzugriff wird geprüft…")
add("Calendar access is off. Enable it in Settings to see today’s events.", "Calendar access is off. Enable it in Settings to see today’s events.", "El acceso a Calendario está desactivado. Actívalo en Ajustes para ver los eventos de hoy.", "L’accès à Calendrier est désactivé. Activez-le dans Réglages pour voir les événements d’aujourd’hui.", "Der Kalenderzugriff ist aus. Aktivieren Sie ihn in den Einstellungen, um die heutigen Termine zu sehen.")
add("Nothing on Today yet. Confirmed events still save to the Calendar app. Grant full Calendar access to list other events.", "Nothing on Today yet. Confirmed events still save to the Calendar app. Grant full Calendar access to list other events.", "Aún no hay nada en Hoy. Las citas confirmadas se guardan en la app Calendario. Concede acceso completo para listar otros eventos.", "Rien aujourd’hui pour l’instant. Les rendez-vous confirmés s’enregistrent quand même dans Calendrier. Accordez l’accès complet pour lister les autres événements.", "Heute ist noch nichts da. Bestätigte Termine werden trotzdem in der Kalender-App gespeichert. Gewähren Sie vollen Zugriff, um andere Termine zu sehen.")
add("Nothing on the calendar for today.", "Nothing on the calendar for today.", "Nada en el calendario para hoy.", "Rien sur le calendrier aujourd’hui.", "Heute steht nichts im Kalender.")
add("Listen or type an appointment first.", "Listen or type an appointment first.", "Escucha o escribe una cita primero.", "Écoutez ou tapez d’abord un rendez-vous.", "Hören oder tippen Sie zuerst einen Termin.")
add("Pick a photo or type the appointment.", "Pick a photo or type the appointment.", "Elige una foto o escribe la cita.", "Choisissez une photo ou tapez le rendez-vous.", "Wählen Sie ein Foto oder tippen Sie den Termin.")
add("Type an appointment first.", "Type an appointment first.", "Escribe primero una cita.", "Tapez d’abord un rendez-vous.", "Tippen Sie zuerst einen Termin.")
add("Couldn’t read an appointment from that text.", "Couldn’t read an appointment from that text.", "No se pudo leer una cita en ese texto.", "Impossible de lire un rendez-vous dans ce texte.", "Aus diesem Text ließ sich kein Termin lesen.")

# --- Calendar tab / details ---
add("Synced from Apple Calendar", "Synced from Apple Calendar", "Sincronizado desde Calendario de Apple", "Synchronisé depuis Calendrier Apple", "Aus dem Apple-Kalender synchronisiert")
add("Previous day", "Previous day", "Día anterior", "Jour précédent", "Vorheriger Tag")
add("Next day", "Next day", "Día siguiente", "Jour suivant", "Nächster Tag")
add("Calendar access is off. Enable it in Settings to see your events.", "Calendar access is off. Enable it in Settings to see your events.", "El acceso a Calendario está desactivado. Actívalo en Ajustes para ver tus eventos.", "L’accès à Calendrier est désactivé. Activez-le dans Réglages pour voir vos événements.", "Der Kalenderzugriff ist aus. Aktivieren Sie ihn in den Einstellungen, um Ihre Termine zu sehen.")
add("Grant full Calendar access to list events. Confirmed appointments still save.", "Grant full Calendar access to list events. Confirmed appointments still save.", "Concede acceso completo a Calendario para listar eventos. Las citas confirmadas se siguen guardando.", "Accordez l’accès complet à Calendrier pour lister les événements. Les rendez-vous confirmés s’enregistrent quand même.", "Gewähren Sie vollen Kalenderzugriff, um Termine zu listen. Bestätigte Termine werden trotzdem gespeichert.")
add("Appointment", "Appointment", "Cita", "Rendez-vous", "Termin")
add("Place", "Place", "Lugar", "Lieu", "Ort")
add("Delete from Calendar", "Delete from Calendar", "Eliminar del Calendario", "Supprimer du Calendrier", "Aus dem Kalender löschen")
add("Delete this appointment?", "Delete this appointment?", "¿Eliminar esta cita?", "Supprimer ce rendez-vous ?", "Diesen Termin löschen?")
add("This removes “%@” from Apple Calendar, not just Scedra.", "This removes “%@” from Apple Calendar, not just Scedra.", "Esto quita “%@” de Calendario de Apple, no solo de Scedra.", "Cela retire « %@ » de Calendrier Apple, pas seulement de Scedra.", "Das entfernt „%@“ aus dem Apple-Kalender, nicht nur aus Scedra.")
add("This removes the appointment from Apple Calendar, not just Scedra.", "This removes the appointment from Apple Calendar, not just Scedra.", "Esto quita la cita de Calendario de Apple, no solo de Scedra.", "Cela retire le rendez-vous de Calendrier Apple, pas seulement de Scedra.", "Das entfernt den Termin aus dem Apple-Kalender, nicht nur aus Scedra.")
add("Delete %@", "Delete %@", "Eliminar %@", "Supprimer %@", "%@ löschen")
add("Original", "Original", "Original", "Original", "Original")
add("Original photo", "Original photo", "Foto original", "Photo originale", "Originalfoto")
add("No transit time was saved with this appointment.", "No transit time was saved with this appointment.", "No se guardó un tiempo de transporte con esta cita.", "Aucun temps en transports n’a été enregistré avec ce rendez-vous.", "Mit diesem Termin wurde keine ÖPNV-Zeit gespeichert.")
add("No drive time was saved with this appointment.", "No drive time was saved with this appointment.", "No se guardó un tiempo en coche con esta cita.", "Aucun temps de trajet en voiture n’a été enregistré avec ce rendez-vous.", "Mit diesem Termin wurde keine Autofahrtzeit gespeichert.")
add("Conflict", "Conflict", "Conflicto", "Conflit", "Konflikt", "Home-gap eyebrow and travel-time conflict headline.")
add("%@, all day", "%@, all day", "%@, todo el día", "%@, toute la journée", "%@, ganztägig")
add("View details", "View details", "Ver detalles", "Voir les détails", "Details anzeigen")
add("Nothing on the calendar for this day.", "Nothing on the calendar for this day.", "Nada en el calendario para este día.", "Rien sur le calendrier pour ce jour.", "An diesem Tag steht nichts im Kalender.")
add("Swipe left or right for another day.", "Swipe left or right for another day.", "Desliza a izquierda o derecha para otro día.", "Balayez à gauche ou à droite pour un autre jour.", "Wischen Sie nach links oder rechts für einen anderen Tag.")
add("Jump to today", "Jump to today", "Ir a hoy", "Aller à aujourd’hui", "Zu heute springen")
add("Current time", "Current time", "Hora actual", "Heure actuelle", "Aktuelle Uhrzeit")
add("Tap to view appointment details.", "Tap to view appointment details.", "Toca para ver los detalles de la cita.", "Touchez pour voir les détails du rendez-vous.", "Tippen, um Termindetails zu sehen.")

# --- Review ---
add("%lld of %lld", "%1$lld of %2$lld", "%1$lld de %2$lld", "%1$lld sur %2$lld", "%1$lld von %2$lld")
add("Title", "Title", "Título", "Titre", "Titel")
add("Date", "Date", "Fecha", "Date", "Datum")
add("Start", "Start", "Inicio", "Début", "Beginn")
add("End", "End", "Fin", "Fin", "Ende")
add("2:30 PM", "2:30 PM", "2:30 p. m.", "14:30", "14:30")
add("3:30 PM", "3:30 PM", "3:30 p. m.", "15:30", "15:30")
add("Duration assumed", "Duration assumed", "Duración supuesta", "Durée supposée", "Dauer angenommen")
add("Scedra filled the date and time from now — change them if that’s not right.", "Scedra filled the date and time from now — change them if that’s not right.", "Scedra rellenó la fecha y la hora a partir de ahora — cámbialas si no es así.", "Scedra a rempli la date et l’heure à partir de maintenant — changez-les si ce n’est pas ça.", "Scedra hat Datum und Uhrzeit ab jetzt ausgefüllt — ändern Sie sie, wenn das nicht stimmt.")
add("Location", "Location", "Lugar", "Lieu", "Ort")
add("Location (optional)", "Location (optional)", "Lugar (opcional)", "Lieu (facultatif)", "Ort (optional)")
add("Extra time", "Extra time", "Tiempo extra", "Temps en plus", "Zusatzzeit")
add("Before", "Before", "Antes", "Avant", "Davor")
add("After", "After", "Después", "Après", "Danach")
add("min", "min", "min", "min", "Min.")
add("%lld min", "%lld min", "%lld min", "%lld min", "%lld Min.")
add("0 min", "0 min", "0 min", "0 min", "0 Min.")
add("1 hr", "1 hr", "1 h", "1 h", "1 Std.")
add("%lld hr", "%lld hr", "%lld h", "%lld h", "%lld Std.")
add("%lld hr %lld min", "%1$lld hr %2$lld min", "%1$lld h %2$lld min", "%1$lld h %2$lld min", "%1$lld Std. %2$lld Min.")
add("CONFLICT", "CONFLICT", "CONFLICTO", "CONFLIT", "KONFLIKT")
add("Grant full Calendar access in Settings to check overlaps. Scedra will not move existing events.", "Grant full Calendar access in Settings to check overlaps. Scedra will not move existing events.", "Concede acceso completo a Calendario en Ajustes para comprobar solapes. Scedra no moverá eventos existentes.", "Accordez l’accès complet à Calendrier dans Réglages pour vérifier les chevauchements. Scedra ne déplacera pas les événements existants.", "Gewähren Sie in den Einstellungen vollen Kalenderzugriff, um Überschneidungen zu prüfen. Scedra verschiebt bestehende Termine nicht.")
add("Overlaps %@", "Overlaps %@", "Se solapa con %@", "Chevauche %@", "Überschneidet sich mit %@")
add("Checked with the drive included. Your appointment itself is %@.", "Checked with the drive included. Your appointment itself is %@.", "Comprobado con el trayecto incluido. La cita en sí es %@.", "Vérifié avec le trajet compris. Le rendez-vous lui-même est %@.", "Mit Fahrt geprüft. Der Termin selbst ist %@.")
add("Scedra won’t move that event. Confirm still saves this one.", "Scedra won’t move that event. Confirm still saves this one.", "Scedra no moverá ese evento. Confirmar guarda este de todos modos.", "Scedra ne déplacera pas cet événement. Confirmer enregistre quand même celui-ci.", "Scedra verschiebt diesen Termin nicht. Bestätigen speichert diesen trotzdem.")
add("Finding a nearby place…", "Finding a nearby place…", "Buscando un sitio cercano…", "Recherche d’un lieu à proximité…", "Suche einen Ort in der Nähe…")
add("Finding a place in that area…", "Finding a place in that area…", "Buscando un sitio en esa zona…", "Recherche d’un lieu dans ce secteur…", "Suche einen Ort in diesem Gebiet…")
add("Closest nearby match", "Closest nearby match", "Coincidencia más cercana", "Correspondance la plus proche", "Nächste Übereinstimmung")
add("Remembered from last time", "Remembered from last time", "Recordado de la última vez", "Souvenu de la dernière fois", "Von letztem Mal gemerkt")
add("Closest to %@", "Closest to %@", "Lo más cerca de %@", "Le plus près de %@", "Am nächsten bei %@")
add("Closest to your home address", "Closest to your home address", "Lo más cerca de tu casa", "Le plus près de chez vous", "Am nächsten zu Ihrer Heimatadresse")
add("Your saved %@ address", "Your saved %@ address", "Tu dirección guardada de %@", "Votre adresse enregistrée pour %@", "Ihre gespeicherte Adresse für %@")
add("Best match by name", "Best match by name", "Mejor coincidencia por nombre", "Meilleure correspondance par le nom", "Beste Namensübereinstimmung")
add("%@ time", "%@ time", "Hora de %@", "Heure %@ ", "Uhrzeit %@")
add("Extra time %@", "Extra time %@", "Tiempo extra %@", "Temps en plus %@", "Zusatzzeit %@")
add("Read text", "Read text", "Leer el texto", "Lire le texte", "Text lesen")
add("at %@", "at %@", "a las %@", "à %@", "um %@")
add("for %@", "for %@", "durante %@", "pendant %@", "für %@")
add("arrive %@ early", "arrive %@ early", "llegar %@ antes", "arriver %@ en avance", "%@ früher ankommen")
add("stay %@ after", "stay %@ after", "quedarse %@ después", "rester %@ après", "%@ länger bleiben")

# --- Settings ---
add("Mini profile", "Mini profile", "Mini perfil", "Mini profil", "Mini-Profil")
add("Your name", "Your name", "Tu nombre", "Votre prénom", "Ihr Name")
add("Used for the home greeting. Leave blank for just “Hi”.", "Used for the home greeting. Leave blank for just “Hi”.", "Se usa para el saludo. Déjalo en blanco para solo “Hola”.", "Sert au salut d’accueil. Laissez vide pour juste « Salut ».", "Für die Begrüßung. Leer lassen für nur „Hi“.")
add("How I move", "How I move", "Cómo me muevo", "Comment je me déplace", "Wie ich unterwegs bin")
add("Travel", "Travel", "Viaje", "Trajet", "Reise")
add("I’ll walk up to", "I’ll walk up to", "Caminaré hasta", "Je marche jusqu’à", "Ich gehe zu Fuß bis")
add("Walk distance is only a mention on the card. Scedra never silently moves events.", "Walk distance is only a mention on the card. Scedra never silently moves events.", "La distancia a pie solo se menciona en la tarjeta. Scedra nunca mueve eventos en silencio.", "La distance à pied n’est qu’une mention sur la carte. Scedra ne déplace jamais les événements en silence.", "Die Gehweite ist nur ein Hinweis auf der Karte. Scedra verschiebt Termine nie still.")
add("Between stops", "Between stops", "Entre paradas", "Entre les arrêts", "Zwischen Stopps")
add("Leaving home", "Leaving home", "Salir de casa", "Sortir de chez moi", "Losfahren von zu Hause")
add("%lld min extra", "%lld min extra", "%lld min extra", "%lld min en plus", "%lld Min. extra")
add("Extra minutes to get out the door after a stop at home.", "Extra minutes to get out the door after a stop at home.", "Minutos extra para salir de casa después de una parada.", "Minutes en plus pour sortir après une pause à la maison.", "Extra-Minuten, um nach einem Stopp zu Hause wieder rauszukommen.")
add("If I only have", "If I only have", "Si solo tengo", "Si je n’ai que", "Wenn ich nur")
add("%lld min at home", "%lld min at home", "%lld min en casa", "%lld min à la maison", "%lld Min. zu Hause")
add(
    "Don’t bother going home — stay out and let me work. If the leftover time at home would be shorter than this (after the drives, leaving-home extra, and Before), treat it as stay-out.",
    "Don’t bother going home — stay out and let me work. If the leftover time at home would be shorter than this (after the drives, leaving-home extra, and Before), treat it as stay-out.",
    "No mereces volver a casa — quédate fuera y trabaja. Si el tiempo en casa sería más corto que esto (después de los trayectos, el extra para salir y Antes), trátalo como quedarse fuera.",
    "Ne rentrez pas — restez dehors et travaillez. Si le temps à la maison serait plus court que ça (après les trajets, le temps pour sortir et Avant), traitez-le comme rester dehors.",
    "Nicht nach Hause fahren — draußen bleiben und weiterarbeiten. Wenn die Zeit zu Hause kürzer wäre als das (nach den Fahrten, dem Losfahr-Puffer und Davor), als Draußen-bleiben behandeln.",
)
add("Remind me to bring", "Remind me to bring", "Recuérdame llevar", "Rappelle-moi d’apporter", "Erinnere mich mitzunehmen")
add("charger, helmet…", "charger, helmet…", "cargador, casco…", "chargeur, casque…", "Ladegerät, Helm…")
add("One item per line, or commas. Always added when you should stay out or take transit. On a go-home day, only these standing items are mentioned.", "One item per line, or commas. Always added when you should stay out or take transit. On a go-home day, only these standing items are mentioned.", "Un objeto por línea, o comas. Siempre se añade si debes quedarte fuera o ir en transporte. Un día de volver a casa, solo se mencionan estos objetos fijos.", "Un objet par ligne, ou des virgules. Toujours ajouté quand vous devez rester dehors ou prendre les transports. Un jour où vous rentrez, seuls ces objets habituels sont mentionnés.", "Ein Eintrag pro Zeile oder Kommas. Immer dabei, wenn Sie draußen bleiben oder den ÖPNV nehmen sollen. An einem Heimfahrt-Tag werden nur diese festen Dinge genannt.")
add("Home address", "Home address", "Dirección de casa", "Adresse chez vous", "Heimatadresse")
add("123 Main Street", "123 Main Street", "Calle Mayor 123", "123 rue Principale", "Hauptstraße 123")
add("Drive times on Review start from this address.", "Drive times on Review start from this address.", "Los tiempos en coche en Revisar salen de esta dirección.", "Les temps de trajet sur Vérifier partent de cette adresse.", "Fahrzeiten unter Prüfen starten von dieser Adresse.")
add("More details", "More details", "Más detalles", "Plus de détails", "Weitere Angaben")
add("Extra addresses (work, school, a second house) and anything else Scedra should remember. Saying “work” uses the address you save here.", "Extra addresses (work, school, a second house) and anything else Scedra should remember. Saying “work” uses the address you save here.", "Direcciones extra (trabajo, colegio, otra casa) y cualquier otra cosa que Scedra deba recordar. Decir “trabajo” usa la dirección que guardas aquí.", "Adresses en plus (travail, école, une autre maison) et tout ce que Scedra doit retenir. Dire « travail » utilise l’adresse enregistrée ici.", "Weitere Adressen (Arbeit, Schule, ein zweites Haus) und alles, was Scedra merken soll. „Arbeit“ nutzt die Adresse, die Sie hier speichern.")
add("Notes — hours, parking, whatever helps", "Notes — hours, parking, whatever helps", "Notas — horarios, parking, lo que ayude", "Notes — horaires, parking, ce qui aide", "Notizen — Öffnungszeiten, Parken, was hilft")
add("Work, school…", "Work, school…", "Trabajo, colegio…", "Travail, école…", "Arbeit, Schule…")
add("Address", "Address", "Dirección", "Adresse", "Adresse")
add("Remove this address", "Remove this address", "Quitar esta dirección", "Retirer cette adresse", "Diese Adresse entfernen")
add("Add an address", "Add an address", "Añadir una dirección", "Ajouter une adresse", "Adresse hinzufügen")
add("Lavender", "Lavender", "Lavanda", "Lavande", "Lavendel")
add("Blush", "Blush", "Rubor", "Blush", "Rouge")
add("Sage", "Sage", "Salvia", "Sauge", "Salbei")
add("Midnight", "Midnight", "Medianoche", "Minuit", "Mitternacht")

# --- Home gap ---
add("What to bring", "What to bring", "Qué llevar", "Quoi apporter", "Was mitnehmen")
add("A reminder — change it in your head if that’s not right.", "A reminder — change it in your head if that’s not right.", "Un recordatorio — cámbialo mentalmente si no es así.", "Un rappel — changez-le dans votre tête si ce n’est pas ça.", "Eine Erinnerung — ändern Sie sie im Kopf, wenn das nicht stimmt.")
add("Scedra won’t move what’s already on the calendar.", "Scedra won’t move what’s already on the calendar.", "Scedra no moverá lo que ya está en el calendario.", "Scedra ne déplacera pas ce qui est déjà sur le calendrier.", "Scedra verschiebt nicht, was schon im Kalender steht.")
add("How you’ll get there", "How you’ll get there", "Cómo llegarás", "Comment vous y rendre", "Wie Sie hinkommen")
add("Checking whether you can go home…", "Checking whether you can go home…", "Comprobando si puedes ir a casa…", "Vérification si vous pouvez rentrer…", "Prüfe, ob Sie nach Hause können…")
add("Navigate with %@", "Navigate with %@", "Navegar con %@", "Itinéraire avec %@", "Route mit %@")
add("These overlap", "These overlap", "Se solapan", "Ils se chevauchent", "Diese überschneiden sich", "Home-gap headline when two appointments overlap.")
add("Take transit to %@", "Take transit to %@", "Ve en transporte a %@", "Prenez les transports pour %@", "Nehmen Sie den ÖPNV zu %@")
add("You can go home", "You can go home", "Puedes ir a casa", "Vous pouvez rentrer", "Sie können nach Hause")
add("You can go home on transit", "You can go home on transit", "Puedes ir a casa en transporte", "Vous pouvez rentrer en transports", "Sie können mit ÖPNV nach Hause")
add("Don’t go home — go to %@", "Don’t go home — go to %@", "No vayas a casa — ve a %@", "Ne rentrez pas — allez à %@", "Nicht nach Hause — weiter zu %@")
add("no time", "no time", "sin tiempo", "pas le temps", "keine Zeit")
add("only %lld min", "only %lld min", "solo %lld min", "seulement %lld min", "nur %lld Min.")
add(
    "Driving is ~%lld min and won’t make it. Transit is ~%lld min at the time you’d actually leave, and that fits.",
    "Driving is ~%lld min and won’t make it. Transit is ~%lld min at the time you’d actually leave, and that fits.",
    "En coche son ~%lld min y no llegas. El transporte son ~%lld min a la hora a la que saldrías, y eso cabe.",
    "En voiture c’est ~%lld min et ça ne passe pas. Les transports sont ~%lld min à l’heure où vous partiriez vraiment, et ça passe.",
    "Mit dem Auto sind es ~%lld Min. und das reicht nicht. ÖPNV ist ~%lld Min. zur tatsächlichen Abfahrt, und das passt.",
)
add(
    "You can’t get from %@ to %@ in time — ~%lld min drive, %@ between them.",
    "You can’t get from %@ to %@ in time — ~%lld min drive, %@ between them.",
    "No llegas de %@ a %@ a tiempo — ~%lld min en coche, %@ entre ellos.",
    "Vous ne pouvez pas aller de %@ à %@ à temps — ~%lld min en voiture, %@ entre les deux.",
    "Sie kommen nicht rechtzeitig von %@ nach %@ — ~%lld Min. Fahrt, %@ dazwischen.",
)
add(
    "~%lld min home, then ~%lld min to %@. Leave home by %@. About %lld min at home.",
    "~%lld min home, then ~%lld min to %@. Leave home by %@. About %lld min at home.",
    "~%lld min a casa, luego ~%lld min a %@. Sal de casa a las %@. Unos %lld min en casa.",
    "~%lld min pour rentrer, puis ~%lld min vers %@. Partez de chez vous à %@. Environ %lld min à la maison.",
    "~%lld Min. nach Hause, dann ~%lld Min. zu %@. Zu Hause los um %@. Etwa %lld Min. zu Hause.",
)
add(
    "Driving home and out again is ~%lld min and won’t fit. Transit is ~%lld min home, then ~%lld min to %@.",
    "Driving home and out again is ~%lld min and won’t fit. Transit is ~%lld min home, then ~%lld min to %@.",
    "Ir a casa y salir otra vez son ~%lld min y no cabe. El transporte son ~%lld min a casa, luego ~%lld min a %@.",
    "Rentrer puis ressortir en voiture c’est ~%lld min et ça ne passe pas. Les transports sont ~%lld min pour rentrer, puis ~%lld min vers %@.",
    "Hin und wieder raus mit dem Auto sind ~%lld Min. und passen nicht. ÖPNV ist ~%lld Min. nach Hause, dann ~%lld Min. zu %@.",
)
add(
    "You’d only have %lld min at home — not enough to bother (you asked for at least %lld min).",
    "You’d only have %lld min at home — not enough to bother (you asked for at least %lld min).",
    "Solo tendrías %lld min en casa — no merece la pena (pediste al menos %lld min).",
    "Vous n’auriez que %lld min à la maison — ça ne vaut pas le coup (vous avez demandé au moins %lld min).",
    "Sie hätten nur %lld Min. zu Hause — zu wenig (Sie wollten mindestens %lld Min.).",
)
add(
    "Stay at %@ until you need to leave — only about %lld min to spare.",
    "Stay at %@ until you need to leave — only about %lld min to spare.",
    "Quédate en %@ hasta que tengas que salir — solo unos %lld min de margen.",
    "Restez à %@ jusqu’au moment de partir — seulement environ %lld min de marge.",
    "Bleiben Sie bei %@, bis Sie losmüssen — nur etwa %lld Min. übrig.",
)
add(
    "Head toward %@ when you finish — about %lld min to spare.",
    "Head toward %@ when you finish — about %lld min to spare.",
    "Dirígete a %@ cuando termines — unos %lld min de margen.",
    "Dirigez-vous vers %@ en finissant — environ %lld min de marge.",
    "Gehen Sie nach %@ wenn Sie fertig sind — etwa %lld Min. übrig.",
)
add("~%lld min drive from %@. %@", "~%lld min drive from %@. %@", "~%lld min en coche desde %@. %@", "~%lld min en voiture depuis %@. %@", "~%lld Min. Fahrt von %@. %@")
add("That’s also within your %lld min walk if you’d rather not drive.", "That’s also within your %lld min walk if you’d rather not drive.", "Eso también entra en tus %lld min a pie si prefieres no coger el coche.", "C’est aussi dans vos %lld min à pied si vous préférez ne pas conduire.", "Das liegt auch in Ihrer %lld-Min.-Gehweite, wenn Sie nicht fahren möchten.")
add("You prefer transit (~%lld min). Driving is ~%lld min.", "You prefer transit (~%lld min). Driving is ~%lld min.", "Prefieres transporte (~%lld min). En coche son ~%lld min.", "Vous préférez les transports (~%lld min). En voiture c’est ~%lld min.", "Sie bevorzugen ÖPNV (~%lld Min.). Mit dem Auto sind es ~%lld Min.")
add("You prefer transit — about %lld min at the time you’d leave.", "You prefer transit — about %lld min at the time you’d leave.", "Prefieres transporte — unos %lld min a la hora a la que saldrías.", "Vous préférez les transports — environ %lld min à l’heure où vous partiriez.", "Sie bevorzugen ÖPNV — etwa %lld Min. zur Abfahrt.")
add("Transit is ~%lld min at the time you’d leave.", "Transit is ~%lld min at the time you’d leave.", "El transporte son ~%lld min a la hora a la que saldrías.", "Les transports sont ~%lld min à l’heure où vous partiriez.", "ÖPNV ist ~%lld Min. zur Abfahrt.")
add("Transit is ~%lld min — quicker than the ~%lld min drive, at the time you’d leave.", "Transit is ~%lld min — quicker than the ~%lld min drive, at the time you’d leave.", "El transporte son ~%lld min — más rápido que los ~%lld min en coche, a la hora a la que saldrías.", "Les transports sont ~%lld min — plus rapides que les ~%lld min en voiture, à l’heure où vous partiriez.", "ÖPNV ist ~%lld Min. — schneller als die ~%lld Min. Autofahrt, zur Abfahrt.")
add("Transit is ~%lld min (vs ~%lld min drive) at the time you’d leave.", "Transit is ~%lld min (vs ~%lld min drive) at the time you’d leave.", "El transporte son ~%lld min (frente a ~%lld min en coche) a la hora a la que saldrías.", "Les transports sont ~%lld min (contre ~%lld min en voiture) à l’heure où vous partiriez.", "ÖPNV ist ~%lld Min. (vs. ~%lld Min. Auto) zur Abfahrt.")
add("Transit is about the same, ~%lld min.", "Transit is about the same, ~%lld min.", "El transporte es parecido, ~%lld min.", "Les transports sont à peu près pareil, ~%lld min.", "ÖPNV ist etwa gleich, ~%lld Min.")
add("Transit home and out again is ~%lld min.", "Transit home and out again is ~%lld min.", "Transporte a casa y otra vez fuera son ~%lld min.", "Transports pour rentrer puis ressortir : ~%lld min.", "ÖPNV nach Hause und wieder raus ist ~%lld Min.")
add("Home", "Home", "Casa", "Maison", "Zuhause")
add("Bring: %@", "Bring: %@", "Llevar: %@", "Apporter : %@", "Mitnehmen: %@")
add("Riding stuff — helmet, boots, anything you keep at home", "Riding stuff — helmet, boots, anything you keep at home", "Cosas de montar — casco, botas, lo que dejas en casa", "Affaires d’équitation — casque, bottes, ce que vous gardez à la maison", "Reitsachen — Helm, Stiefel, was zu Hause liegt")
add("Whatever you need for the dentist (insurance card, referral if they asked)", "Whatever you need for the dentist (insurance card, referral if they asked)", "Lo que necesites para el dentista (tarjeta, derivación si la pidieron)", "Ce qu’il faut pour le dentiste (carte, ordonnance s’ils l’ont demandée)", "Was Sie beim Zahnarzt brauchen (Versicherungskarte, Überweisung falls nötig)")
add("Whatever you need for the appointment (ID, insurance card)", "Whatever you need for the appointment (ID, insurance card)", "Lo que necesites para la cita (DNI, tarjeta)", "Ce qu’il faut pour le rendez-vous (pièce d’identité, carte)", "Was Sie für den Termin brauchen (Ausweis, Versicherungskarte)")
add("School things — laptop, charger, anything for %@", "School things — laptop, charger, anything for %@", "Cosas del cole — portátil, cargador, lo de %@", "Affaires d’école — ordinateur, chargeur, ce qu’il faut pour %@", "Schulsachen — Laptop, Ladegerät, alles für %@")
add("Work things — laptop, charger, anything you need for %@", "Work things — laptop, charger, anything you need for %@", "Cosas del trabajo — portátil, cargador, lo de %@", "Affaires de travail — ordinateur, chargeur, ce qu’il faut pour %@", "Arbeitssachen — Laptop, Ladegerät, alles für %@")
add("Gym bag / change of clothes", "Gym bag / change of clothes", "Bolsa de gym / muda", "Sac de sport / change", "Sporttasche / Wechselkleidung")
add("Anything you need for %@", "Anything you need for %@", "Lo que necesites para %@", "Ce qu’il vous faut pour %@", "Was Sie brauchen für %@")
add("the next stop", "the next stop", "la siguiente parada", "le prochain arrêt", "den nächsten Stopp")
add("%@ at %@", "%1$@ at %2$@", "%1$@ en %2$@", "%1$@ à %2$@", "%1$@ bei %2$@")

# --- Errors ---
add("Scedra needs Calendar access to save this appointment.", "Scedra needs Calendar access to save this appointment.", "Scedra necesita acceso a Calendario para guardar esta cita.", "Scedra a besoin de l’accès à Calendrier pour enregistrer ce rendez-vous.", "Scedra braucht Kalenderzugriff, um diesen Termin zu speichern.")
add("No default calendar is available on this device.", "No default calendar is available on this device.", "No hay un calendario predeterminado en este dispositivo.", "Aucun calendrier par défaut n’est disponible sur cet appareil.", "Auf diesem Gerät ist kein Standardkalender verfügbar.")
add("Calendar did not accept this appointment. Check Calendar access in Settings.", "Calendar did not accept this appointment. Check Calendar access in Settings.", "Calendario no aceptó esta cita. Revisa el acceso a Calendario en Ajustes.", "Calendrier n’a pas accepté ce rendez-vous. Vérifiez l’accès à Calendrier dans Réglages.", "Kalender hat diesen Termin nicht übernommen. Prüfen Sie den Kalenderzugriff in den Einstellungen.")
add("This needs a date and a time before it can be saved.", "This needs a date and a time before it can be saved.", "Hace falta una fecha y una hora para guardarlo.", "Il faut une date et une heure avant de pouvoir l’enregistrer.", "Dafür braucht es Datum und Uhrzeit, bevor es gespeichert werden kann.")
add("Scedra couldn’t open that photo. Pick another one, or type the appointment.", "Scedra couldn’t open that photo. Pick another one, or type the appointment.", "Scedra no pudo abrir esa foto. Elige otra, o escribe la cita.", "Scedra n’a pas pu ouvrir cette photo. Choisissez-en une autre, ou tapez le rendez-vous.", "Scedra konnte dieses Foto nicht öffnen. Wählen Sie ein anderes oder tippen Sie den Termin.")
add("Scedra couldn’t read that photo. Try a clearer screenshot, or type the appointment.", "Scedra couldn’t read that photo. Try a clearer screenshot, or type the appointment.", "Scedra no pudo leer esa foto. Prueba una captura más clara, o escribe la cita.", "Scedra n’a pas pu lire cette photo. Essayez une capture plus nette, ou tapez le rendez-vous.", "Scedra konnte dieses Foto nicht lesen. Versuchen Sie einen klareren Screenshot oder tippen Sie den Termin.")
add("No text found in that photo. Try a screenshot with the details visible, or type the appointment.", "No text found in that photo. Try a screenshot with the details visible, or type the appointment.", "No hay texto en esa foto. Prueba una captura con los detalles visibles, o escribe la cita.", "Aucun texte dans cette photo. Essayez une capture avec les détails visibles, ou tapez le rendez-vous.", "In diesem Foto steht kein Text. Versuchen Sie einen Screenshot mit sichtbaren Details oder tippen Sie den Termin.")

# --- Nearby / leave notifications ---
add("%@ is right at the place", "%@ is right at the place", "%@ está justo en el sitio", "%@ est juste sur place", "%@ ist direkt am Ort")
add("%@ is about a %lld-min walk", "%@ is about a %lld-min walk", "%@ está a unos %lld min a pie", "%@ est à environ %lld min à pied", "%@ ist etwa %lld Min. zu Fuß")
add("Nearest transit: %@ (%@)", "Nearest transit: %@ (%@)", "Transporte más cercano: %@ (%@)", "Transports les plus proches : %@ (%@)", "Nächster ÖPNV: %@ (%@)")
add("Time to leave for %@", "Time to leave for %@", "Hora de salir hacia %@", "C’est l’heure de partir pour %@", "Zeit loszufahren zu %@")
add("Leave now — open transit directions to %@.", "Leave now — open transit directions to %@.", "Sal ahora — abre el itinerario en transporte hacia %@.", "Partez maintenant — ouvrez l’itinéraire en transports vers %@.", "Jetzt losfahren — ÖPNV-Route zu %@ öffnen.")
add("Leave now — open Google Maps or Waze to %@.", "Leave now — open Google Maps or Waze to %@.", "Sal ahora — abre Google Maps o Waze hacia %@.", "Partez maintenant — ouvrez Google Maps ou Waze vers %@.", "Jetzt losfahren — Google Maps oder Waze zu %@ öffnen.")



def unit(value: str) -> dict:
    return {"stringUnit": {"state": "translated", "value": value}}


def main() -> None:
    strings = {}
    for key, (comment, en, es, fr, de) in STRINGS.items():
        entry: dict = {
            "extractionState": "manual",
            "localizations": {
                "en": unit(en),
                "es": unit(es),
                "fr": unit(fr),
                "de": unit(de),
            },
        }
        if comment:
            entry["comment"] = comment
        strings[key] = entry

    catalog = {
        "sourceLanguage": "en",
        "strings": dict(sorted(strings.items(), key=lambda item: item[0].casefold())),
        "version": "1.1",
    }
    dest = Path(__file__).resolve().parents[1] / "Scedra" / "Localizable.xcstrings"
    dest.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {len(strings)} keys to {dest}")


if __name__ == "__main__":
    main()
