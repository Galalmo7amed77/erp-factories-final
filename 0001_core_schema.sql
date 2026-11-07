-- 0001: الجداول والقيود والفهارس. المالية في schema منفصل "finance" مغلق عن كل الأدوار.
create extension if not exists pgcrypto;
create extension if not exists btree_gist;
create schema if not exists finance;

create table public.factories (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code in ('FATTAHA','TEXTILE','SPINNING')),
  name_ar text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.profiles (
  id uuid primary key references auth.users(id) on delete restrict,
  username text not null unique check (username ~ '^[a-z][a-z0-9_]{2,31}$'),
  full_name text not null check (length(btrim(full_name)) > 0),
  role text not null check (role in ('chairman','factory_manager')),
  factory_id uuid references public.factories(id),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id),
  constraint profiles_role_factory_chk check (
    (role = 'chairman' and factory_id is null) or
    (role = 'factory_manager' and factory_id is not null))
);
create unique index profiles_single_chairman on public.profiles ((role)) where role = 'chairman';

create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  name text not null check (length(btrim(name)) > 0),
  start_time time not null,
  end_time time not null,
  required_hours numeric(5,2) not null check (required_hours > 0 and required_hours <= 24),
  is_night boolean generated always as (end_time <= start_time) stored,
  is_active boolean not null default true,
  unique (factory_id, name),
  unique (id, factory_id)
);

create table public.employees (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  full_name text not null check (length(btrim(full_name)) > 0),
  job_title text,
  phone text,
  start_date date not null,
  shift_id uuid,
  status text not null default 'active' check (status in ('active','suspended','resigned')),
  notes text,
  created_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, factory_id),
  constraint employees_shift_same_factory_fk foreign key (shift_id, factory_id)
    references public.shifts (id, factory_id)
);
create index employees_factory_status_idx on public.employees (factory_id, status);

create table public.employee_factory_assignments (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  factory_id uuid not null references public.factories(id),
  valid_from date not null,
  valid_to date,
  transfer_reason text,
  performed_by uuid references public.profiles(id),
  created_at timestamptz not null default now(),
  check (valid_to is null or valid_to > valid_from),
  exclude using gist (
    employee_id with =,
    daterange(valid_from, coalesce(valid_to, 'infinity'::date), '[)') with &&
  )
);

create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  employee_id uuid not null references public.employees(id),
  shift_id uuid not null,
  work_date date not null,
  status text not null check (status in ('present','absent','leave','mission')),
  check_in_at timestamptz,
  check_out_at timestamptz,
  worked_hours numeric(6,2) not null default 0 check (worked_hours >= 0),
  late_minutes int not null default 0 check (late_minutes >= 0),
  early_leave_minutes int not null default 0 check (early_leave_minutes >= 0),
  overtime_hours numeric(6,2) not null default 0 check (overtime_hours >= 0),
  notes text,
  recorded_by uuid not null references public.profiles(id),
  recorded_at timestamptz not null default now(),
  updated_by uuid references public.profiles(id),
  updated_at timestamptz,
  unique (employee_id, work_date, shift_id),
  check (check_out_at is null or check_in_at is null or check_out_at > check_in_at),
  check (status = 'present' or (check_in_at is null and check_out_at is null)),
  constraint attendance_shift_same_factory_fk foreign key (shift_id, factory_id)
    references public.shifts (id, factory_id)
);
create index attendance_factory_date_idx on public.attendance (factory_id, work_date);
create index attendance_employee_date_idx on public.attendance (employee_id, work_date);

create table public.advances (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  employee_id uuid not null references public.employees(id),
  amount numeric(14,4) not null check (amount > 0),
  given_on date not null,
  reason text,
  deduction_method text not null check (deduction_method in ('full','installments')),
  weekly_deduction numeric(14,4),
  balance_remaining numeric(14,4) not null check (balance_remaining >= 0),
  status text not null default 'open' check (status in ('open','settled','cancelled')),
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (balance_remaining <= amount),
  check (
    (deduction_method = 'full' and weekly_deduction is null) or
    (deduction_method = 'installments' and weekly_deduction > 0 and weekly_deduction <= amount))
);
create index advances_employee_idx on public.advances (employee_id, status);

