# Clinic on the go — plan

A clinic app for small clinics and dispensaries, built on the **My DukaGO POS** foundation (copied, not shared):
offline-first on the phone, sync to its **own** Supabase project, staff PINs and roles, shifts, cash / M-Pesa,
receipts, reports, stock. The POS code it started from is build 101 (Oct 2026).

Served at `https://muturifrancis25-dev.github.io/clinic-on-the-go/` — the same web address as the POS, so everything
stored on the phone uses clinic-only names (database `clinic_otg_db_v1`, settings `clinic_otg_*`, offline cache
`clinic-otg-shell-*`, sync lock `clinic-otg-sync`). The two apps can be installed side by side on one phone.

## Stages
| # | What | Status |
|---|------|--------|
| 1 | Copy of the POS, renamed, separate storage, **Clinic** business type (consultation, lab, procedures, pharmacy Rx / OTC) as the default | done |
| 2 | **Patients** — register, search, patient file with visit history, consent, access log | done |
| 3 | **Visits & queue** — check-in → triage (vitals) → doctor (notes, diagnosis, orders) → billing → done | next |
| 4 | **Billing & pharmacy** — a visit's fees and dispensed medicines go to the existing till; cash, M-Pesa, insurance (SHA / private) | |
| 5 | **Appointments** — book, day list, check an appointment in as a visit | |
| 6 | **Own Supabase project** — tables + row-level security per clinic, sign-in functions (copied from the POS), deploy | needs the project |

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
- The **catalogue** (services and medicines), **sales**, **stock**, **shifts**, **staff** are the POS ones.

## Roles (POS roles kept, clinic ones added)
| Role | Can |
|------|-----|
| Receptionist (POS "cashier") | register patients, check in, appointments, take payment |
| Nurse | the above + triage / vitals |
| Doctor (clinical officer) | everything clinical: notes, diagnosis, orders, prescriptions |
| Supervisor / Admin | as in the POS (reports, stock, staff, refunds) + all of the above |

Clinical notes are visible to clinical staff only; reception sees names, queue and bills.

## Things to decide / get right (health data)
- Patient records are **sensitive personal data** under Kenya's Data Protection Act 2019: the clinic should register
  with the ODPC, get patient consent at registration, and the app should keep an access log on patient files
  (who opened what, when). The privacy and terms pages copied from the POS must be rewritten for a clinic before
  real patients are entered.
- Lab results entry and printable patient summary / referral letter — after the first version.
- SMS appointment reminders — needs an SMS provider (Africa's Talking or similar) and its cost.
