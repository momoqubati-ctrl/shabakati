-- ====================================================================
-- Program R1: Retailer and Wholesale Merchant Identity & Governance
-- File: 20260919000001_program_r1_retailer_identity.sql
-- Version: 3.3.0 (Enterprise UBTR & Zero-PII Hardened)
-- Description:
--   1. Adds 'retailer' to user_role enum
--   2. Defines store_type, retailer_status, vendor_type enums
--   3. Extends business_category_enum and business_entity_type for Enterprise UBTR
--   4. Extends vendors with vendor_type and wholesale_license_number
--   5. Creates retailer_code_seq and public.retailers table with UNIQUE idempotency_key
--   6. Links retailers and audit logs directly with Enterprise UBTR (business_transactions)
--   7. Enforces strict immutability (Append-only) on retailer_audit_logs
--   8. Enforces immutability of retailer_code, idempotency_key, and protects status transitions
--   9. Implements Idempotent & Concurrency-Safe RPCs: register_retailer_profile, admin_verify_retailer
--   10. Updates handle_new_user trigger function for role 'retailer'
--   11. Creates Zero-PII Projection View: retailer_wholesale_directory
--   12. Establishes Multi-Role Row-Level Security (RLS) policies
-- ====================================================================

-- 1. أنواع البيانات (Enums)
DO $$
BEGIN
    ALTER TYPE public.user_role ADD VALUE IF NOT EXISTS 'retailer';
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'store_type') THEN
        CREATE TYPE public.store_type AS ENUM (
            'grocery',
            'supermarket',
            'commercial_center',
            'telecom_shop',
            'kiosk',
            'pos_outlet',
            'other'
        );
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'retailer_status') THEN
        CREATE TYPE public.retailer_status AS ENUM (
            'pending_verification',
            'active',
            'suspended',
            'blocked',
            'rejected'
        );
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'vendor_type') THEN
        CREATE TYPE public.vendor_type AS ENUM (
            'network_owner',
            'wholesale_merchant',
            'hybrid'
        );
    END IF;
END $$;

-- توسيع Enums سجل المعاملات البنكي المركزي Enterprise UBTR
DO $$
BEGIN
    ALTER TYPE public.business_category_enum ADD VALUE IF NOT EXISTS 'REGISTRATION';
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

DO $$
BEGIN
    ALTER TYPE public.business_entity_type ADD VALUE IF NOT EXISTS 'RETAILER';
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

-- 2. تحديث جدول التجار vendors لدعم تجار الجملة المعتمدين
ALTER TABLE public.vendors 
ADD COLUMN IF NOT EXISTS vendor_type public.vendor_type NOT NULL DEFAULT 'network_owner',
ADD COLUMN IF NOT EXISTS wholesale_license_number TEXT;

CREATE INDEX IF NOT EXISTS idx_vendors_vendor_type ON public.vendors(vendor_type);

-- 3. متسلسلة كود التاجر الفريد retailer_code
CREATE SEQUENCE IF NOT EXISTS public.retailer_code_seq START WITH 1001;

