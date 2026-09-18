-- ====================================================================
-- Program R2: Wholesale Catalog, Offers & Tiered Pricing Architecture
-- File: 20260920000001_program_r2_wholesale_catalog_pricing.sql
-- Description:
--   1. Defines wholesale_package_status and wholesale_offer_status enums
--   2. Creates public.wholesale_catalog_products (Direct link to network_packages, Zero price duplication)
--   3. Creates public.wholesale_merchant_offers (MOQ, step_quantity, strict cost_floor_price)
--   4. Creates public.wholesale_offer_tiers (Monotonic volume discounts, Absolute Unit Price Model)
--   5. Implements mathematical integrity triggers:
--      - Single official retail price source verification (network_packages.price)
--      - Strict cost_floor <= wholesale_unit_price <= official_retail_price
--      - Monotonic non-increasing unit prices for volume tiers
--      - Immutability / Non-invalidating cost_floor update guard
--      - Strict currency matching across catalog, offer, and tiers
--   6. Implements read-only STABLE quote engine: calculate_wholesale_quote
--   7. Establishes Zero Price Leakage Row-Level Security (RLS) policies
-- ====================================================================

-- --------------------------------------------------------------------
-- 1. أنواع البيانات والـ Enums
-- --------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wholesale_package_status') THEN
        CREATE TYPE public.wholesale_package_status AS ENUM (
            'active',
            'inactive',
            'archived'
        );
    END IF;
END $$;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wholesale_offer_status') THEN
        CREATE TYPE public.wholesale_offer_status AS ENUM (
            'active',
            'paused',
            'archived'
        );
    END IF;
END $$;

