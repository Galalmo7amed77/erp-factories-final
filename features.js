/* شاشات إضافية تعتمد على واجهة ERP في app.js:
 *  - الحضور بأكثر من وردية للعامل في اليوم نفسه (يستبدل شاشة الحضور الأولى)
 *  - المكافآت والجزاءات واعتمادها (رئيس المجلس)
 *  - حضور الإدارة (رئيس المجلس)
 *  - إدارة حسابات المديرين عبر Edge Function
 *  - تصدير Excel (SheetJS)
 * كل الحسابات المالية والصلاحيات في قاعدة البيانات، والمتصفح يعرض فقط.
 */
(() => {
  'use strict';
  const E = window.ERP;
  if (!E) { console.error('ERP core not loaded'); return; }
  const { S, sb, VIEWS, actions, page, route, rpc, dialog, fld, selFld, esc, money, toast, fail,
    scopeFactory, todayStr, cairoIso, addDays, monthStart, nextSaturday, factoryName, empName,
    shiftsOf, loadShifts, drawBar, WEEK, LOADING } = E;

  const ATT_OPTS = [['', '—'], ['present', 'حاضر'], ['absent', 'غائب'], ['leave', 'إجازة'], ['mission', 'مأمورية']];
  const ADJ_LBL = { pending: 'بانتظار الاعتماد', approved: 'معتمدة', rejected: 'مرفوضة' };
  const timeOf = (iso) => (iso ? new Date(iso).toLocaleTimeString('en-GB', { timeZone: E.cfg.TIMEZONE, hour: '2-digit', minute: '2-digit', hourCycle: 'h23' }) : '');
  const outDateFor = (date, tin, tout) => (tin && tout && tout <= tin ? addDays(date, 1) : date);

  // ---------- تصدير Excel ----------
  function exportXlsx(tableId, filename) {
    const t = document.getElementById(tableId);
    if (!t) return toast('لا توجد بيانات للتصدير', true);
    if (!window.XLSX) return toast('مكتبة Excel لم تُحمَّل. تحقق من الاتصال بالإنترنت', true);
    const wb = window.XLSX.utils.table_to_book(t, { sheet: 'البيانات' });
    window.XLSX.writeFile(wb, filename.replace(/\.(csv|xlsx)$/i, '') + '.xlsx');
  }
  actions.exportCsv = (el) => exportXlsx(el.dataset.table, el.dataset.name);

  // ---------- الحضور بأكثر من وردية ----------
  function attRow(emp, att, shifts, first) {
    const shiftId = att ? att.shift_id : (emp.shift_id || '');
    const shiftCell = att
      ? `<span>${esc((shifts.find((s) => s.id === shiftId) || {}).name || '—')}</span>`
      : `<select name="shift"><option value="" ${!shiftId ? 'selected' : ''}>— اختر وردية —</option>${shifts.map((s) => `<option value="${s.id}" ${s.id === shiftId ? 'selected' : ''}>${esc(s.name)}</option>`).join('')}</select>`;
    const action = first
      ? `<button class="ghost" data-action="addShiftRow" data-emp="${emp.id}">+ وردية</button>`
      : (att ? '' : `<button class="ghost" data-action="removeRow">حذف</button>`);
    return `<tr data-row="${emp.id}" data-name="${esc(emp.full_name)}" data-att="${att ? att.id : ''}" data-shift="${att ? att.shift_id : ''}">
      <td>${esc(emp.full_name)}</td>
      <td>${shiftCell}</td>
      <td><select name="status">${ATT_OPTS.map(([v, l]) => `<option value="${v}" ${v === (att ? att.status : '') ? 'selected' : ''}>${l}</option>`).join('')}</select></td>
      <td><input type="time" name="in" value="${timeOf(att && att.check_in_at)}"></td>
      <td><input type="time" name="out" value="${timeOf(att && att.check_out_at)}"></td>
      <td><input name="notes" value="${esc(att ? att.notes : '')}"></td>
      <td>${action}</td></tr>`;
  }

  VIEWS.attendance = async function viewAttendanceMulti() {
    const fid = scopeFactory();
    if (!fid) return page('attendance', 'الحضور والانصراف', '<div class="card">اختر مصنعاً من الأعلى لتسجيل الحضور.</div>');
    const date = S.attDate || todayStr();
    page('attendance', 'الحضور والانصراف', LOADING);
    const [{ data: emps }, { data: att }, wk] = await Promise.all([
      sb.from('employees').select('id,full_name,shift_id').eq('factory_id', fid).eq('status', 'active').order('full_name'),
      sb.from('attendance').select('id,employee_id,shift_id,status,check_in_at,check_out_at,notes').eq('factory_id', fid).eq('work_date', date).order('recorded_at'),
      rpc('get_week_status', { p_factory: fid, p_date: date })
    ]);
    const shifts = shiftsOf(fid);
    const byEmp = {};
    for (const a of att || []) (byEmp[a.employee_id] ||= []).push(a);
    const rows = (emps || []).map((e) => {
      const list = byEmp[e.id] || [];
      const items = list.length ? list : [null];
      return items.map((a, i) => attRow(e, a, shifts, i === 0)).join('');
    }).join('');
    page('attendance', 'الحضور والانصراف', `
      <div class="toolbar"><label style="flex:1">التاريخ<input type="date" value="${date}" data-set="attDate"></label></div>
      ${wk !== 'open' ? `<div class="warn">الأسبوع ${WEEK[wk] || wk}. تعديل الحضور هنا يتطلب رئيس مجلس الإدارة وسبباً موثقاً.</div>` : ''}
      <div class="tablewrap"><table><thead><tr><th>العامل</th><th>الوردية</th><th>الحالة</th><th>الحضور</th><th>الانصراف</th><th>ملاحظات</th><th></th></tr></thead>
        <tbody>${rows || '<tr><td colspan="7">لا يوجد عمال نشطون</td></tr>'}</tbody></table></div>
      <div class="row end"><button data-action="saveAttendance">حفظ الحضور</button></div>
      <p class="muted">لكل عامل سجل لكل وردية. زر "+ وردية" يضيف وردية ثانية في اليوم نفسه. الصفوف بلا حالة لن تُحفظ.</p>`);
  };

  actions.addShiftRow = (el) => {
    const empId = el.dataset.emp;
    const first = document.querySelector(`tr[data-row="${empId}"]`);
    if (!first) return;
    const emp = { id: empId, full_name: first.dataset.name, shift_id: '' };
    const last = [...document.querySelectorAll(`tr[data-row="${empId}"]`)].pop();
    last.insertAdjacentHTML('afterend', attRow(emp, null, shiftsOf(scopeFactory()), false));
  };
  actions.removeRow = (el) => el.closest('tr').remove();

  actions.saveAttendance = async () => {
    const date = S.attDate || todayStr();
    const bulk = [];
    const errors = [];
    let updated = 0;
    for (const tr of document.querySelectorAll('tr[data-row]')) {
      const name = tr.dataset.name;
      const status = tr.querySelector('[name=status]').value;
      if (!status) continue;
      const tin = tr.querySelector('[name=in]').value;
      const tout = tr.querySelector('[name=out]').value;
      const notes = tr.querySelector('[name=notes]').value.trim() || null;
      const inIso = tin && status === 'present' ? cairoIso(date, tin) : null;
      const outIso = tout && status === 'present' ? cairoIso(outDateFor(date, tin, tout), tout) : null;
      try {
        if (tr.dataset.att) {
          await rpc('update_attendance', { p_id: tr.dataset.att, p_status: status, p_check_in: inIso, p_check_out: outIso, p_notes: notes, p_reason: '' });
          updated++;
        } else {
          const shiftEl = tr.querySelector('[name=shift]');
          const shift = shiftEl ? shiftEl.value : '';
          if (!shift) { errors.push(`${name}: اختر الوردية`); continue; }
          bulk.push({ employee_id: tr.dataset.row, shift_id: shift, work_date: date, status, check_in_at: inIso, check_out_at: outIso, notes });
        }
      } catch (e) {
        errors.push(`${name}: ${e.message}`);
      }
    }
    let created = 0;
    if (bulk.length) {
      try { created = await rpc('record_attendance_bulk', { p_rows: bulk }); } catch (e) { errors.push(e.message); }
    }
    toast(`تم حفظ ${created} سجل جديد و${updated} تعديل${errors.length ? ' مع ' + errors.length + ' خطأ' : ''}`, errors.length > 0);
    if (errors.length) alert(errors.join('\n'));
    route();
  };

  // ---------- المكافآت والجزاءات (رئيس المجلس) ----------
  const adjLabel = (s) => ADJ_LBL[s] || s;

  VIEWS.adjustments = async function viewAdjustments() {
    const fid = S.factoryId;
    const from = S.adjFrom || monthStart(todayStr());
    const to = S.adjTo || todayStr();
    page('adjustments', 'المكافآت والجزاءات', LOADING);
    const [bonuses, penalties, { data: emps }] = await Promise.all([
      rpc('list_adjustments', { p_kind: 'bonus', p_factory: fid, p_from: from, p_to: to }),
      rpc('list_adjustments', { p_kind: 'penalty', p_factory: fid, p_from: from, p_to: to }),
      sb.from('employees').select('id,full_name,factory_id,status').order('full_name')
    ]);
    S.employees = emps || S.employees;
    const table = (kind, list) => `<div class="tablewrap"><table><thead><tr><th>العامل</th><th>المصنع</th><th>التاريخ</th><th>القيمة</th><th>السبب</th><th>الحالة</th><th></th></tr></thead><tbody>${
      (list || []).map((a) => `<tr><td>${esc(empName(a.employee_id))}</td><td>${esc(factoryName(a.factory_id))}</td><td>${esc(a.event_date)}</td><td>${money(a.amount)}</td><td>${esc(a.reason)}</td>
        <td>${adjLabel(a.approval_status)}${a.applied ? ' · رُحِّل للكشف' : ''}</td>
        <td>${a.approval_status === 'pending' ? `<button data-action="decideAdj" data-kind="${kind}" data-id="${a.id}" data-approve="1">اعتماد</button> <button class="ghost" data-action="decideAdj" data-kind="${kind}" data-id="${a.id}" data-approve="0">رفض</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="7">لا توجد سجلات</td></tr>'
    }</tbody></table></div>`;
    page('adjustments', 'المكافآت والجزاءات', `
      <div class="toolbar">
        <label style="flex:1">من<input type="date" value="${from}" data-set="adjFrom"></label>
        <label style="flex:1">إلى<input type="date" value="${to}" data-set="adjTo"></label>
      </div>
      <div class="row" style="margin-bottom:10px"><button data-action="addAdjustment">+ تسجيل مكافأة أو جزاء</button></div>
      <p class="muted">المعلّقة لا تدخل الكشف. عند الاعتماد تُرحَّل تلقائياً إلى كشف الأسبوع الذي يحتوي على تاريخ الحدث، ولا تُرحَّل مرتين.</p>
      <h3>المكافآت</h3>${table('bonus', bonuses)}
      <h3>الجزاءات</h3>${table('penalty', penalties)}`);
  };

  actions.addAdjustment = async () => {
    const fid = S.factoryId;
    const people = (S.employees || []).filter((e) => e.status === 'active' && (!fid || e.factory_id === fid));
    dialog('تسجيل مكافأة أو جزاء',
      selFld('النوع *', 'kind', [['bonus', 'مكافأة'], ['penalty', 'جزاء']]) +
      selFld('العامل *', 'employee', people.map((e) => [e.id, e.full_name])) +
      fld('تاريخ الحدث *', 'event_date', 'date', todayStr(), 'required') +
      fld('القيمة (ج.م) *', 'amount', 'number', '', 'step="0.01" min="0.01" required') +
      fld('السبب *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => rpc('add_adjustment', { p_kind: fd.kind, p_employee: fd.employee, p_event_date: fd.event_date, p_amount: Number(fd.amount), p_reason: fd.reason }));
  };

  actions.decideAdj = (el) => {
    const approve = el.dataset.approve === '1';
    dialog(approve ? 'اعتماد المكافأة/الجزاء' : 'رفض المكافأة/الجزاء',
      fld('سبب القرار *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => rpc('decide_adjustment', { p_kind: el.dataset.kind, p_id: el.dataset.id, p_approve: approve, p_reason: fd.reason }),
      approve ? 'اعتماد' : 'رفض');
  };

  // ---------- حضور الإدارة (رئيس المجلس) ----------
  VIEWS.mgmt = async function viewMgmt() {
    const from = S.mgFrom || monthStart(todayStr());
    const to = S.mgTo || todayStr();
    page('mgmt', 'حضور الإدارة', LOADING);
    const [{ data: people }, { data: rows }] = await Promise.all([
      sb.from('profiles').select('id,full_name,role').order('full_name'),
      sb.from('management_attendance').select('person_id,work_date,check_in_at,check_out_at,worked_hours,notes').gte('work_date', from).lte('work_date', to).order('work_date', { ascending: false })
    ]);
    const nm = Object.fromEntries((people || []).map((p) => [p.id, p.full_name]));
    const body = (rows || []).map((r) => `<tr><td>${esc(nm[r.person_id] || '—')}</td><td>${esc(r.work_date)}</td><td>${timeOf(r.check_in_at)}</td><td>${timeOf(r.check_out_at)}</td><td>${Number(r.worked_hours).toFixed(2)}</td><td>${esc(r.notes || '')}</td></tr>`).join('');
    page('mgmt', 'حضور الإدارة', `
      <div class="toolbar">
        <label style="flex:1">من<input type="date" value="${from}" data-set="mgFrom"></label>
        <label style="flex:1">إلى<input type="date" value="${to}" data-set="mgTo"></label>
      </div>
      <div class="row" style="margin-bottom:10px"><button data-action="addMgmt">+ تسجيل حضور</button>
        <button class="ghost" data-action="exportCsv" data-table="mgTable" data-name="management-attendance-${from}.csv">تصدير Excel</button></div>
      <p class="muted">حضور رئيس المجلس والمديرين مستقل تماماً عن رواتب العمال ولا يدخل في أي حساب.</p>
      <div class="tablewrap"><table id="mgTable"><thead><tr><th>الاسم</th><th>التاريخ</th><th>الحضور</th><th>الانصراف</th><th>الساعات</th><th>ملاحظات</th></tr></thead>
        <tbody>${body || '<tr><td colspan="6">لا توجد سجلات</td></tr>'}</tbody></table></div>`);
  };

  actions.addMgmt = async () => {
    const { data: people } = await sb.from('profiles').select('id,full_name').eq('is_active', true).order('full_name');
    dialog('تسجيل حضور إداري',
      selFld('الشخص *', 'person', (people || []).map((p) => [p.id, p.full_name])) +
      fld('التاريخ *', 'work_date', 'date', todayStr(), 'required') +
      fld('وقت الحضور', 'tin', 'time') +
      fld('وقت الانصراف', 'tout', 'time') +
      fld('ملاحظات', 'notes'),
      (fd) => {
        const date = fd.work_date;
        const inIso = fd.tin ? cairoIso(date, fd.tin) : null;
        const outIso = fd.tout ? cairoIso(outDateFor(date, fd.tin, fd.tout), fd.tout) : null;
        return rpc('record_management_attendance', { p_person: fd.person, p_work_date: date, p_check_in: inIso, p_check_out: outIso, p_notes: fd.notes || null });
      });
  };

  // ---------- إدارة المديرين عبر Edge Function ----------
  async function edge(action, payload = {}) {
    const { data, error } = await sb.functions.invoke('manage-managers', { body: { action, ...payload } });
    if (error) {
      let msg = error.message;
      try { const j = await error.context.json(); msg = j.error || msg; } catch (_) { /* لا يوجد JSON */ }
      throw new Error(msg);
    }
    if (data && data.error) throw new Error(data.error);
    return data;
  }

  VIEWS.managers = async function viewManagers() {
    page('managers', 'المديرون', LOADING);
    const { managers } = await edge('list');
    const rows = (managers || []).map((m) => `
      <div class="item">
        <div><strong>${esc(m.full_name)}</strong><small>${esc(m.username)} · ${esc(factoryName(m.factory_id))}</small></div>
        <span class="pill ${m.is_active ? 'active' : 'suspended'}">${m.is_active ? 'مفعّل' : 'موقوف'}</span>
        <div class="acts">
          <button class="ghost" data-action="mgrFactory" data-id="${m.id}">تغيير المصنع</button>
          <button class="ghost" data-action="mgrActive" data-id="${m.id}" data-active="${m.is_active ? '0' : '1'}">${m.is_active ? 'إيقاف' : 'إعادة تفعيل'}</button>
        </div>
      </div>`).join('');
    page('managers', 'المديرون', `
      <div class="toolbar"><button data-action="mgrCreate">+ إنشاء حساب مدير</button></div>
      <div class="list">${rows || '<p class="muted">لا يوجد مديرون بعد</p>'}</div>
      <p class="muted">اسم المستخدم بحروف إنجليزية صغيرة وأرقام و_ فقط. كلمة المرور 12 حرفاً على الأقل. الحساب يُنشأ عبر Edge Function على الخادم، ومفتاح الإدارة لا يصل إلى المتصفح.</p>`);
  };

  actions.mgrCreate = () => {
    dialog('إنشاء حساب مدير',
      fld('اسم المستخدم *', 'username', 'text', '', 'required pattern="[a-z][a-z0-9_]{2,31}"') +
      fld('الاسم الكامل *', 'full_name', 'text', '', 'required minlength="3"') +
      selFld('المصنع *', 'factory_id', S.factories.map((f) => [f.id, f.name_ar])) +
      fld('كلمة المرور الأولية *', 'password', 'password', '', 'required minlength="12"'),
      (fd) => edge('create', fd));
  };

  actions.mgrActive = (el) => {
    const active = el.dataset.active === '1';
    dialog(active ? 'إعادة تفعيل المدير' : 'إيقاف المدير',
      fld('سبب القرار *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => edge('set_active', { user_id: el.dataset.id, active, reason: fd.reason }),
      active ? 'تفعيل' : 'إيقاف');
  };

  actions.mgrFactory = (el) => {
    dialog('تغيير مصنع المدير',
      selFld('المصنع الجديد *', 'factory_id', S.factories.map((f) => [f.id, f.name_ar])) +
      fld('سبب التغيير *', 'reason', 'text', '', 'required minlength="3"'),
      (fd) => edge('change_factory', { user_id: el.dataset.id, factory_id: fd.factory_id, reason: fd.reason }));
  };

  // ---------- تحميل مكتبة Excel عند الحاجة ----------
  if (!window.XLSX) {
    const s = document.createElement('script');
    s.src = 'https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js';
    document.head.appendChild(s);
  }
})();