-- 4. جدول تجار التجزئة retailers مع مفتاح عدم التكرار والربط بـ UBTR
CREATE TABLE IF NOT EXISTS public.retailers (
    id UUID PRIMARY KEY REFERENCES public.profiles(id) ON DELETE RESTRICT,
    retailer_code VARCHAR(20) UNIQUE NOT NULL,
    store_name TEXT NOT NULL,
    store_type public.store_type NOT NULL DEFAULT 'grocery',
    commercial_registry TEXT,
    owner_national_id TEXT,
    city TEXT NOT NULL,
    zone TEXT NOT NULL,
    exact_address TEXT,
    contact_phone TEXT NOT NULL,
    whatsapp_phone TEXT,
    status public.retailer_status NOT NULL DEFAULT 'pending_verification',
    idempotency_key VARCHAR(255) NOT NULL UNIQUE,
    business_transaction_id UUID REFERENCES public.business_transactions(id),
    ubtr VARCHAR(50) NOT NULL,
    verified_at TIMESTAMPTZ,
    verified_by UUID REFERENCES public.profiles(id),
    rejection_reason TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_retailers_code ON public.retailers(retailer_code);
CREATE UNIQUE INDEX IF NOT EXISTS idx_retailers_idempotency_key ON public.retailers(idempotency_key);
CREATE INDEX IF NOT EXISTS idx_retailers_status ON public.retailers(status);
CREATE INDEX IF NOT EXISTS idx_retailers_city_zone ON public.retailers(city, zone);
CREATE INDEX IF NOT EXISTS idx_retailers_bt_id ON public.retailers(business_transaction_id);

-- تريجر حماية الحقول الثابتة ومنع التعديل غير المصرح للحالة
CREATE OR REPLACE FUNCTION public.trg_fn_retailer_guard()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.retailer_code IS NULL OR TRIM(NEW.retailer_code) = '' THEN
            NEW.retailer_code := 'RET-' || LPAD(nextval('public.retailer_code_seq')::TEXT, 5, '0');
        END IF;
        NEW.updated_at := NOW();
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE' THEN
        -- منع تغيير كود التاجر نهائياً بعد توليده
        IF NEW.retailer_code IS DISTINCT FROM OLD.retailer_code THEN
            RAISE EXCEPTION 'IMMUTABILITY_VIOLATION: retailer_code is an immutable identifier and cannot be modified';
        END IF;

        -- منع تعديل مفتاح عدم التكرار أو رابط UBTR
        IF NEW.idempotency_key IS DISTINCT FROM OLD.idempotency_key THEN
            RAISE EXCEPTION 'IMMUTABILITY_VIOLATION: idempotency_key is immutable';
        END IF;

        IF NEW.ubtr IS DISTINCT FROM OLD.ubtr THEN
            RAISE EXCEPTION 'IMMUTABILITY_VIOLATION: ubtr is immutable';
        END IF;

        -- منع تغيير الحالة مباشرة من قبل المستخدم غير المخول
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            IF auth.uid() IS NOT NULL THEN
                IF NOT EXISTS (SELECT 1 FROM public.profiles WHERE id = auth.uid() AND role = 'admin') THEN
                    RAISE EXCEPTION 'SECURITY_VIOLATION: Direct status modification is forbidden. Must use admin verification RPC.';
                END IF;
            END IF;
        END IF;

        NEW.updated_at := NOW();
        RETURN NEW;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_guard_retailer_code_and_status ON public.retailers;
DROP TRIGGER IF EXISTS trg_set_retailer_code ON public.retailers;
CREATE TRIGGER trg_guard_retailer_code_and_status
    BEFORE INSERT OR UPDATE ON public.retailers
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_fn_retailer_guard();

-- 5. جدول سجل التدقيق والمراجعة الإدارية لتجار التجزئة
CREATE TABLE IF NOT EXISTS public.retailer_audit_logs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    retailer_id UUID NOT NULL REFERENCES public.retailers(id) ON DELETE CASCADE,
    action VARCHAR(50) NOT NULL,
    actor_id UUID REFERENCES auth.users(id),
    reason TEXT,
    ubtr VARCHAR(255) NOT NULL,
    metadata JSONB DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_retailer_audit_logs_retailer ON public.retailer_audit_logs(retailer_id);
CREATE INDEX IF NOT EXISTS idx_retailer_audit_logs_ubtr ON public.retailer_audit_logs(ubtr);

-- ضمان صرامة سجل التدقيق: منع التعديل أو الحذف نهائياً (Append-only guarantee)
CREATE OR REPLACE FUNCTION public.trg_fn_prevent_audit_modification()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'IMMUTABILITY_VIOLATION: Audit logs are strictly append-only. Updates and Deletions are forbidden.';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_prevent_retailer_audit_mutation ON public.retailer_audit_logs;
DROP TRIGGER IF EXISTS trg_protect_retailer_audit_logs ON public.retailer_audit_logs;
CREATE TRIGGER trg_prevent_retailer_audit_mutation
    BEFORE UPDATE OR DELETE ON public.retailer_audit_logs
    FOR EACH ROW
    EXECUTE FUNCTION public.trg_fn_prevent_audit_modification();

-- 6. دالة التسجيل الذري لتاجر التجزئة مع ضمان منع التكرار والربط بـ Enterprise UBTR
CREATE OR REPLACE FUNCTION public.register_retailer_profile(
    p_store_name TEXT,
    p_store_type TEXT DEFAULT 'grocery',
    p_city TEXT DEFAULT 'صنعاء',
    p_zone TEXT DEFAULT '',
    p_exact_address TEXT DEFAULT '',
    p_contact_phone TEXT DEFAULT '',
    p_whatsapp_phone TEXT DEFAULT NULL,
    p_commercial_registry TEXT DEFAULT NULL,
    p_owner_national_id TEXT DEFAULT NULL,
    p_idempotency_key VARCHAR(255) DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
    v_user_id UUID;
    v_role user_role;
    v_existing_by_key RECORD;
    v_existing_by_user RECORD;
    v_code VARCHAR(20);
    v_ubtr VARCHAR(50);
    v_store_type store_type;
    v_key_uuid UUID;
    v_bt RECORD;
BEGIN
    -- 1. فحص مصادقة المستخدم
    v_user_id := auth.uid();
    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: User must be authenticated to register as retailer';
    END IF;

    IF p_idempotency_key IS NULL OR TRIM(p_idempotency_key) = '' THEN
        RAISE EXCEPTION 'IDEMPOTENCY_KEY_REQUIRED: An idempotency key must be provided';
    END IF;

    -- 2. فحص الـ Idempotency Replay أولاً (قبل فحص الدور لتمكين إعادة نفس الطلب للمستخدم المسجل)
    SELECT id, retailer_code, status, ubtr, idempotency_key
    INTO v_existing_by_key
    FROM public.retailers
    WHERE idempotency_key = p_idempotency_key;

    IF v_existing_by_key.id IS NOT NULL THEN
        IF v_existing_by_key.id = v_user_id THEN
            -- Replay لنفس المستخدم
            RETURN jsonb_build_object(
                'success', true,
                'retailer_code', v_existing_by_key.retailer_code,
                'status', v_existing_by_key.status,
                'ubtr', v_existing_by_key.ubtr,
                'is_idempotent_replay', true,
                'message', 'تمت معالجة هذا الطلب مسبقاً بنجاح (Idempotency Protected)'
            );
        ELSE
            -- نفس المفتاح مستخدم من حساب آخر
            RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Key % is already claimed by another user', p_idempotency_key;
        END IF;
    END IF;

    -- 3. فحص ما إذا كان المستخدم مسجلاً بالفعل (بمفتاح مختلف)
    SELECT id, retailer_code, status, ubtr
    INTO v_existing_by_user
    FROM public.retailers
    WHERE id = v_user_id;

    IF v_existing_by_user.id IS NOT NULL THEN
        RAISE EXCEPTION 'ALREADY_REGISTERED: User % already has a registered retailer profile (%)', v_user_id, v_existing_by_user.retailer_code;
    END IF;

    -- 4. فحص الصلاحية والدور للتسجيل الجديد (Authorization Guard)
    SELECT role INTO v_role FROM public.profiles WHERE id = v_user_id;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'PROFILE_NOT_FOUND: Profile does not exist for user %', v_user_id;
    END IF;

    IF v_role IN ('admin', 'vendor') THEN
        RAISE EXCEPTION 'FORBIDDEN_ROLE: Users with role % cannot register as retailers', v_role;
    END IF;

    IF v_role != 'customer' THEN
        RAISE EXCEPTION 'FORBIDDEN_ROLE: Only customers can register as retailers (current role: %)', v_role;
    END IF;

    -- 5. فحص نوع المتجر
    BEGIN
        v_store_type := p_store_type::store_type;
    EXCEPTION WHEN OTHERS THEN
        v_store_type := 'grocery'::store_type;
    END;

    -- 6. إنشاء معاملة UBTR مركزية حقيقية عبر Enterprise UBTR
    v_key_uuid := md5('retailer_reg:' || p_idempotency_key)::uuid;

    SELECT * INTO v_bt
    FROM public.create_business_transaction(
        v_key_uuid,
        'RETAILER_REGISTRATION',
        'REGISTRATION'::public.business_category_enum,
        'RETAILER_ONBOARDING',
        'PENDING'::public.business_status_enum,
        'CUSTOMER'::public.business_stage_enum,
        NULL,
        v_user_id,
        NULL,
        NULL
    );

    v_ubtr := public._ubtr_display(v_bt.business_reference);
    v_code := 'RET-' || LPAD(nextval('public.retailer_code_seq')::TEXT, 5, '0');

    -- 7. محاولة الإدخال الذري مع حماية التسابق المتزامن (Concurrency Rescue)
    BEGIN
        INSERT INTO public.retailers (
            id,
            retailer_code,
            store_name,
            store_type,
            commercial_registry,
            owner_national_id,
            city,
            zone,
            exact_address,
            contact_phone,
            whatsapp_phone,
            status,
            idempotency_key,
            business_transaction_id,
            ubtr
        ) VALUES (
            v_user_id,
            v_code,
            p_store_name,
            v_store_type,
            p_commercial_registry,
            p_owner_national_id,
            p_city,
            p_zone,
            p_exact_address,
            p_contact_phone,
            COALESCE(p_whatsapp_phone, p_contact_phone),
            'pending_verification'::retailer_status,
            p_idempotency_key,
            v_bt.business_transaction_id,
            v_ubtr
        );
    EXCEPTION WHEN unique_violation THEN
        SELECT id, retailer_code, status, ubtr, idempotency_key
        INTO v_existing_by_key
        FROM public.retailers
        WHERE idempotency_key = p_idempotency_key;

        IF v_existing_by_key.id IS NOT NULL THEN
            IF v_existing_by_key.id = v_user_id THEN
                RETURN jsonb_build_object(
                    'success', true,
                    'retailer_code', v_existing_by_key.retailer_code,
                    'status', v_existing_by_key.status,
                    'ubtr', v_existing_by_key.ubtr,
                    'is_idempotent_replay', true,
                    'message', 'تمت معالجة هذا الطلب مسبقاً بنجاح (Idempotency Protected)'
                );
            ELSE
                RAISE EXCEPTION 'IDEMPOTENCY_CONFLICT: Key % is already claimed by another user', p_idempotency_key;
            END IF;
        ELSE
            RAISE;
        END IF;
    END;

    -- 8. ترقية دور المستخدم في profiles
    UPDATE public.profiles SET role = 'retailer' WHERE id = v_user_id;

    -- 9. قيد سجل التدقيق الذري
    INSERT INTO public.retailer_audit_logs (
        retailer_id,
        action,
        actor_id,
        reason,
        ubtr,
        metadata
    ) VALUES (
        v_user_id,
        'REGISTERED',
        v_user_id,
        'تسجيل متجر تجزئة جديد',
        v_ubtr,
        jsonb_build_object(
            'store_name', p_store_name,
            'store_type', v_store_type,
            'city', p_city,
            'zone', p_zone,
            'idempotency_key', p_idempotency_key,
            'business_transaction_id', v_bt.business_transaction_id,
            'business_reference', v_bt.business_reference
        )
    );

    -- 10. الربط متعدد الأشكال مع Enterprise UBTR
    PERFORM public.link_business_transaction(
        v_bt.business_transaction_id,
        'RETAILER'::public.business_entity_type,
        'ORIGIN'::public.business_entity_role,
        v_user_id,
        v_code
    );

    RETURN jsonb_build_object(
        'success', true,
        'retailer_code', v_code,
        'status', 'pending_verification',
        'ubtr', v_ubtr,
        'is_idempotent_replay', false,
        'message', 'تم استلام طلب تسجيل متجر التجزئة بنجاح وهو قيد المراجعة الإدارية'
    );
END;
$$;

-- 8. دالة المراجعة والاعتماد الإداري RPC مع التحقق من State Machine و Enterprise UBTR
CREATE OR REPLACE FUNCTION public.admin_verify_retailer(
    p_retailer_id UUID,
    p_action TEXT, -- 'APPROVE', 'REJECT', 'SUSPEND', 'ACTIVATE', 'BLOCK'
    p_reason TEXT DEFAULT NULL,
    p_admin_idempotency_key VARCHAR(255) DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, extensions
AS $$
DECLARE
    v_admin_id UUID;
    v_admin_role user_role;
    v_old_status retailer_status;
    v_new_status retailer_status;
    v_code VARCHAR(20);
    v_key_uuid UUID;
    v_bt RECORD;
    v_ubtr VARCHAR(50);
BEGIN
    v_admin_id := auth.uid();
    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Admin session required';
    END IF;

    -- التحقق من صلاحية الإدارة
    SELECT role INTO v_admin_role FROM public.profiles WHERE id = v_admin_id;
    IF v_admin_role != 'admin' THEN
        RAISE EXCEPTION 'FORBIDDEN: Only administrators can verify retailers';
    END IF;

    -- فحص الحالة السابقة للتاجر
    SELECT status, retailer_code INTO v_old_status, v_code FROM public.retailers WHERE id = p_retailer_id;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'RETAILER_NOT_FOUND: Retailer record does not exist for %', p_retailer_id;
    END IF;

    -- تطبيق قواعد آلة الحالات الصارمة
    CASE UPPER(TRIM(p_action))
        WHEN 'APPROVE' THEN 
            IF v_old_status != 'pending_verification' THEN
                RAISE EXCEPTION 'INVALID_STATE_TRANSITION: Cannot APPROVE retailer from status % (must be pending_verification)', v_old_status;
            END IF;
            v_new_status := 'active'::retailer_status;

        WHEN 'ACTIVATE' THEN 
            IF v_old_status != 'suspended' THEN
                RAISE EXCEPTION 'INVALID_STATE_TRANSITION: Cannot ACTIVATE retailer from status % (must be suspended)', v_old_status;
            END IF;
            v_new_status := 'active'::retailer_status;

        WHEN 'REJECT' THEN 
            IF v_old_status != 'pending_verification' THEN
                RAISE EXCEPTION 'INVALID_STATE_TRANSITION: Cannot REJECT retailer from status % (must be pending_verification)', v_old_status;
            END IF;
            IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
                RAISE EXCEPTION 'REASON_REQUIRED: Rejection requires an explicit reason';
            END IF;
            v_new_status := 'rejected'::retailer_status;

        WHEN 'SUSPEND' THEN 
            IF v_old_status != 'active' THEN
                RAISE EXCEPTION 'INVALID_STATE_TRANSITION: Cannot SUSPEND retailer from status % (must be active)', v_old_status;
            END IF;
            v_new_status := 'suspended'::retailer_status;

        WHEN 'BLOCK' THEN 
            IF v_old_status = 'blocked' THEN
                RAISE EXCEPTION 'INVALID_STATE_TRANSITION: Retailer is already blocked';
            END IF;
            v_new_status := 'blocked'::retailer_status;

        ELSE RAISE EXCEPTION 'INVALID_ACTION: Action % is not supported', p_action;
    END CASE;

    -- إنشاء معاملة UBTR مركزية حقيقية للقرار الإداري
    v_key_uuid := md5('admin_verify:' || p_retailer_id::text || ':' || UPPER(TRIM(p_action)) || ':' || COALESCE(p_admin_idempotency_key, gen_random_uuid()::text))::uuid;

    SELECT * INTO v_bt
    FROM public.create_business_transaction(
        v_key_uuid,
        'ADMIN_VERIFICATION',
        'REGISTRATION'::public.business_category_enum,
        'RETAILER_STATE_TRANSITION',
        CASE WHEN v_new_status = 'active' THEN 'COMPLETED'::public.business_status_enum
             WHEN v_new_status = 'rejected' THEN 'FAILED'::public.business_status_enum
             ELSE 'PROCESSING'::public.business_status_enum END,
        'COMPLETED'::public.business_stage_enum,
        NULL,
        v_admin_id,
        NULL,
        NULL
    );

    v_ubtr := public._ubtr_display(v_bt.business_reference);

    -- تحديث السجل مع ثوابت البيانات الوصفية (Metadata Invariants)
    UPDATE public.retailers
    SET status = v_new_status,
        verified_at = CASE WHEN v_new_status = 'active' THEN NOW() ELSE verified_at END,
        verified_by = CASE WHEN v_new_status = 'active' THEN v_admin_id ELSE verified_by END,
        rejection_reason = CASE WHEN v_new_status = 'rejected' THEN p_reason ELSE NULL END,
        updated_at = NOW()
    WHERE id = p_retailer_id;

    -- قيد سجل التدقيق
    INSERT INTO public.retailer_audit_logs (
        retailer_id,
        action,
        actor_id,
        reason,
        ubtr,
        metadata
    ) VALUES (
        p_retailer_id,
        UPPER(TRIM(p_action)),
        v_admin_id,
        p_reason,
        v_ubtr,
        jsonb_build_object(
            'from_status', v_old_status,
            'to_status', v_new_status,
            'admin_id', v_admin_id,
            'business_transaction_id', v_bt.business_transaction_id,
            'business_reference', v_bt.business_reference
        )
    );

    -- ربط المعاملة الإدارية بـ Enterprise UBTR
    PERFORM public.link_business_transaction(
        v_bt.business_transaction_id,
        'RETAILER'::public.business_entity_type,
        'AUDIT'::public.business_entity_role,
        p_retailer_id,
        v_code
    );

    RETURN jsonb_build_object(
        'success', true,
        'retailer_id', p_retailer_id,
        'retailer_code', v_code,
        'old_status', v_old_status,
        'new_status', v_new_status,
        'ubtr', v_ubtr,
        'message', 'تم تحديث حالة متجر التجزئة بنجاح'
    );
END;
$$;

-- 9. تحديث دالة تريجر handle_new_user لدعم دور 'retailer' دون كسر أي مسار قديم
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  v_role user_role;
  v_phone TEXT;
BEGIN
  CASE COALESCE(new.raw_user_meta_data->>'role', 'customer')
    WHEN 'vendor' THEN v_role := 'vendor'::user_role;
    WHEN 'admin' THEN v_role := 'admin'::user_role;
    WHEN 'retailer' THEN v_role := 'retailer'::user_role;
    ELSE v_role := 'customer'::user_role;
  END CASE;

  v_phone := COALESCE(new.raw_user_meta_data->>'phone_number', new.phone);

  INSERT INTO public.profiles (id, name, phone_number, email, role)
  VALUES (
    new.id,
    COALESCE(new.raw_user_meta_data->>'full_name', 'مستخدم جديد'),
    v_phone,
    new.email,
    v_role
  )
  ON CONFLICT (id) DO UPDATE 
  SET name = EXCLUDED.name,
      phone_number = COALESCE(profiles.phone_number, EXCLUDED.phone_number),
      email = COALESCE(profiles.email, EXCLUDED.email);

  INSERT INTO public.wallets (user_id, balance)
  VALUES (new.id, 0.00)
  ON CONFLICT (user_id) DO NOTHING;

  RETURN new;
EXCEPTION WHEN OTHERS THEN
  RAISE WARNING 'Error in handle_new_user: %', SQLERRM;
  RETURN new;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, auth, extensions;

-- دوال الأمان المحددة الصلاحية (Security Definer Helpers) لمنع تعارض الصلاحيات في RLS
CREATE OR REPLACE FUNCTION public.is_wholesale_merchant(p_user_id uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.vendors 
    WHERE id = p_user_id AND vendor_type IN ('wholesale_merchant', 'hybrid')
  );
$$;

-- 10. عرض الدليل التجاري الآمن لتجار الجملة (Zero-PII Wholesale Directory Projection)
CREATE OR REPLACE VIEW public.retailer_wholesale_directory
WITH (security_invoker = false)
AS
SELECT 
    r.id,
    r.retailer_code,
    r.store_name,
    r.store_type,
    r.city,
    r.zone,
    r.status,
    r.created_at
FROM public.retailers r
WHERE r.status = 'active'
  AND (
      public.is_wholesale_merchant(auth.uid())
      OR
      public.is_admin(auth.uid())
  );

-- 11. سياسات الأمان Row-Level Security (RLS)
ALTER TABLE public.retailers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retailers FORCE ROW LEVEL SECURITY;
ALTER TABLE public.retailer_audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.retailer_audit_logs FORCE ROW LEVEL SECURITY;

-- سياسات جدول retailers الخام:
-- حجب تاجر الجملة عن الجدول الخام تماماً لحماية PII؛ يجب أن يستخدم View: retailer_wholesale_directory
DROP POLICY IF EXISTS "Retailers view self" ON public.retailers;
CREATE POLICY "Retailers view self"
    ON public.retailers FOR SELECT
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Wholesale merchants view active retailers" ON public.retailers;
-- تم حذف سياسة وصول تاجر الجملة إلى الجدول الخام لحظر تسريب البيانات الحساسة

DROP POLICY IF EXISTS "Admins manage all retailers" ON public.retailers;
CREATE POLICY "Admins manage all retailers"
    ON public.retailers FOR ALL
    USING (public.is_admin(auth.uid()));

-- سياسات جدول retailer_audit_logs
DROP POLICY IF EXISTS "Admins view audit logs" ON public.retailer_audit_logs;
CREATE POLICY "Admins view audit logs"
    ON public.retailer_audit_logs FOR SELECT
    USING (public.is_admin(auth.uid()));

DROP POLICY IF EXISTS "Retailers view own audit logs" ON public.retailer_audit_logs;
CREATE POLICY "Retailers view own audit logs"
    ON public.retailer_audit_logs FOR SELECT
    USING (auth.uid() = retailer_id);

-- الصلاحيات
GRANT SELECT, INSERT, UPDATE ON public.retailers TO authenticated;
GRANT SELECT ON public.retailers TO anon;
GRANT SELECT ON public.retailer_wholesale_directory TO authenticated, anon;
GRANT SELECT ON public.retailer_audit_logs TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.retailer_code_seq TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_wholesale_merchant(uuid) TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.is_admin(uuid) TO authenticated, anon;