-- --------------------------------------------------------------------
-- 2. جدول كتالوج باقات الجملة (Wholesale Catalog Products)
-- قاعدة المصدر الرسمي الموحد: لا يتم تكرار أو نسخ base_retail_price
-- --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wholesale_catalog_products (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    network_package_id UUID NOT NULL UNIQUE REFERENCES public.network_packages(id) ON DELETE RESTRICT,
    network_id UUID NOT NULL REFERENCES public.networks(id) ON DELETE RESTRICT,
    currency VARCHAR(3) NOT NULL DEFAULT 'YER',
    status public.wholesale_package_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_catalog_currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX IF NOT EXISTS idx_wholesale_catalog_network_id ON public.wholesale_catalog_products(network_id);
CREATE INDEX IF NOT EXISTS idx_wholesale_catalog_package_id ON public.wholesale_catalog_products(network_package_id);
CREATE INDEX IF NOT EXISTS idx_wholesale_catalog_status ON public.wholesale_catalog_products(status);

-- مشغل التحقق من صحة باقة الكتالوج والارتباط بالشبكة والسعر الرسمي
CREATE OR REPLACE FUNCTION public.fn_wholesale_catalog_products_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $$
DECLARE
    v_pkg_network_id UUID;
    v_pkg_price NUMERIC(10, 2);
    v_pkg_status public.package_status;
BEGIN
    -- استعلام الباقة الأصلية من المصدر الرسمي
    SELECT network_id, price, status
    INTO v_pkg_network_id, v_pkg_price, v_pkg_status
    FROM public.network_packages
    WHERE id = NEW.network_package_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFICIAL_PACKAGE_NOT_FOUND: network_package_id % does not exist', NEW.network_package_id;
    END IF;

    -- التحقق من تطابق الشبكة
    IF v_pkg_network_id IS DISTINCT FROM NEW.network_id THEN
        RAISE EXCEPTION 'NETWORK_MISMATCH: Package % does not belong to network %', NEW.network_package_id, NEW.network_id;
    END IF;

    -- التحقق الإلزامي من وجود سعر رسمي إيجابي في المصدر الرسمي
    IF v_pkg_price IS NULL OR v_pkg_price <= 0 THEN
        RAISE EXCEPTION 'INVALID_OFFICIAL_RETAIL_PRICE: Official retail price in network_packages must be strictly positive';
    END IF;

    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wholesale_catalog_products_validate ON public.wholesale_catalog_products;
CREATE TRIGGER trg_wholesale_catalog_products_validate
BEFORE INSERT OR UPDATE ON public.wholesale_catalog_products
FOR EACH ROW EXECUTE FUNCTION public.fn_wholesale_catalog_products_validate();

-- --------------------------------------------------------------------
-- 3. جدول عروض تجار الجملة المعتمدين (Wholesale Merchant Offers)
-- --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wholesale_merchant_offers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id UUID NOT NULL REFERENCES public.vendors(id) ON DELETE RESTRICT,
    catalog_product_id UUID NOT NULL REFERENCES public.wholesale_catalog_products(id) ON DELETE RESTRICT,
    min_order_quantity INT NOT NULL DEFAULT 10,
    max_order_quantity INT,
    step_quantity INT NOT NULL DEFAULT 10,
    cost_floor_price NUMERIC(15, 2) NOT NULL,
    currency VARCHAR(3) NOT NULL,
    status public.wholesale_offer_status NOT NULL DEFAULT 'active',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_merchant_catalog_product UNIQUE (merchant_id, catalog_product_id),
    CONSTRAINT chk_offer_moq CHECK (min_order_quantity >= 10),
    CONSTRAINT chk_offer_step CHECK (step_quantity >= 1),
    CONSTRAINT chk_offer_max_qty CHECK (max_order_quantity IS NULL OR max_order_quantity >= min_order_quantity),
    CONSTRAINT chk_offer_cost_floor_positive CHECK (cost_floor_price > 0),
    CONSTRAINT chk_offer_currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX IF NOT EXISTS idx_wholesale_offers_merchant_id ON public.wholesale_merchant_offers(merchant_id);
CREATE INDEX IF NOT EXISTS idx_wholesale_offers_catalog_product ON public.wholesale_merchant_offers(catalog_product_id);
CREATE INDEX IF NOT EXISTS idx_wholesale_offers_status ON public.wholesale_merchant_offers(status);

-- مشغل حوكمة عروض تجار الجملة وأرضية التكلفة
CREATE OR REPLACE FUNCTION public.fn_wholesale_merchant_offers_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $$
DECLARE
    v_is_wholesale BOOLEAN;
    v_catalog_currency VARCHAR(3);
    v_official_price NUMERIC(10, 2);
    v_min_existing_tier_price NUMERIC(15, 2);
BEGIN
    -- 1. التحقق من هوية تاجر الجملة عبر عقود R1
    v_is_wholesale := public.is_wholesale_merchant(NEW.merchant_id);
    IF v_is_wholesale IS NOT TRUE THEN
        RAISE EXCEPTION 'UNAUTHORIZED_MERCHANT: Vendor % is not an authorized wholesale merchant', NEW.merchant_id;
    END IF;

    -- 2. استعلام بيانات الكتالوج والمصدر الرسمي لسعر التجزئة
    SELECT cp.currency, np.price
    INTO v_catalog_currency, v_official_price
    FROM public.wholesale_catalog_products cp
    JOIN public.network_packages np ON np.id = cp.network_package_id
    WHERE cp.id = NEW.catalog_product_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'CATALOG_PRODUCT_NOT_FOUND: catalog_product_id % does not exist', NEW.catalog_product_id;
    END IF;

    -- 3. عزل العملة الصارم: تطابق عملة العرض مع الكتالوج
    IF NEW.currency IS DISTINCT FROM v_catalog_currency THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Offer currency % does not match catalog currency %', NEW.currency, v_catalog_currency;
    END IF;

    -- 4. قاعدة أرضية التكلفة: لا يمكن أن تتجاوز سعر التجزئة الرسمي
    IF NEW.cost_floor_price > v_official_price THEN
        RAISE EXCEPTION 'COST_FLOOR_EXCEEDS_RETAIL: Cost floor (%s) cannot exceed official retail price (%s)', NEW.cost_floor_price, v_official_price;
    END IF;

    -- 5. حظر التعديل غير الصالح (Non-Invalidating Update Guard):
    -- منع رفع cost_floor_price لدرجة تجعل أي شريحة حالية أقل من التكلفة
    IF TG_OP = 'UPDATE' AND NEW.cost_floor_price > OLD.cost_floor_price THEN
        SELECT MIN(unit_price) INTO v_min_existing_tier_price
        FROM public.wholesale_offer_tiers
        WHERE offer_id = NEW.id;

        IF v_min_existing_tier_price IS NOT NULL AND NEW.cost_floor_price > v_min_existing_tier_price THEN
            RAISE EXCEPTION 'INVALID_COST_FLOOR_UPDATE: New cost floor (%s) exceeds existing tier price (%s)', NEW.cost_floor_price, v_min_existing_tier_price;
        END IF;
    END IF;

    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wholesale_merchant_offers_validate ON public.wholesale_merchant_offers;
CREATE TRIGGER trg_wholesale_merchant_offers_validate
BEFORE INSERT OR UPDATE ON public.wholesale_merchant_offers
FOR EACH ROW EXECUTE FUNCTION public.fn_wholesale_merchant_offers_validate();

-- --------------------------------------------------------------------
-- 4. جدول شرائح تسعير الكميات (Wholesale Offer Tiers)
-- نموذج سعر الوحدة الصافي المطلق (Absolute Unit Price Model)
-- --------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wholesale_offer_tiers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    offer_id UUID NOT NULL REFERENCES public.wholesale_merchant_offers(id) ON DELETE CASCADE,
    min_quantity INT NOT NULL,
    max_quantity INT,
    unit_price NUMERIC(15, 2) NOT NULL,
    currency VARCHAR(3) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_tier_min_qty CHECK (min_quantity >= 1),
    CONSTRAINT chk_tier_max_qty CHECK (max_quantity IS NULL OR max_quantity >= min_quantity),
    CONSTRAINT chk_tier_unit_price_positive CHECK (unit_price > 0),
    CONSTRAINT chk_tier_currency_iso CHECK (currency ~ '^[A-Z]{3}$')
);

