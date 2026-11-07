/* نظام إدارة العمال والرواتب - الواجهة الرئيسية
 * - كل القراءات تمر من RLS، وكل الكتابات تمر من دوال RPC آمنة في قاعدة البيانات.
 * - المتصفح لا يحسب أي مبلغ ولا يحدد أي صلاحية؛ قاعدة البيانات هي المرجع الوحيد.
 */
(() => {
  'use strict';

  const cfg = window.ERP_CONFIG;
  const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true }
  });

  const S = { profile: null, factories: [], shifts: [], employees: [], factoryId: null, attDate: null, weekStart: null, repFrom: null, repTo: null };
  const CHAIRMAN_ONLY = ['payroll', 'audit', 'settings', 'backup', 'adjustments', 'mgmt', 'managers'];
  const WEEK = { open: 'مفتوح', calculated: 'محسوب', approved: 'معتمد', closed: 'مغلق' };
  const STATUS_LBL = { active: 'نشط', suspended: 'موقوف', resigned: 'مستقيل' };
  const ATT_OPTS = [['', '—'], ['present', 'حاضر'], ['absent', 'غائب'], ['leave', 'إجازة'], ['mission', 'مأمورية']];
  const PAY_LBL = { unpaid: 'لم يُصرف', partial: 'صُرف جزئياً', paid: 'صُرف بالكامل' };
  const LOADING = '<p class="muted">جارٍ التحميل…</p>';

  const $ = (sel, root = document) => root.querySelector(sel);

  // ---------- أدوات مساعدة ----------
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const money = (n) => Number(n || 0).toLocaleString('ar-EG', { minimumFractionDigits: 2, maximumFractionDigits: 2 }) + ' ' + cfg.CURRENCY;
  const pad = (n) => String(n).padStart(2, '0');
  const ymd = (d) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const todayStr = () => new Date().toLocaleDateString('en-CA', { timeZone: cfg.TIMEZONE });
  const addDays = (s, n) => { const d = new Date(s + 'T12:00:00'); d.setDate(d.getDate() + n); return ymd(d); };
  // بداية الأسبوع المالي: السبت (getDay = 6)
  const weekStartOf = (s) => { const d = new Date(s + 'T12:00:00'); return addDays(s, -((d.getDay() - 6 + 7) % 7)); };
  const monthStart = (s) => s.slice(0, 8) + '01';
  const nextSaturday = (s) => { const d = new Date(s + 'T12:00:00'); return addDays(s, (6 - d.getDay() + 7) % 7); };

  // وقت الحضور بتوقيت القاهرة مع الإزاحة الصحيحة (تحسب تلقائياً تغيّر التوقيت الصيفي)
  function cairoIso(dateStr, timeStr) {
    const guess = new Date(`${dateStr}T${timeStr}:00Z`);
    const parts = new Intl.DateTimeFormat('en-US', {
      timeZone: cfg.TIMEZONE, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit',
      hour: '2-digit', minute: '2-digit', second: '2-digit'
    }).formatToParts(guess);
    const g = (t) => +parts.find((p) => p.type === t).value;
    const wallAsUtc = Date.UTC(g('year'), g('month') - 1, g('day'), g('hour'), g('minute'), g('second'));
    const off = Math.round((wallAsUtc - guess.getTime()) / 60000);
    const a = Math.abs(off);
    return `${dateStr}T${timeStr}:00${off >= 0 ? '+' : '-'}${pad(Math.floor(a / 60))}:${pad(a % 60)}`;
  }
  const timeOf = (iso) => (iso ? new Date(iso).toLocaleTimeString('en-GB', { timeZone: cfg.TIMEZONE, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }) : '');

  function toast(msg, isErr = false) {
    const t = document.createElement('div');
    t.className = 'toast' + (isErr ? ' err' : '');
    t.textContent = msg;
    document.body.appendChild(t);
    setTimeout(() => t.remove(), 4000);
  }
  const fail = (e) => toast((e && e.message) || String(e), true);

  async function rpc(name, args) {
    const { data, error } = await sb.rpc(name, args);
    if (error) throw error;
    return data;
  }

  const fld = (label, name, type = 'text', value = '', extra = '') =>
    `<label>${label}<input name="${name}" type="${type}" value="${esc(value)}" ${extra}></label>`;
  const selFld = (label, name, opts, value = '') =>
    `<label>${label}<select name="${name}">${opts.map(([v, l]) => `<option value="${esc(v)}" ${String(v) === String(value ?? '') ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></label>`;

  function dialog(title, html, submitFn, submitLabel = 'حفظ') {
    const ov = document.createElement('div');
    ov.className = 'overlay';
    ov.innerHTML = `<form class="dlg"><h3>${esc(title)}</h3>${html}
      <div class="row end"><button type="button" class="ghost" data-x>إلغاء</button><button type="submit">${esc(submitLabel)}</button></div></form>`;
    document.body.appendChild(ov);
    ov.querySelector('[data-x]').onclick = () => ov.remove();
    ov.querySelector('form').onsubmit = async (e) => {
      e.preventDefault();
      const btn = e.target.querySelector('button[type=submit]');
      btn.disabled = true;
      try {
        await submitFn(Object.fromEntries(new FormData(e.target)));
        ov.remove();
        toast('تم الحفظ');
        route();
      } catch (err) {
        fail(err);
        btn.disabled = false;
      }
    };
  }

  function info(title, html) {
    const ov = document.createElement('div');
    ov.className = 'overlay';
    ov.innerHTML = `<div class="dlg"><h3>${esc(title)}</h3>${html}<div class="row end"><button type="button" data-x>إغلاق</button></div></div>`;
    document.body.appendChild(ov);
    ov.querySelector('[data-x]').onclick = () => ov.remove();
  }

  function drawBar(canvasId, labels, values, label) {
    const c = document.getElementById(canvasId);
    if (!c || !window.Chart) return;
    new window.Chart(c, {
      type: 'bar',
      data: { labels, datasets: [{ label, data: values, backgroundColor: '#c9a227' }] },
      options: { responsive: true, plugins: { legend: { display: false } } }
    });
  }

  function exportTable(tableId, filename) {
    const t = document.getElementById(tableId);
    if (!t) return;
    const csv = [...t.rows].map((r) => [...r.cells].map((c) => `"${c.textContent.trim().replace(/"/g, '""')}"`).join(',')).join('\r\n');
    const url = URL.createObjectURL(new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8' }));
    download(url, filename);
  }
  function download(url, filename) {
    const a = document.createElement('a');
    a.href = url; a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  // ---------- الجلسة والدخول ----------
  // المستخدمون يدخلون باسم المستخدم (مثل fattaha_mgr) ويُحوَّل تلقائياً إلى البريد المرتبط
  function emailFromInput(v) {
    v = v.trim();
    if (v.includes('@')) return v;
    return v.replace(/_mgr$/, '.mgr') + '@erp.local';
  }

  function renderLogin(msg = '') {
    S.profile = null;
    $('#app').innerHTML = `
      <section class="login">
        <div class="brand"><h1>نظام إدارة العمال والرواتب</h1><p>مصنع الفتّاحة · مصنع النسيج · مصنع الغزل</p></div>
        <form id="login" class="card">
          <label>اسم المستخدم<input name="u" autocomplete="username" required></label>
          <label>كلمة المرور<input name="p" type="password" autocomplete="current-password" required></label>
          <button type="submit" style="width:100%">دخول</button>
          <p class="err">${esc(msg)}</p>
        </form>
      </section>`;
    $('#login').onsubmit = async (e) => {
      e.preventDefault();
      const fd = new FormData(e.target);
      const btn = e.target.querySelector('button');
      btn.disabled = true;
      const { error } = await sb.auth.signInWithPassword({ email: emailFromInput(fd.get('u')), password: fd.get('p') });
      if (error) { btn.disabled = false; return renderLogin('بيانات الدخول غير صحيحة'); }
      await boot();
    };
  }

  async function loadShifts() {
    const { data } = await sb.from('shifts').select('id,factory_id,name,start_time,end_time,required_hours,is_night,is_active').order('start_time');
    S.shifts = data || [];
  }

  async function boot() {
    const { data: { session } } = await sb.auth.getSession();
    if (!session) return renderLogin();
    const { data: prof, error } = await sb.from('profiles')
      .select('id,username,full_name,role,factory_id,is_active').eq('id', session.user.id).maybeSingle();
    if (error || !prof || !prof.is_active) {
      await sb.auth.signOut();
      return renderLogin('هذا الحساب غير مفعّل أو غير مرتبط بصلاحيات');
    }
    S.profile = prof;
    const { data: f } = await sb.from('factories').select('id,code,name_ar').eq('is_active', true).order('code');
    S.factories = f || [];
    await loadShifts();
    if (prof.role === 'factory_manager') S.factoryId = prof.factory_id;
    if (!location.hash) location.hash = '#/dashboard'; else route();
  }

  // ---------- الهيكل والتوجيه ----------
  const scopeFactory = () => (S.profile.role === 'factory_manager' ? S.profile.factory_id : S.factoryId);
  const factoryName = (id) => (S.factories.find((f) => f.id === id) || {}).name_ar || '';
  const shiftName = (id) => (S.shifts.find((s) => s.id === id) || {}).name || '—';
  const shiftsOf = (fid) => S.shifts.filter((s) => s.factory_id === fid && s.is_active);
  const empName = (id) => (S.employees.find((e) => e.id === id) || {}).full_name || '—';

  function page(key, title, body) {
    const chair = S.profile.role === 'chairman';
    const items = [['dashboard', 'الرئيسية'], ['employees', 'العمال'], ['attendance', 'الحضور'], ['shifts', 'الورديات'], ['advances', 'السلف'], ['reports', 'التقارير']];
    if (chair) items.push(['payroll', 'الرواتب'], ['adjustments', 'المكافآت والجزاءات'], ['mgmt', 'حضور الإدارة'], ['managers', 'المديرون'], ['audit', 'سجل العمليات'], ['settings', 'الإعدادات'], ['backup', 'النسخ الاحتياطي']);
    const nav = items.map(([k, l]) => `<a href="#/${k}" class="${k === key ? 'on' : ''}">${l}</a>`).join('');
    const picker = chair
      ? `<select data-set="factoryId" aria-label="المصنع"><option value="">كل المصانع</option>${S.factories.map((f) => `<option value="${f.id}" ${f.id === S.factoryId ? 'selected' : ''}>${esc(f.name_ar)}</option>`).join('')}</select>`
      : `<span class="badge">${esc(factoryName(S.profile.factory_id))}</span>`;
    $('#app').innerHTML = `
      <header class="top">
        <div><strong>${esc(title)}</strong><small>${esc(S.profile.full_name)} · ${chair ? 'رئيس مجلس الإدارة' : 'مدير مصنع'}</small></div>
        <div class="top-actions">${picker}<button class="ghost" data-action="logout">خروج</button></div>
      </header>
      <nav class="tabs">${nav}</nav>
      <main id="main">${body}</main>`;
  }

  const VIEWS = {
    dashboard: viewDashboard, employees: viewEmployees, attendance: viewAttendance, shifts: viewShifts,
    advances: viewAdvances, reports: viewReports, payroll: viewPayroll, audit: viewAudit,
    settings: viewSettings, backup: viewBackup
  };

  async function route() {
    if (!S.profile) return;
    const requested = location.hash.replace(/^#\//, '') || 'dashboard';
    const key = VIEWS[requested] ? requested : 'dashboard';
    if (CHAIRMAN_ONLY.includes(key) && S.profile.role !== 'chairman') {
      return page(key, 'غير مصرح', '<div class="card err">هذه الصفحة لرئيس مجلس الإدارة فقط.</div>');
    }
    try {
      await VIEWS[key]();
    } catch (e) {
      page(key, 'خطأ', `<div class="card err">${esc(e.message)}</div>`);
    }
  }

  // ---------- الرئيسية ----------
  async function viewDashboard() {
    page('dashboard', 'الرئيسية', LOADING);
    const today = todayStr();
    const fid = scopeFactory();
    let eq = sb.from('employees').select('id,factory_id').eq('status', 'active');
    let aq = sb.from('attendance').select('factory_id,status,late_minutes,check_in_at,check_out_at').eq('work_date', today);
    if (fid) { eq = eq.eq('factory_id', fid); aq = aq.eq('factory_id', fid); }
    const [{ data: emps }, { data: att }] = await Promise.all([eq, aq]);
    const E = emps || [];
    const A = att || [];
    const stats = (f) => {
      const e = f ? E.filter((x) => x.factory_id === f) : E;
      const a = f ? A.filter((x) => x.factory_id === f) : A;
      return {
        active: e.length,
        present: a.filter((x) => x.status === 'present').length,
        absent: a.filter((x) => x.status === 'absent').length,
        late: a.filter((x) => x.status === 'present' && x.late_minutes > 0).length,
        noOut: a.filter((x) => x.status === 'present' && x.check_in_at && !x.check_out_at).length
      };
    };
    const card = (l, v) => `<div class="stat"><span>${l}</span><strong>${v}</strong></div>`;
    let body;
    let fin = null;
    if (fid) {
      const s = stats(fid);
      const wk = await rpc('get_week_status', { p_factory: fid, p_date: today });
      body = `<div class="grid">${card('العمال النشطون', s.active)}${card('الحاضرون اليوم', s.present)}${card('الغائبون', s.absent)}${card('المتأخرون', s.late)}${card('لم يسجلوا الانصراف', s.noOut)}${card('الأسبوع الحالي', WEEK[wk] || wk)}</div>`;
    } else {
      fin = await rpc('get_finance_summary', { p_from: monthStart(today), p_to: today });
      const tot = fin.by_factory.reduce((a, f) => ({ net: a.net + +f.net_due, paid: a.paid + +f.paid, rem: a.rem + +f.remaining }), { net: 0, paid: 0, rem: 0 });
      const rows = S.factories.map((f) => {
        const s = stats(f.id);
        return `<tr><td>${esc(f.name_ar)}</td><td>${s.active}</td><td>${s.present}</td><td>${s.absent}</td><td>${s.late}</td><td>${s.noOut}</td></tr>`;
      }).join('');
      body = `<div class="grid">${card('صافي الرواتب (الشهر)', money(tot.net))}${card('المصروف', money(tot.paid))}${card('غير المصروف', money(tot.rem))}${card('رصيد السلف المفتوحة', money(fin.outstanding_advances))}</div>
        <h3>مقارنة المصانع اليوم</h3>
        <div class="tablewrap"><table><thead><tr><th>المصنع</th><th>نشط</th><th>حاضر</th><th>غائب</th><th>متأخر</th><th>بلا انصراف</th></tr></thead><tbody>${rows}</tbody></table></div>
        <h3>صافي الرواتب حسب المصنع</h3><div class="chartbox"><canvas id="chart"></canvas></div>`;
    }
    page('dashboard', 'الرئيسية', body);
    if (fin) drawBar('chart', fin.by_factory.map((f) => f.name_ar), fin.by_factory.map((f) => +f.net_due), 'الصافي');
  }

  // ---------- العمال ----------
  async function viewEmployees() {
    const fid = scopeFactory();
    const chair = S.profile.role === 'chairman';
    page('employees', 'العمال', LOADING);
    let q = sb.from('employees').select('id,factory_id,full_name,job_title,phone,start_date,shift_id,status,notes').order('full_name');
    if (fid) q = q.eq('factory_id', fid);
    const { data } = await q;
    S.employees = data || [];
    const rows = S.employees.map((r) => `
      <div class="item" data-name="${esc(r.full_name)}">
        <div><strong>${esc(r.full_name)}</strong>
          <small>${esc(r.job_title || '')} · الوردية: ${esc(shiftName(r.shift_id))}${chair && !fid ? ' · ' + esc(factoryName(r.factory_id)) : ''}</small></div>
        <span class="pill ${r.status}">${STATUS_LBL[r.status] || r.status}</span>
        <div class="acts">
          <button class="ghost" data-action="editEmployee" data-id="${r.id}">تعديل</button>
          ${chair ? `<button class="ghost" data-action="wage" data-id="${r.id}">تحديد اليومية</button>
          <button class="ghost" data-action="wageHistory" data-id="${r.id}">سجل اليوميات</button>
          <button class="ghost" data-action="transfer" data-id="${r.id}">نقل لمصنع آخر</button>` : ''}
        </div>
      </div>`).join('');
    page('employees', 'العمال', `
      <div class="toolbar">
        <input type="search" placeholder="بحث بالاسم" data-filter aria-label="بحث">
        <button data-action="addEmployee">+ إضافة عامل</button>
      </div>
      ${!fid ? '<div class="warn">اختر مصنعاً من الأعلى لإضافة عامل جديد.</div>' : ''}
      <div class="list">${rows || '<p class="muted">لا يوجد عمال</p>'}</div>`);
  }

  const actions = {};

  actions.addEmployee = () => {
    const fid = scopeFactory();
    if (!fid) return toast('اختر مصنعاً أولاً', true);
    dialog('إضافة عامل',
      fld('الاسم الكامل *', 'full_name', 'text', '', 'required') +
      fld('الوظيفة', 'job_title') +
      fld('رقم الهاتف (اختياري)', 'phone') +
      fld('تاريخ بداية العمل *', 'start_date', 'date', todayStr(), 'required') +
      selFld('الوردية', 'shift_id', [['', 'بدون وردية'], ...shiftsOf(fid).map((s) => [s.id, s.name])]) +
      `<label>ملاحظات<textarea name="notes"></textarea></label>`,
      (fd) => rpc('create_employee', {
        p_factory: fid, p_full_name: fd.full_name, p_job_title: fd.job_title || null,
        p_phone: fd.phone || null, p_start_date: fd.start_date, p_shift: fd.shift_id || null, p_notes: fd.notes || null
      }));
  };

  actions.editEmployee = (el) => {
    const e = S.employees.find((x) => x.id === el.dataset.id);
    if (!e) return;
    dialog('تعديل بيانات العامل',
      fld('الاسم الكامل *', 'full_name', 'text', e.full_name, 'required') +
      fld('الوظيفة', 'job_title', 'text', e.job_title || '') +
      fld('رقم الهاتف', 'phone', 'text', e.phone || '') +
      selFld('الوردية', 'shift_id', [['', 'بدون وردية'], ...shiftsOf(e.factory_id).map((s) => [s.id, s.name])], e.shift_id || '') +
      selFld('الحالة', 'status', [['active', 'نشط'], ['suspended', 'موقوف'], ['resigned', 'مستقيل']], e.status) +
      `<label>ملاحظات<textarea name="notes">${esc(e.notes || '')}</textarea></label>`,
      (fd) => rpc('update_employee', {
        p_id: e.id, p_full_name: fd.full_name, p_job_title: fd.job_title || null, p_phone: fd.phone || null,
        p_shift: fd.shift_id || null, p_status: fd.status, p_notes: fd.notes || null
      }));
  };

  actions.wage = (el) => {
    const e = S.employees.find((x) => x.id === el.dataset.id);
    if (!e) return;
    dialog(`تحديد يومية: ${e.full_name}`,
      fld('اليومية الجديدة (ج.م) *', 'wage', 'number', '', 'step="0.01" min="0" required') +
      fld('تاريخ السريان *', 'effective_from', 'date', todayStr(), 'required') +
      fld('سبب التغيير *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => rpc('set_daily_wage', { p_employee: e.id, p_wage: Number(fd.wage), p_effective_from: fd.effective_from, p_reason: fd.reason }));
  };

  actions.wageHistory = async (el) => {
    const rows = await rpc('get_wage_history', { p_employee: el.dataset.id });
    info('سجل اليوميات',
      `<div class="tablewrap"><table><thead><tr><th>من تاريخ</th><th>اليومية</th><th>السبب</th></tr></thead><tbody>${
        (rows || []).map((r) => `<tr><td>${esc(r.effective_from)}</td><td>${money(r.daily_wage)}</td><td>${esc(r.reason)}</td></tr>`).join('') || '<tr><td colspan="3">لا توجد سجلات</td></tr>'
      }</tbody></table></div>`);
  };

  actions.transfer = (el) => {
    const e = S.employees.find((x) => x.id === el.dataset.id);
    if (!e) return;
    const others = S.factories.filter((f) => f.id !== e.factory_id).map((f) => [f.id, f.name_ar]);
    dialog(`نقل: ${e.full_name}`,
      selFld('المصنع الجديد *', 'to_factory', others) +
      fld('تاريخ سريان النقل (يوم السبت) *', 'effective_date', 'date', nextSaturday(todayStr()), 'required') +
      `<p class="muted">يبدأ النقل يوم السبت فقط. يبقى سجل الحضور والكشوف السابقة مع المصنع القديم.</p>` +
      fld('سبب النقل *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => rpc('transfer_employee', { p_employee: e.id, p_to_factory: fd.to_factory, p_effective_date: fd.effective_date, p_reason: fd.reason }));
  };

  // ---------- الحضور ----------
  async function viewAttendance() {
    const fid = scopeFactory();
    if (!fid) return page('attendance', 'الحضور والانصراف', '<div class="card">اختر مصنعاً من الأعلى لتسجيل الحضور.</div>');
    const date = S.attDate || todayStr();
    page('attendance', 'الحضور والانصراف', LOADING);
    const [{ data: emps }, { data: att }, wk] = await Promise.all([
      sb.from('employees').select('id,full_name,shift_id').eq('factory_id', fid).eq('status', 'active').order('full_name'),
      sb.from('attendance').select('id,employee_id,shift_id,status,check_in_at,check_out_at,notes').eq('factory_id', fid).eq('work_date', date),
      rpc('get_week_status', { p_factory: fid, p_date: date })
    ]);
    const byEmp = Object.fromEntries((att || []).map((a) => [a.employee_id, a]));
    const rows = (emps || []).map((e) => {
      const a = byEmp[e.id] || {};
      const shift = e.shift_id || a.shift_id || '';
      return `<tr data-row="${e.id}" data-name="${esc(e.full_name)}" data-shift="${shift}" data-att="${a.id || ''}">
        <td>${esc(e.full_name)}${shift ? '' : ' <small class="err">(بلا وردية)</small>'}</td>
        <td><select name="status">${ATT_OPTS.map(([v, l]) => `<option value="${v}" ${v === (a.status || '') ? 'selected' : ''}>${l}</option>`).join('')}</select></td>
        <td><input type="time" name="in" value="${timeOf(a.check_in_at)}"></td>
        <td><input type="time" name="out" value="${timeOf(a.check_out_at)}"></td>
        <td><input name="notes" value="${esc(a.notes || '')}"></td></tr>`;
    }).join('');
    page('attendance', 'الحضور والانصراف', `
      <div class="toolbar">
        <label style="flex:1">التاريخ<input type="date" value="${date}" data-set="attDate"></label>
      </div>
      ${wk !== 'open' ? `<div class="warn">الأسبوع ${WEEK[wk] || wk}. تعديل الحضور في أسبوع غير مفتوح يتطلب رئيس مجلس الإدارة وسبباً موثقاً.</div>` : ''}
      <div class="tablewrap"><table><thead><tr><th>العامل</th><th>الحالة</th><th>وقت الحضور</th><th>وقت الانصراف</th><th>ملاحظات</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="5">لا يوجد عمال نشطون</td></tr>'}</tbody></table></div>
      <div class="row end"><button data-action="saveAttendance">حفظ الحضور</button></div>
      <p class="muted">الصفوف التي لا تُختار لها حالة لن تُحفظ. ساعات العمل والتأخير والإضافي تُحسب تلقائياً في قاعدة البيانات.</p>`);
  }

  actions.saveAttendance = async () => {
    const date = S.attDate || todayStr();
    const bulk = [];
    const errors = [];
    let updated = 0;
    for (const tr of document.querySelectorAll('tr[data-row]')) {
      const status = tr.querySelector('[name=status]').value;
      if (!status) continue;
      const tin = tr.querySelector('[name=in]').value;
      const tout = tr.querySelector('[name=out]').value;
      const notes = tr.querySelector('[name=notes]').value.trim() || null;
      const inIso = tin && status === 'present' ? cairoIso(date, tin) : null;
      // وردية ليلية: الانصراف قبل الحضور زمنياً يعني اليوم التالي
      const outDate = tout && tin && tout <= tin ? addDays(date, 1) : date;
      const outIso = tout && status === 'present' ? cairoIso(outDate, tout) : null;
      const attId = tr.dataset.att;
      try {
        if (attId) {
          await rpc('update_attendance', { p_id: attId, p_status: status, p_check_in: inIso, p_check_out: outIso, p_notes: notes, p_reason: '' });
          updated++;
        } else {
          if (!tr.dataset.shift) { errors.push(`${tr.dataset.name}: لا توجد وردية`); continue; }
          bulk.push({ employee_id: tr.dataset.row, shift_id: tr.dataset.shift, work_date: date, status, check_in_at: inIso, check_out_at: outIso, notes });
        }
      } catch (e) {
        errors.push(`${tr.dataset.name}: ${e.message}`);
      }
    }
    let created = 0;
    if (bulk.length) {
      try { created = await rpc('record_attendance_bulk', { p_rows: bulk }); } catch (e) { errors.push(e.message); }
    }
    toast(`تم حفظ ${created} جديد و${updated} تعديل${errors.length ? ' مع ' + errors.length + ' خطأ' : ''}`, errors.length > 0);
    if (errors.length) alert(errors.join('\n'));
    route();
  };

  // ---------- الورديات ----------
  async function viewShifts() {
    const fid = scopeFactory();
    if (!fid) return page('shifts', 'الورديات', '<div class="card">اختر مصنعاً من الأعلى لإدارة ورديات مصنعه.</div>');
    page('shifts', 'الورديات', LOADING);
    const { data } = await sb.from('shifts').select('*').eq('factory_id', fid).order('start_time');
    const rows = (data || []).map((s) => `
      <div class="item">
        <div><strong>${esc(s.name)}</strong><small>${s.start_time.slice(0, 5)} ← ${s.end_time.slice(0, 5)} · ${s.required_hours} ساعة ${s.is_night ? '· وردية ليلية' : ''}</small></div>
        <span class="pill ${s.is_active ? 'active' : 'suspended'}">${s.is_active ? 'مفعّلة' : 'موقوفة'}</span>
        <div class="acts"><button class="ghost" data-action="editShift" data-id="${s.id}">تعديل</button></div>
      </div>`).join('');
    page('shifts', 'الورديات', `
      <div class="toolbar"><button data-action="addShift">+ إضافة وردية</button></div>
      <div class="list">${rows || '<p class="muted">لا توجد ورديات بعد</p>'}</div>`);
  }

  actions.addShift = () => {
    const fid = scopeFactory();
    dialog('إضافة وردية',
      fld('اسم الوردية *', 'name', 'text', '', 'required') +
      fld('وقت البداية *', 'start', 'time', '08:00', 'required') +
      fld('وقت النهاية *', 'end', 'time', '16:00', 'required') +
      fld('ساعات العمل المطلوبة *', 'hours', 'number', '8', 'step="0.25" min="0.25" max="24" required'),
      async (fd) => {
        await rpc('create_shift', { p_factory: fid, p_name: fd.name, p_start: fd.start, p_end: fd.end, p_hours: Number(fd.hours) });
        await loadShifts();
      });
  };

  actions.editShift = (el) => {
    const s = S.shifts.find((x) => x.id === el.dataset.id);
    if (!s) return;
    dialog('تعديل وردية',
      fld('اسم الوردية *', 'name', 'text', s.name, 'required') +
      fld('وقت البداية *', 'start', 'time', s.start_time.slice(0, 5), 'required') +
      fld('وقت النهاية *', 'end', 'time', s.end_time.slice(0, 5), 'required') +
      fld('ساعات العمل المطلوبة *', 'hours', 'number', s.required_hours, 'step="0.25" min="0.25" max="24" required') +
      selFld('الحالة', 'active', [['1', 'مفعّلة'], ['0', 'موقوفة']], s.is_active ? '1' : '0'),
      async (fd) => {
        await rpc('update_shift', { p_id: s.id, p_name: fd.name, p_start: fd.start, p_end: fd.end, p_hours: Number(fd.hours), p_active: fd.active === '1' });
        await loadShifts();
      });
  };

  // ---------- السلف ----------
  async function viewAdvances() {
    const fid = scopeFactory();
    page('advances', 'السلف', LOADING);
    let aq = sb.from('advances').select('id,employee_id,factory_id,amount,given_on,reason,deduction_method,weekly_deduction,balance_remaining,status').order('given_on', { ascending: false }).limit(200);
    if (fid) aq = aq.eq('factory_id', fid);
    const [{ data: adv }, { data: emps }] = await Promise.all([aq, sb.from('employees').select('id,full_name,factory_id,status').order('full_name')]);
    S.employees = emps || S.employees;
    const active = fid ? (emps || []).filter((e) => e.factory_id === fid && e.status === 'active') : [];
    const chair = S.profile.role === 'chairman';
    const rows = (adv || []).map((a) => `
      <tr><td>${esc(empName(a.employee_id))}</td><td>${money(a.amount)}</td><td>${money(a.balance_remaining)}</td>
      <td>${a.deduction_method === 'full' ? 'خصم كامل' : 'أقساط ' + money(a.weekly_deduction)}</td>
      <td>${esc(a.given_on)}</td><td>${esc(a.reason || '')}</td><td>${a.status === 'open' ? 'مفتوحة' : a.status === 'settled' ? 'مسددة' : 'ملغاة'}</td>
      <td>${chair && a.status === 'open' ? `<button class="ghost" data-action="cancelAdvance" data-id="${a.id}">إلغاء</button>` : ''}</td></tr>`).join('');
    page('advances', 'السلف', `
      <div class="toolbar">${fid ? '<button data-action="addAdvance">+ تسجيل سلفة</button>' : '<span class="muted">اختر مصنعاً لتسجيل سلفة</span>'}</div>
      <div class="tablewrap"><table><thead><tr><th>العامل</th><th>المبلغ</th><th>المتبقي</th><th>طريقة الخصم</th><th>التاريخ</th><th>السبب</th><th>الحالة</th><th></th></tr></thead>
        <tbody>${rows || '<tr><td colspan="8">لا توجد سلف</td></tr>'}</tbody></table></div>
      `);
  }

  actions.addAdvance = async () => {
    const fid = scopeFactory();
    const { data: emps } = await sb.from('employees').select('id,full_name').eq('factory_id', fid).eq('status', 'active').order('full_name');
    dialog('تسجيل سلفة',
      selFld('العامل *', 'employee', (emps || []).map((e) => [e.id, e.full_name])) +
      fld('المبلغ (ج.م) *', 'amount', 'number', '', 'step="0.01" min="0.01" required') +
      fld('تاريخ السلفة *', 'given_on', 'date', todayStr(), 'required') +
      selFld('طريقة الخصم', 'method', [['installments', 'على أقساط أسبوعية'], ['full', 'خصم كامل مرة واحدة']]) +
      fld('القسط الأسبوعي (للأقساط)', 'weekly', 'number', '', 'step="0.01" min="0"') +
      fld('السبب', 'reason'),
      (fd) => rpc('create_advance', {
        p_employee: fd.employee, p_amount: Number(fd.amount), p_given_on: fd.given_on, p_reason: fd.reason || null,
        p_method: fd.method, p_weekly: fd.method === 'installments' ? Number(fd.weekly) : null
      }));
  };

  actions.cancelAdvance = (el) => {
    dialog('إلغاء السلفة', fld('سبب الإلغاء *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => rpc('cancel_advance', { p_id: el.dataset.id, p_reason: fd.reason }), 'تأكيد الإلغاء');
  };

  // ---------- الرواتب (رئيس المجلس فقط) ----------
  async function viewPayroll() {
    const fid = S.factoryId;
    if (!fid) return page('payroll', 'الرواتب', '<div class="card">اختر مصنعاً من الأعلى لإدارة كشوف رواتبه.</div>');
    const week = S.weekStart || weekStartOf(todayStr());
    page('payroll', 'الرواتب', LOADING);
    const [status, items] = await Promise.all([
      rpc('get_week_status', { p_factory: fid, p_date: week }),
      rpc('get_payroll_week', { p_factory: fid, p_week_start: week })
    ]);
    const ids = (items || []).map((i) => i.employee_id);
    const { data: names } = ids.length ? await sb.from('employees').select('id,full_name').in('id', ids) : { data: [] };
    const nameOf = Object.fromEntries((names || []).map((n) => [n.id, n.full_name]));
    const canPay = status === 'approved' || status === 'closed';
    const btns = {
      open: `<button data-action="calcWeek">احسب الأسبوع</button>`,
      calculated: `<button class="gold" data-action="approveWeek">اعتماد الكشف</button>`,
      approved: `<button class="gold" data-action="closeWeek">إغلاق الأسبوع</button>`,
      closed: ''
    }[status] || '';
    const reopen = status !== 'open' ? `<button class="danger" data-action="reopenWeek">إعادة فتح الأسبوع</button>` : '';
    const total = (items || []).reduce((a, i) => ({ net: a.net + +i.net_due, paid: a.paid + +i.paid_total, rem: a.rem + +i.remaining_due }), { net: 0, paid: 0, rem: 0 });
    const rows = (items || []).map((i) => `
      <tr><td>${esc(nameOf[i.employee_id] || '—')}</td><td>${i.regular_days}</td><td>${i.friday_days}</td>
      <td>${money(i.total_due)}</td><td>${money(i.advance_deduction)}</td><td>${money(i.penalties_total)}</td>
      <td><strong>${money(i.net_due)}</strong></td><td>${money(i.paid_total)}</td><td>${money(i.remaining_due)}</td>
      <td>${PAY_LBL[i.payment_status] || i.payment_status}</td>
      <td>${canPay && +i.remaining_due > 0 ? `<button class="ghost" data-action="paySlip" data-id="${i.id}" data-remaining="${i.remaining_due}">صرف</button>` : ''}</td></tr>`).join('');
    page('payroll', 'الرواتب', `
      <div class="toolbar">
        <label style="flex:1">أي يوم من الأسبوع<input type="date" value="${week}" data-set="weekStart"></label>
      </div>
      <div class="card row"><span>حالة الأسبوع: <strong>${WEEK[status] || status}</strong> (من السبت ${week} إلى الجمعة ${addDays(week, 6)})</span></div>
      <div class="row" style="margin-bottom:12px">${btns}${reopen}
        <button class="ghost" data-action="exportCsv" data-table="payTable" data-name="payroll-${week}.csv">تصدير Excel</button>
        <button class="ghost" data-action="print">طباعة</button></div>
      <div class="grid">
        <div class="stat"><span>صافي المستحق</span><strong>${money(total.net)}</strong></div>
        <div class="stat"><span>المصروف</span><strong>${money(total.paid)}</strong></div>
        <div class="stat"><span>غير المصروف</span><strong>${money(total.rem)}</strong></div>
      </div>
      <div class="tablewrap"><table id="payTable"><thead><tr><th>العامل</th><th>أيام عادي</th><th>جمعة</th><th>الإجمالي</th><th>السلف</th><th>الجزاءات</th><th>الصافي</th><th>المدفوع</th><th>المتبقي</th><th>الحالة</th><th></th></tr></thead>
        <tbody>${rows || '<tr><td colspan="11">لا توجد كشوف لهذا الأسبوع. اضغط "احسب الأسبوع" بعد تسجيل الحضور.</td></tr>'}</tbody></table></div>`);
  }

  actions.calcWeek = async () => {
    const r = await rpc('calculate_payroll_week', { p_factory: S.factoryId, p_week_start: S.weekStart || weekStartOf(todayStr()) });
    toast(`تم حساب ${r.items} عامل`);
    route();
  };
  actions.approveWeek = async () => {
    await rpc('approve_payroll_week', { p_factory: S.factoryId, p_week_start: S.weekStart || weekStartOf(todayStr()) });
    toast('تم اعتماد الكشف'); route();
  };
  actions.closeWeek = async () => {
    await rpc('close_payroll_week', { p_factory: S.factoryId, p_week_start: S.weekStart || weekStartOf(todayStr()) });
    toast('تم إغلاق الأسبوع'); route();
  };
  actions.reopenWeek = () => {
    dialog('إعادة فتح الأسبوع', `<p class="warn">سيتم إلغاء الكشف وإرجاع خصومات السلف. لا يُسمح بذلك إذا وُجدت دفعات مسجلة.</p>` +
      fld('سبب إعادة الفتح *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => rpc('reopen_payroll_week', { p_factory: S.factoryId, p_week_start: S.weekStart || weekStartOf(todayStr()), p_reason: fd.reason }),
      'إعادة الفتح');
  };
  actions.paySlip = (el) => {
    dialog('صرف راتب',
      fld('المبلغ (ج.م) *', 'amount', 'number', el.dataset.remaining, 'step="0.01" min="0.01" max="' + el.dataset.remaining + '" required') +
      selFld('طريقة الصرف', 'method', [['cash', 'نقدي'], ['bank_transfer', 'تحويل بنكي'], ['other', 'أخرى']]) +
      fld('رقم مرجعي (اختياري)', 'reference') +
      fld('ملاحظات (اختياري)', 'notes'),
      (fd) => rpc('record_payroll_payment', {
        p_item: el.dataset.id, p_amount: Number(fd.amount), p_method: fd.method,
        p_reference: fd.reference || null, p_notes: fd.notes || null, p_idempotency_key: crypto.randomUUID()
      }), 'صرف');
  };

  // ---------- التقارير ----------
  async function viewReports() {
    const fid = scopeFactory();
    const chair = S.profile.role === 'chairman';
    const from = S.repFrom || monthStart(todayStr());
    const to = S.repTo || todayStr();
    page('reports', 'التقارير', LOADING);
    let aq = sb.from('attendance').select('employee_id,status,late_minutes,worked_hours,overtime_hours').gte('work_date', from).lte('work_date', to);
    if (fid) aq = aq.eq('factory_id', fid);
    const [{ data: att }, { data: emps }] = await Promise.all([aq, sb.from('employees').select('id,full_name')]);
    S.employees = emps || S.employees;
    const agg = {};
    for (const r of att || []) {
      const g = (agg[r.employee_id] ||= { present: 0, absent: 0, leave: 0, mission: 0, late: 0, hours: 0, ot: 0 });
      if (r.status in g) g[r.status]++;
      g.late += r.late_minutes || 0;
      g.hours += +r.worked_hours || 0;
      g.ot += +r.overtime_hours || 0;
    }
    const rows = Object.entries(agg).map(([id, g]) => `
      <tr><td>${esc(empName(id))}</td><td>${g.present}</td><td>${g.absent}</td><td>${g.leave}</td><td>${g.mission}</td>
      <td>${g.late}</td><td>${g.hours.toFixed(2)}</td><td>${g.ot.toFixed(2)}</td></tr>`).join('');
    let finHtml = '';
    let fin = null;
    if (chair) {
      fin = await rpc('get_finance_summary', { p_from: from, p_to: to });
      finHtml = `<h3>التقرير المالي (رئيس المجلس فقط)</h3>
        <div class="tablewrap"><table id="finTable"><thead><tr><th>المصنع</th><th>الإجمالي</th><th>السلف المخصومة</th><th>المكافآت</th><th>الجزاءات</th><th>الصافي</th><th>المصروف</th><th>غير المصروف</th></tr></thead><tbody>${
          fin.by_factory.map((f) => `<tr><td>${esc(f.name_ar)}</td><td>${money(f.total_due)}</td><td>${money(f.advances_deducted)}</td><td>${money(f.bonuses)}</td><td>${money(f.penalties)}</td><td>${money(f.net_due)}</td><td>${money(f.paid)}</td><td>${money(f.remaining)}</td></tr>`).join('')
        }</tbody></table></div>
        <p class="muted">رصيد السلف المفتوحة حالياً: ${money(fin.outstanding_advances)}</p>
        <div class="chartbox"><canvas id="finChart"></canvas></div>`;
    }
    page('reports', 'التقارير', `
      <div class="toolbar">
        <label style="flex:1">من<input type="date" value="${from}" data-set="repFrom"></label>
        <label style="flex:1">إلى<input type="date" value="${to}" data-set="repTo"></label>
      </div>
      <h3>تقرير الحضور</h3>
      <div class="row" style="margin-bottom:10px">
        <button class="ghost" data-action="exportCsv" data-table="attTable" data-name="attendance-${from}-${to}.csv">تصدير Excel</button>
        <button class="ghost" data-action="print">طباعة / حفظ PDF</button></div>
      <div class="tablewrap"><table id="attTable"><thead><tr><th>العامل</th><th>حاضر</th><th>غائب</th><th>إجازة</th><th>مأمورية</th><th>دقائق التأخير</th><th>ساعات العمل</th><th>الإضافي</th></tr></thead>
        <tbody>${rows || '<tr><td colspan="8">لا توجد بيانات في هذه الفترة</td></tr>'}</tbody></table></div>
      ${finHtml}`);
    if (fin) drawBar('finChart', fin.by_factory.map((f) => f.name_ar), fin.by_factory.map((f) => +f.net_due), 'الصافي');
  }

  // ---------- سجل العمليات (رئيس المجلس) ----------
  async function viewAudit() {
    page('audit', 'سجل العمليات', LOADING);
    const { data } = await sb.from('audit_logs').select('occurred_at,actor_username,factory_id,action,table_name,reason').order('occurred_at', { ascending: false }).limit(200);
    const rows = (data || []).map((r) => `<tr><td>${new Date(r.occurred_at).toLocaleString('ar-EG', { timeZone: cfg.TIMEZONE })}</td>
      <td>${esc(r.actor_username || '—')}</td><td>${esc(factoryName(r.factory_id) || '—')}</td><td>${esc(r.action)}</td><td>${esc(r.table_name)}</td><td>${esc(r.reason || '')}</td></tr>`).join('');
    page('audit', 'سجل العمليات', `<div class="tablewrap"><table><thead><tr><th>الوقت</th><th>المستخدم</th><th>المصنع</th><th>العملية</th><th>الجدول</th><th>السبب</th></tr></thead><tbody>${rows}</tbody></table></div>`);
  }

  // ---------- الإعدادات (السياسات المالية) ----------
  async function viewSettings() {
    page('settings', 'الإعدادات', LOADING);
    const { data } = await sb.from('system_settings').select('key,value');
    const get = (k) => (data || []).find((x) => x.key === k)?.value || {};
    const ot = get('overtime_policy'), late = get('late_deduction_policy'), lv = get('leave_policy'), ms = get('mission_policy');
    page('settings', 'الإعدادات', `
      <div class="card warn">هذه السياسات تطبق على الكشوف التي تُحسب بعد حفظها فقط، ولا تغيّر الأسابيع المعتمدة.</div>
      <form id="settings-form" class="card">
        <h3>العمل الإضافي</h3>
        <label class="row"><input type="checkbox" name="ot_enabled" ${ot.enabled ? 'checked' : ''} style="width:auto;min-height:auto"> تفعيل احتساب الإضافي</label>
        ${fld('معامل الإضافي', 'ot_rate', 'number', ot.rate_multiplier ?? 1, 'step="0.01" min="0"')}
        <h3>خصم التأخير</h3>
        <label class="row"><input type="checkbox" name="late_enabled" ${late.enabled ? 'checked' : ''} style="width:auto;min-height:auto"> تفعيل خصم التأخير</label>
        ${fld('الخصم لكل دقيقة تأخير (ج.م)', 'late_rate', 'number', late.per_minute ?? 0, 'step="0.0001" min="0"')}
        <h3>الإجازات والمأموريات</h3>
        ${fld('نسبة اليومية المدفوعة في الإجازة (0 إلى 1)', 'leave_factor', 'number', lv.paid_factor ?? 0, 'step="0.01" min="0" max="1"')}
        ${fld('نسبة اليومية المدفوعة في المأمورية (0 إلى 1)', 'mission_factor', 'number', ms.paid_factor ?? 0, 'step="0.01" min="0" max="1"')}
        ${fld('سبب تعديل السياسات *', 'reason', 'text', '', 'required minlength="3"')}
        <div class="row end"><button type="button" data-action="saveSettings">حفظ السياسات</button></div>
      </form>`);
  }

  actions.saveSettings = async () => {
    const f = $('#settings-form');
    const v = Object.fromEntries(new FormData(f));
    const reason = (v.reason || '').trim();
    if (reason.length < 3) return toast('اكتب سبب التعديل', true);
    const checked = (n) => f.querySelector(`[name=${n}]`).checked;
    await rpc('set_system_setting', { p_key: 'overtime_policy', p_value: { enabled: checked('ot_enabled'), rate_multiplier: Number(v.ot_rate) }, p_reason: reason });
    await rpc('set_system_setting', { p_key: 'late_deduction_policy', p_value: { enabled: checked('late_enabled'), per_minute: Number(v.late_rate) }, p_reason: reason });
    await rpc('set_system_setting', { p_key: 'leave_policy', p_value: { paid_factor: Number(v.leave_factor) }, p_reason: reason });
    await rpc('set_system_setting', { p_key: 'mission_policy', p_value: { paid_factor: Number(v.mission_factor) }, p_reason: reason });
    toast('تم حفظ السياسات');
    route();
  };

  // ---------- النسخ الاحتياطي (رئيس المجلس) ----------
  async function viewBackup() {
    page('backup', 'النسخ الاحتياطي', `
      <div class="card">
        <h3>تصدير نسخة كاملة</h3>
        <p class="muted">الملف يحتوي على كل البيانات بما فيها الرواتب والسلف واليوميات. احفظه في مكان آمن ولا تشاركه.</p>
        <button data-action="exportBackup">تنزيل النسخة الاحتياطية (JSON)</button>
      </div>
      <div class="card warn">استعادة البيانات من الملف تتم بإجراء تقني موثق، ولم تُنفَّذ كزر في الواجهة بعد.</div>`);
  }

  actions.exportBackup = async () => {
    const data = await rpc('export_backup');
    const url = URL.createObjectURL(new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' }));
    download(url, `erp-backup-${todayStr()}.json`);
    toast('تم تجهيز النسخة الاحتياطية');
  };

  // ---------- أحداث عامة ----------
  actions.logout = async () => {
    await sb.auth.signOut();
    location.hash = '';
    renderLogin();
  };
  actions.exportCsv = (el) => exportTable(el.dataset.table, el.dataset.name);
  actions.print = () => window.print();

  document.addEventListener('click', (ev) => {
    const el = ev.target.closest('[data-action]');
    if (!el) return;
    ev.preventDefault();
    const fn = actions[el.dataset.action];
    if (fn) Promise.resolve(fn(el)).catch(fail);
  });

  document.addEventListener('change', (ev) => {
    const el = ev.target.closest('[data-set]');
    if (!el) return;
    const key = el.dataset.set;
    let value = el.value || null;
    if (key === 'weekStart' && value) value = weekStartOf(value);
    S[key] = value;
    route();
  });

  document.addEventListener('input', (ev) => {
    if (!ev.target.matches('[data-filter]')) return;
    const q = ev.target.value.trim();
    document.querySelectorAll('[data-name]').forEach((n) => { n.hidden = !!q && !n.dataset.name.includes(q); });
  });

  // واجهة داخلية تستخدمها ملفات الشاشات الإضافية (features.js)
  window.ERP = {
    cfg, S, sb, VIEWS, actions, page, route, rpc, dialog, info, fld, selFld, esc, money, toast, fail,
    scopeFactory, todayStr, cairoIso, addDays, weekStartOf, monthStart, nextSaturday, download,
    factoryName, empName, shiftsOf, loadShifts, drawBar, WEEK, LOADING
  };

  window.addEventListener('hashchange', route);
  boot();
})();
