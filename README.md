# Scedra

Speak it, snap it, or type it. Review the card. **Confirm** writes Apple Calendar.

Scedra is not a Calendar clone. Capture builds a draft; you check it; then it becomes a real EventKit event.

Optional one-liner: *Voice, photo, or type → review → Confirm. Tasks land in free time. Leave-by and conflict cards keep the day livable.*

## Capture

Three ways in: **Voice**, **Photo**, **Type**.

Each pass becomes a review card — title, time, place, extras. Edit anything. Confirm is the only write to Apple Calendar. A failed save leaves the draft alone.

Appointment titles stay as spoken, typed, or OCR’d. Buttons and chrome follow the phone language.

## Calendar day

Once events are on the calendar, Scedra helps the day actually work:

- **Travel / leave-by** — drive or transit time, plus a leaving-home buffer. The official appointment time stays; leave-by is when to go.
- **Don’t go home** — if a stop at home would be too short, or travel between two appointments does not fit, the card says stay out or go straight to the next place.
- **Conflict** — overlapping timed events show a conflict card. Touching endpoints are fine; overlapping windows are not.

Nothing here silently moves a calendar event.

## Tasks

A task is something to finish. Scedra parks it in free time and can write that slot to Apple Calendar.

- Prefer in-hours slots that finish by **8pm**.
- Keep a **buffer** (about 10 minutes, never under 5) next to exclusive blocks.
- **Exclusive** by default — class, meetings, focused work do not share the slot.
- **Allowed overlap** is a choice: a call can sit on driving, walking, waiting, or transit. Two tasks still never share a slot.

If the time is taken, nothing else is moved. Pick another time.

## Language

UI follows the **phone**: English, French, Spanish, German. No in-app language picker.

Titles and original wording stay as captured.

## Requirements

- macOS with **Xcode** (iOS 18.6 SDK / deployment target)
- iPhone or Simulator
- **Calendar** access (EventKit) to read the day and Confirm a write
- **Microphone** and speech recognition for Voice
- **Camera** / Photos for Photo
- **Location** for travel, leave-by, and Don’t-go-home cards

The app asks when a feature needs permission.

## Open and build

1. Open `Scedra.xcodeproj` in Xcode.
2. Choose an iPhone simulator or a signed device.
3. Run.

Do not commit secrets, `.env` files, signing certificates, or local Xcode user data.