CREATE INDEX IF NOT EXISTS idx_wholesale_offer_tiers_offer_id ON public.wholesale_offer_tiers(offer_id);
CREATE INDEX IF NOT EXISTS idx_wholesale_offer_tiers_range ON public.wholesale_offer_tiers(offer_id, min_quantity, max_quantity);

-- مشغل الرتابة الرياضية والتدرج السعري التنازلي للكميات
CREATE OR REPLACE FUNCTION public.fn_wholesale_offer_tiers_validate()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $$
DECLARE
    v_offer RECORD;
    v_conflict RECORD;
BEGIN
    -- 1. جلب بيانات العرض وباقة الشبكة الرسمية
    SELECT o.*, np.price AS official_retail_price
    INTO v_offer
    FROM public.wholesale_merchant_offers o
    JOIN public.wholesale_catalog_products cp ON cp.id = o.catalog_product_id
    JOIN public.network_packages np ON np.id = cp.network_package_id
    WHERE o.id = NEW.offer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFER_NOT_FOUND: Offer % does not exist', NEW.offer_id;
    END IF;

    -- 2. التحقق من تكامل الشريحة مع الحد الأدنى للطلب (MOQ Invariant)
    IF NEW.min_quantity < v_offer.min_order_quantity THEN
        RAISE EXCEPTION 'TIER_MIN_BELOW_OFFER_MOQ: Tier min quantity (%s) cannot be lower than offer MOQ (%s)', NEW.min_quantity, v_offer.min_order_quantity;
    END IF;

    -- 3. عزل العملة: تطابق عملة الشريحة مع عملة العرض
    IF NEW.currency IS DISTINCT FROM v_offer.currency THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Tier currency % does not match offer currency %', NEW.currency, v_offer.currency;
    END IF;

    -- 4. التحقق من حدود التسعير الصارمة:
    -- cost_floor <= wholesale_unit_price <= official_retail_price
    IF NEW.unit_price < v_offer.cost_floor_price THEN
        RAISE EXCEPTION 'PRICE_BELOW_COST_FLOOR: Wholesale unit price (%s) cannot be lower than offer cost floor (%s)', NEW.unit_price, v_offer.cost_floor_price;
    END IF;

    IF NEW.unit_price > v_offer.official_retail_price THEN
        RAISE EXCEPTION 'PRICE_EXCEEDS_OFFICIAL_RETAIL: Wholesale unit price (%s) cannot exceed official retail price (%s)', NEW.unit_price, v_offer.official_retail_price;
    END IF;

    -- 5. قاعدة الترتيب والرتابة التنازلية للسعر (Strict Monotonic Non-Increasing Volume Pricing):
    -- أ. فحص الشرائح السابقة (كمية أقل): يجب أن يكون سعرها أعلى من أو مساوياً للشريحة الحالية
    FOR v_conflict IN
        SELECT min_quantity, unit_price
        FROM public.wholesale_offer_tiers
        WHERE offer_id = NEW.offer_id
          AND id IS DISTINCT FROM NEW.id
          AND min_quantity < NEW.min_quantity
    LOOP
        IF NEW.unit_price > v_conflict.unit_price THEN
            RAISE EXCEPTION 'MONOTONIC_TIER_VIOLATION: Higher quantity tier (qty >= %s, price %s) cannot be more expensive than lower tier (qty >= %s, price %s)',
                NEW.min_quantity, NEW.unit_price, v_conflict.min_quantity, v_conflict.unit_price;
        END IF;
    END LOOP;

    -- ب. فحص الشرائح اللاحقة (كمية أكبر): يجب أن يكون سعرها أقل من أو مساوياً للشريحة الحالية
    FOR v_conflict IN
        SELECT min_quantity, unit_price
        FROM public.wholesale_offer_tiers
        WHERE offer_id = NEW.offer_id
          AND id IS DISTINCT FROM NEW.id
          AND min_quantity > NEW.min_quantity
    LOOP
        IF NEW.unit_price < v_conflict.unit_price THEN
            RAISE EXCEPTION 'MONOTONIC_TIER_VIOLATION: Lower quantity tier (qty >= %s, price %s) cannot be cheaper than higher tier (qty >= %s, price %s)',
                NEW.min_quantity, NEW.unit_price, v_conflict.min_quantity, v_conflict.unit_price;
        END IF;
    END LOOP;

    -- 6. منع تداخل نطاقات الكميات لنفس العرض
    IF EXISTS (
        SELECT 1 FROM public.wholesale_offer_tiers
        WHERE offer_id = NEW.offer_id
          AND id IS DISTINCT FROM NEW.id
          AND (
              (NEW.max_quantity IS NOT NULL AND min_quantity <= NEW.max_quantity AND (max_quantity IS NULL OR max_quantity >= NEW.min_quantity))
              OR
              (NEW.max_quantity IS NULL AND (max_quantity IS NULL OR max_quantity >= NEW.min_quantity))
          )
    ) THEN
        RAISE EXCEPTION 'OVERLAPPING_TIER_RANGE: Tier quantity range overlaps with an existing tier for offer %', NEW.offer_id;
    END IF;

    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_wholesale_offer_tiers_validate ON public.wholesale_offer_tiers;
