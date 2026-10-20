# Clinic On the Go — plan

A clinic app for small clinics and dispensaries, built on the **My DukaGO POS** foundation (copied, not shared):
offline-first on the phone, sync to its **own** Supabase project, staff PINs and roles, shifts, cash / M-Pesa,
receipts, reports, stock. The POS code it started from is build 101 (Oct 2026).

Served at `https://my-duka-go.github.io/clinic-on-the-go/` — the same web address as the POS, so everything
stored on the phone uses clinic-only names (database `clinic_otg_db_v1`, settings `clinic_otg_*`, offline cache
`clinic-otg-shell-*`, sync lock `clinic-otg-sync`). The two apps can be installed side by side on one phone.

## Stages
| # | What | Status |
|---|------|--------|
| 1 | Copy of the POS, renamed, separate storage, health photos and clinic wording throughout, **Clinic** business type (the only one) (consultation, lab, procedures, pharmacy Rx / OTC) as the default | done |
| 2 | **Patients** — register, search, patient file with visit history, consent, access log | done |
| 3 | **Visits & queue** — check-in (reason, payer, ticket no.) → vitals (out-of-range flagged) → doctor (history, exam, diagnosis, plan, orders, dosing) → bill at the desk → done; cancel with a reason; notes visible to doctors / administrators only. Until stage 6 the queue lives on one phone | done |
| 4 | **Billing & pharmacy** — patient and visit on the bill and receipt; **Insurance** payment (SHA / private) records a claim the insurer owes — never cash in the drawer — tracked on **Insurance Claims** (to submit → submitted → paid, or rejected → owed by the patient) with a printable claim summary; prescription-only medicines need a doctor's order (or a doctor at the desk, logged); **Dispensing** record; printed medicine labels | done |
| 5 | **Appointments** — book a registered patient or a new person (name + phone), with a doctor or any doctor; clash and double-booking warnings; day list (late / missed / cancelled); reminders by SMS or WhatsApp from the phone; check in as a visit (a new person registers first); coming appointments on the patient file; doctor books a follow-up from a visit | done |
| 5b | **Full hospital flow** (from the Hospitali Ndogo reference, without the ward) — **Patient tracker**: today's numbers and one tab per step: Triage → Doctor → Lab → Cashier → Pharmacy → Done, plus a timeline on every visit. Dangerous vitals make the patient **urgent** (front of the doctor queue); the doctor **sends to the lab**, results bring the patient **back to the doctor** ("Results back"); the prescription reaches the **pharmacy** as soon as the doctor finishes (prepare + allergy check), the patient pays at the cashier, then the pharmacy gives it out. **Allergy checks** by medicine class; **insurance cover %** with the patient's co-pay | done |
| 7 | **Hospital screens** (build 13, laid out like the Hospitali Ndogo reference, no ward) replace the shop till as the main screen: side menu (a strip on phones) **Front office** (Patient tracker, Reception, Appointments), **Clinical** (Triage, Consultation, Laboratory, Pharmacy), **Finance** (Cashier), **Administration** (Back office, Administrator only), each with its waiting count. Journey: reception (register / start visit, card fee on a first visit) → triage → doctor queue (urgent first, then "Results back") → **with the doctor** (called in: lab orders, services, prescription with dose, diagnosis, follow-up) → laboratory → back to the doctor → **pharmacy** (dispense with allergy and stock check, or "not given" with a reason; stock goes down here) → **cashier** (one invoice: card fee, consultation, services, tests done, medicines given; insurance share; cash / M-Pesa / claim) → completed. The till is only used for **over-the-counter sales** from the Pharmacy screen. Same records and sync as before | done |
| 6 | **Own Supabase project** (`hugaqzeqefzzpsvaanfm`) — the POS database copied from the live POS (tables, keys, row-level security, PIN scrambling with its own key, rate limits, licences, devices, hourly suspension) + clinic tables `patients`, `visits`, `appointments`, `dispensing` (whole record in `doc`, one clinic per row); sign-in functions `shop-auth`, `super-admin-login`, `platform-rest`, `pin-reset` deployed; the app sends and fetches clinic records, so reception, nurse, doctor and pharmacy can each use their own phone | done |

## Server (stage 6)
- Project `hugaqzeqefzzpsvaanfm` (eu-central-1). SQL kept in `supabase/clinic_schema.sql`, `clinic_functions.sql`,
  `clinic_tables_and_security.sql`; functions in `supabase/functions/`. The app uses the project's public (anon) key.
- A phone set up before the server existed (builds 1-8) only has its clinic on that phone; at sign-in it is offered
  "Start fresh" (clears only the clinic's data on the phone, never the POS's) so the clinic can be set up on the server.
- Two phones changing the same record: each field keeps the time it was last changed (`_f` in the record), the newer
  change of each field wins and visit/appointment timelines (`log`, `history`) keep entries from both (build 11).
- A phone moved to another clinic forgets everything of the old one (suppliers, profile, VAT, backup file) and restarts
  once after the first sign-in (build 11).
- Plans (build 12, app and server `plan_monthly_price`): small KSh 1,200 / month (2 phones), medium 1,500 (3),
  health centre 1,800 (5), 6+ devices 2,500; a year is 12 months less 10%.
- First setup is step by step (PIN, confirm, email, plan); a setup that stops part way opens on the same step next time
  (kept on the phone 24 hours, "Start over" clears it) (build 12).
