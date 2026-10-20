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
Three roles, shown as **Administrator, Doctor, Nurse** everywhere on screen. Underneath they keep the POS role keys,
so the sign-in functions, row-level security and permission checks copied from the POS work unchanged.

| Role on screen | Stored as | Can |
|------|-----|-----|
| Nurse | `cashier` | register patients, check in, triage / vitals, appointments, take payment |
| Doctor | `supervisor` | the above + clinical notes, diagnosis, orders, prescriptions; approves removals and reviews |
| Administrator | `admin` | everything: stock, reports, staff, refunds, settings |

Clinical notes are visible to doctors and administrators; nurses see triage, the queue and bills.

## Things to decide / get right (health data)
- Patient records are **sensitive personal data** under Kenya's Data Protection Act 2019: the clinic should register
  with the ODPC, get patient consent at registration, and the app should keep an access log on patient files
  (who opened what, when). The privacy and terms pages copied from the POS must be rewritten for a clinic before
  real patients are entered.
- Lab results entry and printable patient summary / referral letter — after the first version.
- Automatic SMS appointment reminders — needs an SMS provider (Africa's Talking or similar) and its cost; until then reminders are sent by hand from the phone's SMS / WhatsApp.