CREATE TRIGGER trg_wholesale_offer_tiers_validate
BEFORE INSERT OR UPDATE ON public.wholesale_offer_tiers
FOR EACH ROW EXECUTE FUNCTION public.fn_wholesale_offer_tiers_validate();

-- --------------------------------------------------------------------
-- 5. محرك عروض الأسعار للقراءة فقط (Read-Only Quote Engine)
-- calculate_wholesale_quote(p_offer_id UUID, p_quantity INT)
-- --------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calculate_wholesale_quote(
    p_offer_id UUID,
    p_quantity INT
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'extensions'
AS $$
DECLARE
    v_caller_id UUID;
    v_is_active_retailer BOOLEAN := false;
    v_is_authorized_merchant BOOLEAN := false;
    v_is_admin BOOLEAN := false;

    v_offer RECORD;
    v_tier RECORD;
    v_official_retail_price NUMERIC(10, 2);
    v_total_wholesale NUMERIC(15, 2);
    v_total_retail NUMERIC(15, 2);
    v_margin_amount NUMERIC(15, 2);
    v_margin_pct NUMERIC(5, 2);
BEGIN
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Authentication required to calculate wholesale quote';
    END IF;

    -- فحص صلاحيات المستدعي: تاجر تجزئة نشط، تاجر جملة صاحب العرض، أو مدير نظام
    SELECT EXISTS (
        SELECT 1 FROM public.retailers 
        WHERE id = v_caller_id AND status = 'active'
    ) INTO v_is_active_retailer;

    SELECT (role = 'admin') INTO v_is_admin
    FROM public.profiles
    WHERE id = v_caller_id;

    -- 1. استعلام العرض والتحقق من حالته
    SELECT o.*, cp.status AS catalog_status, cp.currency AS catalog_currency, cp.network_package_id, cp.network_id
    INTO v_offer
    FROM public.wholesale_merchant_offers o
    JOIN public.wholesale_catalog_products cp ON cp.id = o.catalog_product_id
    WHERE o.id = p_offer_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'OFFER_NOT_FOUND: Offer % does not exist', p_offer_id;
    END IF;

    -- التحقق مما إذا كان المستدعي هو تاجر الجملة صاحب العرض
    IF v_caller_id = v_offer.merchant_id THEN
        v_is_authorized_merchant := true;
    END IF;

    IF NOT (v_is_active_retailer OR v_is_authorized_merchant OR COALESCE(v_is_admin, false)) THEN
        RAISE EXCEPTION 'FORBIDDEN_OR_INACTIVE_RETAILER: Wholesale pricing is exclusively accessible to active retailers or authorized merchants';
    END IF;

    -- 2. التحقق من نشاط العرض وباقة الكتالوج
    IF v_offer.status != 'active' THEN
        RAISE EXCEPTION 'OFFER_NOT_ACTIVE: Offer is currently %', v_offer.status;
    END IF;
    IF v_offer.catalog_status != 'active' THEN
        RAISE EXCEPTION 'CATALOG_PRODUCT_NOT_ACTIVE: Catalog product is currently %', v_offer.catalog_status;
    END IF;

    -- 3. التحقق من الحد الأدنى للطلب (MOQ Guard)
    IF p_quantity < v_offer.min_order_quantity THEN
        RAISE EXCEPTION 'ORDER_QUANTITY_BELOW_MOQ: Requested quantity (%s) is below minimum order quantity (%s)', p_quantity, v_offer.min_order_quantity;
    END IF;

    -- 4. التحقق من مضاعفات الخطوة (Step Quantity Guard)
    IF ((p_quantity - v_offer.min_order_quantity) % v_offer.step_quantity) != 0 THEN
        RAISE EXCEPTION 'INVALID_QUANTITY_STEP: Requested quantity (%s) does not match step quantity (%s) from MOQ (%s)', p_quantity, v_offer.step_quantity, v_offer.min_order_quantity;
    END IF;

    -- 5. التحقق من الحد الأقصى (إن وجد)
    IF v_offer.max_order_quantity IS NOT NULL AND p_quantity > v_offer.max_order_quantity THEN
        RAISE EXCEPTION 'ORDER_QUANTITY_EXCEEDS_MAX: Requested quantity (%s) exceeds maximum order quantity (%s)', p_quantity, v_offer.max_order_quantity;
    END IF;

    -- 6. استخراج السعر الرسمي مباشرة من المصدر الرسمي network_packages
    SELECT price INTO v_official_retail_price
    FROM public.network_packages
    WHERE id = v_offer.network_package_id;

    IF v_official_retail_price IS NULL OR v_official_retail_price <= 0 THEN
        RAISE EXCEPTION 'OFFICIAL_RETAIL_PRICE_UNAVAILABLE: Official price in network_packages is missing or invalid';
    END IF;

    -- 7. اختيار أنسب شريحة سعرية مطابقة للكمية
    SELECT * INTO v_tier
    FROM public.wholesale_offer_tiers
    WHERE offer_id = p_offer_id
      AND p_quantity >= min_quantity
      AND (max_quantity IS NULL OR p_quantity <= max_quantity)
    ORDER BY min_quantity DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'NO_MATCHING_TIER: No pricing tier configured for quantity %', p_quantity;
    END IF;

    -- 8. عزل العملة: تأكيد تطابق العملات وعدم وجود تحويل
    IF v_tier.currency IS DISTINCT FROM v_offer.currency THEN
        RAISE EXCEPTION 'CURRENCY_MISMATCH: Tier currency does not match offer currency';
    END IF;

    -- 9. الحسابات المالية (صافية قبل الضريبة)
    v_total_wholesale := ROUND((p_quantity * v_tier.unit_price)::numeric, 2);
    v_total_retail := ROUND((p_quantity * v_official_retail_price)::numeric, 2);
    v_margin_amount := v_total_retail - v_total_wholesale;
    v_margin_pct := ROUND(((v_margin_amount / v_total_retail) * 100.0)::numeric, 2);

    -- 10. إرجاع كائن JSON منظم
    RETURN jsonb_build_object(
        'success', true,
        'offer_id', v_offer.id,
        'catalog_product_id', v_offer.catalog_product_id,
        'network_id', v_offer.network_id,
        'quantity', p_quantity,
        'unit_price', v_tier.unit_price,
        'currency', v_offer.currency,
        'official_retail_price', v_official_retail_price,
        'cost_floor_price', v_offer.cost_floor_price,
        'total_wholesale_price', v_total_wholesale,
        'total_retail_value', v_total_retail,
        'retailer_margin_amount', v_margin_amount,
        'retailer_margin_percentage', v_margin_pct,
        'tier_id', v_tier.id
    );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_wholesale_quote(UUID, INT) TO authenticated, anon;

-- --------------------------------------------------------------------
-- 6. سياسات الأمان ومنع تسريب الأسعار (Zero Price Leakage RLS)
-- --------------------------------------------------------------------
ALTER TABLE public.wholesale_catalog_products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wholesale_catalog_products FORCE ROW LEVEL SECURITY;

ALTER TABLE public.wholesale_merchant_offers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wholesale_merchant_offers FORCE ROW LEVEL SECURITY;

ALTER TABLE public.wholesale_offer_tiers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wholesale_offer_tiers FORCE ROW LEVEL SECURITY;

-- 6.1 سياسات الكتالوج: wholesale_catalog_products
DROP POLICY IF EXISTS "rls_wholesale_catalog_select" ON public.wholesale_catalog_products;
CREATE POLICY "rls_wholesale_catalog_select"
ON public.wholesale_catalog_products FOR SELECT
USING (
    auth.uid() IS NOT NULL
    AND (
        -- تجار التجزئة النشطون فقط
        (status = 'active' AND EXISTS (SELECT 1 FROM public.retailers WHERE id = auth.uid() AND status = 'active'))
        OR
        -- تجار الجملة المعتمدون
        public.is_wholesale_merchant(auth.uid())
        OR
        -- مالك الشبكة
        EXISTS (
            SELECT 1 FROM public.networks n
            WHERE n.id = wholesale_catalog_products.network_id
              AND (n.vendor_id = auth.uid() OR EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = n.vendor_id AND (v.profile_id = auth.uid() OR v.id = auth.uid())))
        )
        OR
        -- مدير النظام
        public.is_admin(auth.uid())
    )
);