- Setup email is required (build 16, POS build 106 too) - no skipping; it is how a forgotten Admin PIN is reset.
- Appointment reminders (build 16): staff can have a phone number (Back office → Staff); the Appointments screen sends
  a doctor today's list, or one booking, and the patient a reminder on WhatsApp (the message opens ready to send on the
  phone); a doctor is told about today's appointments after starting the shift, and Consultation lists them.
- Registration (build 17): every field is required (allergies / conditions accept "None"); phones are 10 digits starting
  07 or 01. The payment method comes first - Cash / M-Pesa, SHA (number, cover active, cover %) or private insurance
  (insurer, member no., cover active, cover %); cover not active is refused (register as cash). Under 18 (from the date
  of birth or age) asks for the parent / guardian's name, relationship and phone, and the patient's own phone is
  optional. The visit starts with the patient's payment method; at the cashier SHA uses the patient's cover % (no longer
  fixed at 100%) and the rest is paid by cash or M-Pesa ("Balance paid by").
- Platform Administrator is set. Still to set: Brevo email secrets (`BREVO_API_KEY`, `MAIL_FROM`) for "Forgot PIN?".

## Data (phone database now, Supabase tables in stage 6; every row has `clinic_id`)
- **patients**: id, clinic_id, patient_no (e.g. `P-00042`), full_name, sex, date_of_birth (or age), phone, national_id,
  sha_no (Social Health Authority), insurer + member_no, next_of_kin (name, phone), allergies, chronic_conditions,
  notes, created_by, created_at, updated_at.
- **visits**: id, clinic_id, patient_id, visit_no, status (`waiting` → `triage` → `with_doctor` → `billing` → `done`, or
  `cancelled`), checked_in_at, checked_in_by, reason (chief complaint), doctor_id, closed_at, sale_id (the till sale),
  payer (`cash` / `mpesa` / `insurance`), insurer, claim_no.
- **vitals** (triage): visit_id, temperature, bp_systolic / bp_diastolic, pulse, resp_rate, spo2, weight, height
  (BMI shown), taken_by, taken_at.
- **consult notes**: visit_id, history, examination, diagnosis (free text + optional ICD-10 code), plan, orders (lab
  tests / procedures / medicines — each a catalogue item, so billing is automatic), prescription lines
  (item, dose, frequency, days, quantity), doctor_id, signed_at.
- **appointments**: id, clinic_id, patient_id (or a new name + phone), date, time, with (staff), reason, status
  (`booked` / `arrived` → becomes a visit / `missed` / `cancelled`), reminder_sent.
- The **catalogue** (services and medicines), **sales**, **stock**, **shifts**, **staff** are the POS ones. Sales also carry
  patient_id, patient_name, patient_no, visit_id, visit_no (stage 6: add these columns).
- **insurance claims**: kept in customer_debts with kind = 'claim' and a `claim` object (insurer, scheme, member_no, preauth_no,
  claim_no, status, history, paid_ref, reject_reason); income counts when paid, like credit.
- **dispensing**: id, ts, sku, name, qty, is_rx, dose, freq, days, prescriber, patient_*, visit_*, dispensed_by, sale_id / claim_id.

## Roles
Five roles (build 15). Doctor, Nurse and Administrator keep the POS role keys, so the sign-in functions, row-level
security and permission checks copied from the POS work unchanged; the two new ones are plain keys the server passes
through.

| Role on screen | Stored as | Sees on the hospital screen | Start of shift |
|------|-----|-----|-----|
| Receptionist | `receptionist` | Reception (register, start a visit), Appointments, Triage queue (the nurse takes the vitals) | clock in |
| Nurse | `cashier` | everything except the back office and the Cashier; no prices or money anywhere | clock in |
| Doctor | `supervisor` | everything except the back office and the Cashier, no prices or money; only a doctor calls patients in and writes notes | clock in |
| Pharmacist | `pharmacist` | Pharmacy (dispense, over-the-counter till) and Cashier | counts the cash drawer (the POS cash shift) |
| Administrator | `admin` | everything, plus Attendance and the Back office | clock in |

**Time on duty.** Everyone records the start and end of work: the pharmacist through the POS cash shift (float at the
start, cash-up at the end), everyone else with a clock-in ("Start your shift", the time is recorded) and **Shift → End
shift**. Both are the audit records "Shift started" / "Shift ended", which every phone receives, so the administrator's
**Attendance** screen shows who is on duty now, every shift (start, end, hours) and hours per person, from all phones. A
shift not ended by the next day is closed as "Not ended" when the person next starts work.

Clinical notes are visible to doctors and administrators. **Money is only for the pharmacist and the administrator**
(build 18): only they take payments (Cashier), see prices (tests, services, medicines), the over-the-counter till and
receiving stock, and the day's takings. The Patient tracker is a queue board - each step with who is there (ticket and
name, urgent in red) and the longest wait - plus seen today, in the hospital, urgent and appointments still to come.

## Things to decide / get right (health data)
- Patient records are **sensitive personal data** under Kenya's Data Protection Act 2019: the clinic should register
  with the ODPC, get patient consent at registration, and the app should keep an access log on patient files
  (who opened what, when). The privacy and terms pages copied from the POS must be rewritten for a clinic before
  real patients are entered.
- Lab results entry and printable patient summary / referral letter — after the first version.
- Automatic SMS appointment reminders — needs an SMS provider (Africa's Talking or similar) and its cost; until then reminders are sent by hand from the phone's SMS / WhatsApp.
