// Edge Function: إدارة حسابات المديرين (رئيس مجلس الإدارة فقط)
// - مفتاح service_role يُقرأ من أسرار Supabase (SUPABASE_SERVICE_ROLE_KEY) ولا يُكتب في أي ملف.
// - كل عملية تتحقق أولاً من أن المتصل رئيس مجلس الإدارة عبر JWT الخاص به.
// - التغييرات في البيانات تتم عبر دوال RPC التي تفحص الهوية داخل قاعدة البيانات.
import { createClient } from 'jsr:@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...CORS, 'Content-Type': 'application/json' } });

const USERNAME_RE = /^[a-z][a-z0-9_]{2,31}$/;
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'METHOD_NOT_ALLOWED' }, 405);

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization') ?? '';

  // عميل بهوية المتصل: كل دوال قاعدة البيانات تفحص auth.uid() من هذا الـ JWT
  const userClient = createClient(url, anon, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  // عميل الإدارة: لا يُستخدم إلا لإنشاء/تعطيل حسابات Auth بعد التحقق من رئيس المجلس
  const admin = createClient(url, service, { auth: { persistSession: false, autoRefreshToken: false } });

  const { data: isChair, error: chairErr } = await userClient.rpc('is_chairman');
  if (chairErr || isChair !== true) return json({ error: 'FORBIDDEN: لرئيس مجلس الإدارة فقط' }, 403);

  let body: any;
  try { body = await req.json(); } catch { return json({ error: 'INVALID_JSON' }, 400); }
  const action = String(body?.action ?? '');

  try {
    if (action === 'list') {
      const { data, error } = await userClient
        .from('profiles').select('id,username,full_name,factory_id,is_active,created_at')
        .eq('role', 'factory_manager').order('username');
      if (error) throw error;
      return json({ managers: data });
    }

    if (action === 'create') {
      const username = String(body.username ?? '').trim();
      const fullName = String(body.full_name ?? '').trim();
      const factoryId = String(body.factory_id ?? '');
      const password = String(body.password ?? '');
      if (!USERNAME_RE.test(username)) return json({ error: 'اسم المستخدم: حروف إنجليزية صغيرة وأرقام و_ فقط (3 إلى 32)' }, 400);
      if (fullName.length < 3) return json({ error: 'الاسم الكامل مطلوب' }, 400);
      if (!UUID_RE.test(factoryId)) return json({ error: 'المصنع غير صالح' }, 400);
      if (password.length < 12) return json({ error: 'كلمة المرور 12 حرفاً على الأقل' }, 400);

      const email = `${username.replace(/_/g, '.')}@erp.local`;
      const { data: created, error: createErr } = await admin.auth.admin.createUser({
        email, password, email_confirm: true,
      });
      if (createErr || !created?.user) return json({ error: createErr?.message ?? 'تعذر إنشاء الحساب' }, 400);

      const { error: linkErr } = await userClient.rpc('link_manager_account', {
        p_user: created.user.id, p_username: username, p_full_name: fullName,
        p_factory: factoryId, p_reason: 'إنشاء حساب مدير مصنع',
      });
      if (linkErr) {
        // تراجع: لا يبقى حساب Auth يتيم بلا صلاحيات
        await admin.auth.admin.deleteUser(created.user.id);
        return json({ error: linkErr.message }, 400);
      }
      return json({ ok: true, id: created.user.id, email });
    }

    if (action === 'set_active') {
      const userId = String(body.user_id ?? '');
      const active = body.active === true;
      const reason = String(body.reason ?? '');
      if (!UUID_RE.test(userId)) return json({ error: 'معرّف غير صالح' }, 400);
      const { error: stErr } = await userClient.rpc('set_manager_status', { p_user: userId, p_active: active, p_reason: reason });
      if (stErr) return json({ error: stErr.message }, 400);
      const { error: banErr } = await admin.auth.admin.updateUserById(userId, { ban_duration: active ? 'none' : '876000h' });
      if (banErr) {
        // تراجع عن تغيير الحالة في قاعدة البيانات إذا فشل الحجب في Auth
        await userClient.rpc('set_manager_status', { p_user: userId, p_active: !active, p_reason: 'تراجع بسبب فشل الحجب في Auth' });
        return json({ error: 'فشل تحديث حالة الحساب في Auth: ' + banErr.message }, 500);
      }
      return json({ ok: true });
    }

    if (action === 'change_factory') {
      const { error } = await userClient.rpc('change_manager_factory', {
        p_user: String(body.user_id ?? ''), p_factory: String(body.factory_id ?? ''), p_reason: String(body.reason ?? ''),
      });
      if (error) return json({ error: error.message }, 400);
      return json({ ok: true });
    }

    return json({ error: 'UNKNOWN_ACTION' }, 400);
  } catch (e) {
    return json({ error: (e as Error).message ?? 'SERVER_ERROR' }, 500);
  }
});