DROP POLICY IF EXISTS "rls_wholesale_catalog_admin_all" ON public.wholesale_catalog_products;
CREATE POLICY "rls_wholesale_catalog_admin_all"
ON public.wholesale_catalog_products FOR ALL
USING (public.is_admin(auth.uid()))
WITH CHECK (public.is_admin(auth.uid()));

-- 6.2 سياسات العروض: wholesale_merchant_offers
DROP POLICY IF EXISTS "rls_wholesale_offers_select" ON public.wholesale_merchant_offers;
CREATE POLICY "rls_wholesale_offers_select"
ON public.wholesale_merchant_offers FOR SELECT
USING (
    auth.uid() IS NOT NULL
    AND (
        -- تجار التجزئة النشطون: يرون العروض النشطة فقط
        (status = 'active' AND EXISTS (SELECT 1 FROM public.retailers WHERE id = auth.uid() AND status = 'active'))
        OR
        -- تاجر الجملة يرى عروضه الخاصة فقط
        (merchant_id = auth.uid() AND public.is_wholesale_merchant(auth.uid()))
        OR
        -- مالك الشبكة يرى عروض شبكته
        EXISTS (
            SELECT 1 FROM public.wholesale_catalog_products cp
            JOIN public.networks n ON n.id = cp.network_id
            WHERE cp.id = wholesale_merchant_offers.catalog_product_id
              AND (n.vendor_id = auth.uid() OR EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = n.vendor_id AND (v.profile_id = auth.uid() OR v.id = auth.uid())))
        )
        OR
        -- مدير النظام
        public.is_admin(auth.uid())
    )
);

