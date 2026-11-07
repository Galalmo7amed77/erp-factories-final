# التشغيل من الصفر (مشروع Supabase جديد)

## 1. قاعدة البيانات
نفّذ ملفات `supabase/migrations` بالترتيب من **SQL Editor** في Supabase:
`0001` ← `0002` ← `0003` ← `0004` ← `0005` ← `0006` ← `0007`

الملفات تنشئ الجداول والدوال والسياسات والمصانع الثلاثة والإعدادات المالية (معطلة افتراضياً).

## 2. حساب رئيس مجلس الإدارة (مرة واحدة)
1. من **Authentication ← Sign In / Providers** أوقف **Allow new users to sign up**.
2. من **Authentication ← Users ← Add user** أنشئ المستخدم بالبريد `chairman@erp.local` وكلمة مرور قوية، ثم انسخ الـ UUID الظاهر.
3. من **SQL Editor** شغّل (بعد استبدال UUID):

```sql
insert into public.profiles (id, username, full_name, role)
values ('<UUID-هنا>', 'chairman', 'رئيس مجلس الإدارة', 'chairman');
```

كلمة المرور لا تُكتب في أي ملف من الحزمة.

## 3. Edge Function إدارة المديرين
- ادفع `supabase/functions/manage-managers/index.ts` عبر Supabase CLI أو من لوحة Edge Functions بالاسم `manage-managers` مع **Verify JWT = on**.
- متغير `SUPABASE_SERVICE_ROLE_KEY` يُتاح تلقائياً للدالة من أسرار المشروع، ولا تضعه في أي ملف.

## 4. الواجهة
- ارفع محتويات مجلد الواجهة إلى GitHub وفعّل GitHub Pages (انظر README).
- `js/config.js` يحتوي على رابط المشروع والمفتاح العام فقط. إذا أنشأت مشروعاً جديداً، غيّر القيمتين فيه.

## 5. الاختبارات
- `supabase/tests/01_permissions_suite.sql` و`02_adjustments_attendance_suite.sql`.
- تستخدم معرّفات الحسابات الحالية. استبدلها بمعرّفات حساباتك قبل التشغيل.