create table public.employee_notes (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  employee_id uuid not null references public.employees(id),
  note_type text not null check (note_type in ('administrative','performance','violation')),
  body text not null check (length(btrim(body)) > 0),
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.management_attendance (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.profiles(id),
  factory_id uuid references public.factories(id),
  work_date date not null,
  check_in_at timestamptz,
  check_out_at timestamptz,
  worked_hours numeric(6,2) not null default 0 check (worked_hours >= 0),
  notes text,
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (person_id, work_date),
  check (check_out_at is null or check_in_at is null or check_out_at > check_in_at)
);

create table public.holidays (
  id uuid primary key default gen_random_uuid(),
  holiday_date date not null unique,
  name text not null,
  is_paid boolean not null default true
);

create table public.system_settings (
  key text primary key,
  value jsonb not null,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  occurred_at timestamptz not null default now(),
  actor_id uuid,
  actor_username text,
  factory_id uuid,
  action text not null,
  table_name text not null,
  record_id text,
  old_data jsonb,
  new_data jsonb,
  reason text
);

-- ===== schema مالي مغلق =====
create table finance.employee_wage_history (
  id uuid primary key default gen_random_uuid(),
  employee_id uuid not null references public.employees(id),
  daily_wage numeric(14,4) not null check (daily_wage >= 0),
  effective_from date not null,
  reason text not null check (length(btrim(reason)) > 0),
  set_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (employee_id, effective_from)
);

create table finance.payroll_periods (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  week_start date not null check (extract(isodow from week_start) = 6),
  week_end date generated always as (week_start + 6) stored,
  status text not null default 'open' check (status in ('open','calculated','approved','closed')),
  calculated_by uuid references public.profiles(id),
  calculated_at timestamptz,
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  closed_by uuid references public.profiles(id),
  closed_at timestamptz,
  unique (factory_id, week_start),
  unique (id, factory_id)
);

create table finance.payroll_items (
  id uuid primary key default gen_random_uuid(),
  payroll_period_id uuid not null,
  factory_id uuid not null references public.factories(id),
  employee_id uuid not null references public.employees(id),
  week_start date not null,
  regular_days int not null default 0 check (regular_days >= 0),
  friday_days int not null default 0 check (friday_days >= 0),
  absent_days int not null default 0 check (absent_days >= 0),
  leave_days int not null default 0 check (leave_days >= 0),
  mission_days int not null default 0 check (mission_days >= 0),
  gross_regular numeric(14,4) not null default 0 check (gross_regular >= 0),
  gross_friday numeric(14,4) not null default 0 check (gross_friday >= 0),
  leave_mission_pay numeric(14,4) not null default 0 check (leave_mission_pay >= 0),
  bonuses_total numeric(14,4) not null default 0 check (bonuses_total >= 0),
  overtime_total numeric(14,4) not null default 0 check (overtime_total >= 0),
  total_due numeric(14,4) not null default 0 check (total_due >= 0),
  advance_deduction numeric(14,4) not null default 0 check (advance_deduction >= 0),
  penalties_total numeric(14,4) not null default 0 check (penalties_total >= 0),
  other_deductions numeric(14,4) not null default 0 check (other_deductions >= 0),
  net_due numeric(14,4) not null default 0 check (net_due >= 0),
  paid_total numeric(14,4) not null default 0 check (paid_total >= 0),
  remaining_due numeric(14,4) not null default 0 check (remaining_due >= 0),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid','partial','paid')),
  created_at timestamptz not null default now(),
  unique (employee_id, week_start),
  unique (id, factory_id),
  constraint payroll_items_period_fk foreign key (payroll_period_id, factory_id)
    references finance.payroll_periods (id, factory_id),
  check (total_due = gross_regular + gross_friday + leave_mission_pay + bonuses_total + overtime_total),
  check (net_due = total_due - advance_deduction - penalties_total - other_deductions),
  check (paid_total + remaining_due = net_due)
);

create table finance.payroll_payments (
  id uuid primary key default gen_random_uuid(),
  payroll_item_id uuid not null references finance.payroll_items(id),
  factory_id uuid not null references public.factories(id),
  amount numeric(14,4) not null check (amount > 0),
  paid_at timestamptz not null default now(),
  method text not null check (method in ('cash','bank_transfer','other')),
  reference_no text,
  notes text,
  idempotency_key text not null unique check (length(idempotency_key) >= 8),
  recorded_by uuid not null references public.profiles(id),
  employee_confirmed boolean not null default false,
  employee_confirmed_at timestamptz,
  signature_storage_path text,
  created_at timestamptz not null default now()
);

create table finance.advance_repayments (
  id uuid primary key default gen_random_uuid(),
  advance_id uuid not null references public.advances(id),
  payroll_item_id uuid not null references finance.payroll_items(id),
  factory_id uuid not null references public.factories(id),
  amount numeric(14,4) not null check (amount > 0),
  created_at timestamptz not null default now(),
  unique (advance_id, payroll_item_id)
);

create table finance.bonuses (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  employee_id uuid not null references public.employees(id),
  event_date date not null,
  reason text not null check (length(btrim(reason)) > 0),
  amount numeric(14,4) not null check (amount > 0),
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected')),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  applied_payroll_item_id uuid references finance.payroll_items(id),
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (approval_status = 'pending' or approved_by is not null),
  check (applied_payroll_item_id is null or approval_status = 'approved')
);

create table finance.penalties (
  id uuid primary key default gen_random_uuid(),
  factory_id uuid not null references public.factories(id),
  employee_id uuid not null references public.employees(id),
  event_date date not null,
  reason text not null check (length(btrim(reason)) > 0),
  amount numeric(14,4) not null check (amount > 0),
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected')),
  approved_by uuid references public.profiles(id),
  approved_at timestamptz,
  applied_payroll_item_id uuid references finance.payroll_items(id),
  recorded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  check (approval_status = 'pending' or approved_by is not null),
  check (applied_payroll_item_id is null or approval_status = 'approved')
);