DROP POLICY IF EXISTS "rls_wholesale_offers_merchant_write" ON public.wholesale_merchant_offers;
CREATE POLICY "rls_wholesale_offers_merchant_write"
ON public.wholesale_merchant_offers FOR ALL
USING (
    (merchant_id = auth.uid() AND public.is_wholesale_merchant(auth.uid()))
    OR
    public.is_admin(auth.uid())
)
WITH CHECK (
    (merchant_id = auth.uid() AND public.is_wholesale_merchant(auth.uid()))
    OR
    public.is_admin(auth.uid())
);

-- 6.3 سياسات الشرائح: wholesale_offer_tiers
DROP POLICY IF EXISTS "rls_wholesale_tiers_select" ON public.wholesale_offer_tiers;
CREATE POLICY "rls_wholesale_tiers_select"
ON public.wholesale_offer_tiers FOR SELECT
USING (
    auth.uid() IS NOT NULL
    AND (
        -- تجار التجزئة النشطون: يرون شرائح العروض النشطة فقط
        EXISTS (
            SELECT 1 FROM public.wholesale_merchant_offers o
            WHERE o.id = wholesale_offer_tiers.offer_id
              AND o.status = 'active'
              AND EXISTS (SELECT 1 FROM public.retailers r WHERE r.id = auth.uid() AND r.status = 'active')
        )
        OR
        -- تاجر الجملة يرى شرائح عروضه الخاصة
        EXISTS (
            SELECT 1 FROM public.wholesale_merchant_offers o
            WHERE o.id = wholesale_offer_tiers.offer_id
              AND o.merchant_id = auth.uid()
              AND public.is_wholesale_merchant(auth.uid())
        )
        OR
        -- مالك الشبكة
        EXISTS (
            SELECT 1 FROM public.wholesale_merchant_offers o
            JOIN public.wholesale_catalog_products cp ON cp.id = o.catalog_product_id
            JOIN public.networks n ON n.id = cp.network_id
            WHERE o.id = wholesale_offer_tiers.offer_id
              AND (n.vendor_id = auth.uid() OR EXISTS (SELECT 1 FROM public.vendors v WHERE v.id = n.vendor_id AND (v.profile_id = auth.uid() OR v.id = auth.uid())))
        )
        OR
        -- مدير النظام
        public.is_admin(auth.uid())
    )
);

DROP POLICY IF EXISTS "rls_wholesale_tiers_merchant_write" ON public.wholesale_offer_tiers;
CREATE POLICY "rls_wholesale_tiers_merchant_write"
ON public.wholesale_offer_tiers FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM public.wholesale_merchant_offers o
        WHERE o.id = wholesale_offer_tiers.offer_id
          AND o.merchant_id = auth.uid()
          AND public.is_wholesale_merchant(auth.uid())
    )
    OR
    public.is_admin(auth.uid())
)
WITH CHECK (
    EXISTS (
        SELECT 1 FROM public.wholesale_merchant_offers o
        WHERE o.id = wholesale_offer_tiers.offer_id
          AND o.merchant_id = auth.uid()
          AND public.is_wholesale_merchant(auth.uid())
    )
    OR
    public.is_admin(auth.uid())
);

-- --------------------------------------------------------------------
-- 7. الصلاحيات (Role Grants)
-- --------------------------------------------------------------------
GRANT SELECT ON public.networks, public.network_packages, public.vendors TO authenticated, anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.wholesale_catalog_products TO authenticated, service_role;
GRANT SELECT ON public.wholesale_catalog_products TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.wholesale_merchant_offers TO authenticated, service_role;
GRANT SELECT ON public.wholesale_merchant_offers TO anon;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.wholesale_offer_tiers TO authenticated, service_role;
GRANT SELECT ON public.wholesale_offer_tiers TO anon;
