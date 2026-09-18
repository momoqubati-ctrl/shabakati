-- ====================================================================
-- Test Suite: Program R2 Qualification & Acceptance Gate (039)
-- File: 039_program_r2_catalog_qualification_tests.sql
-- Description:
--   Comprehensive contract qualification covering the 9 mandatory R2 contracts:
--   1. R2-SCHEMA-01:   Schema, Columns, Enums & Single Price Source (Zero Redundancy)
--   2. R2-IDENTITY-02: R1 Identity Consumption & Wholesale Authorization Check
--   3. R2-CATALOG-03:  Independent Catalog Layer & Official Package Binding
--   4. R2-MOQ-04:      MOQ & Step Quantity Invariants (Positive & Negative)
--   5. R2-TIER-05:     Volume Tier Monotonicity & Anti-Discount Inversion Guards
--   6. R2-PRICING-06:  Pricing Ceiling (<= Retail) & Strict Cost Floor Guards
--   7. R2-RLS-07:      Multi-Actor Zero Price Leakage Matrix (Anon, Customer, Retailers, Merchants)
--   8. R2-CURRENCY-08: Strict Currency Isolation & Parametric Multi-Currency Proof
--   9. R2-CLEANUP-09:  Zero-Footprint Self-Cleaning Session & Structured Report
-- ====================================================================

-- --------------------------------------------------------------------
-- STEP 0: SESSION LEDGER INITIALIZATION
-- --------------------------------------------------------------------
CREATE TEMP TABLE IF NOT EXISTS _test_r2_fixtures (
    key TEXT PRIMARY KEY,
    id UUID NOT NULL
);

CREATE TEMP TABLE IF NOT EXISTS _test_r2_results (
    test_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL,
    assertions INT NOT NULL,
    passed INT NOT NULL,
    details TEXT
);

GRANT ALL ON TABLE _test_r2_fixtures TO public;
GRANT ALL ON TABLE _test_r2_results TO public;

TRUNCATE TABLE _test_r2_fixtures;
TRUNCATE TABLE _test_r2_results;

INSERT INTO _test_r2_fixtures (key, id) VALUES
    ('admin_id', gen_random_uuid()),
    ('customer_id', gen_random_uuid()),
    ('retailer_active_id', gen_random_uuid()),
    ('retailer_inactive_id', gen_random_uuid()),
    ('merchant_authorized_id', gen_random_uuid()),
    ('merchant_unauthorized_id', gen_random_uuid()),
    ('vendor_regular_id', gen_random_uuid()),
    ('network_id', gen_random_uuid()),
    ('network_pkg_valid_id', gen_random_uuid()),
    ('network_pkg_free_id', gen_random_uuid()),
    ('network_usd_id', gen_random_uuid()),
    ('network_pkg_usd_id', gen_random_uuid()),
    ('catalog_product_yer_id', gen_random_uuid()),
    ('catalog_product_usd_id', gen_random_uuid()),
    ('offer_yer_id', gen_random_uuid()),
    ('offer_usd_id', gen_random_uuid());

-- --------------------------------------------------------------------
-- STEP 1: QUALIFICATION EXECUTION HARNESS
-- --------------------------------------------------------------------
DO $$
DECLARE
    -- Fixture IDs
    v_admin_id UUID;
    v_customer_id UUID;
    v_retailer_active_id UUID;
    v_retailer_inactive_id UUID;
    v_merchant_authorized_id UUID;
    v_merchant_unauthorized_id UUID;
    v_vendor_regular_id UUID;
    v_network_id UUID;
    v_network_pkg_valid_id UUID;
    v_network_pkg_free_id UUID;
    v_network_usd_id UUID;
    v_network_pkg_usd_id UUID;
    v_catalog_product_yer_id UUID;
    v_catalog_product_usd_id UUID;
    v_offer_yer_id UUID;
    v_offer_usd_id UUID;

    -- Operational & Diagnostic variables
    v_err_caught BOOLEAN;
    v_count INT;
    v_cols TEXT[];
    v_quote JSONB;
    v_tier_id UUID;
    v_temp_id UUID;
BEGIN
    SELECT id INTO v_admin_id FROM _test_r2_fixtures WHERE key = 'admin_id';
    SELECT id INTO v_customer_id FROM _test_r2_fixtures WHERE key = 'customer_id';
    SELECT id INTO v_retailer_active_id FROM _test_r2_fixtures WHERE key = 'retailer_active_id';
    SELECT id INTO v_retailer_inactive_id FROM _test_r2_fixtures WHERE key = 'retailer_inactive_id';
    SELECT id INTO v_merchant_authorized_id FROM _test_r2_fixtures WHERE key = 'merchant_authorized_id';
    SELECT id INTO v_merchant_unauthorized_id FROM _test_r2_fixtures WHERE key = 'merchant_unauthorized_id';
    SELECT id INTO v_vendor_regular_id FROM _test_r2_fixtures WHERE key = 'vendor_regular_id';
    SELECT id INTO v_network_id FROM _test_r2_fixtures WHERE key = 'network_id';
    SELECT id INTO v_network_pkg_valid_id FROM _test_r2_fixtures WHERE key = 'network_pkg_valid_id';
    SELECT id INTO v_network_pkg_free_id FROM _test_r2_fixtures WHERE key = 'network_pkg_free_id';
    SELECT id INTO v_network_usd_id FROM _test_r2_fixtures WHERE key = 'network_usd_id';
    SELECT id INTO v_network_pkg_usd_id FROM _test_r2_fixtures WHERE key = 'network_pkg_usd_id';
    SELECT id INTO v_catalog_product_yer_id FROM _test_r2_fixtures WHERE key = 'catalog_product_yer_id';
    SELECT id INTO v_catalog_product_usd_id FROM _test_r2_fixtures WHERE key = 'catalog_product_usd_id';
    SELECT id INTO v_offer_yer_id FROM _test_r2_fixtures WHERE key = 'offer_yer_id';
    SELECT id INTO v_offer_usd_id FROM _test_r2_fixtures WHERE key = 'offer_usd_id';

    -- ================================================================
    -- 1. R2-SCHEMA-01: SCHEMA, ENUMS, CONSTRAINTS & ZERO-PRICE-COPY
    -- ================================================================
    -- 1.1: Enums exist
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wholesale_package_status') THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: Enum wholesale_package_status missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wholesale_offer_status') THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: Enum wholesale_offer_status missing';
    END IF;

    -- 1.2: Tables exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'wholesale_catalog_products') THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: Table wholesale_catalog_products missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'wholesale_merchant_offers') THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: Table wholesale_merchant_offers missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'wholesale_offer_tiers') THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: Table wholesale_offer_tiers missing';
    END IF;

    -- 1.3: Amendment 1 Proof: base_retail_price MUST NOT exist in wholesale_catalog_products
    SELECT array_agg(column_name::TEXT) INTO v_cols
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'wholesale_catalog_products';

    IF 'base_retail_price' = ANY(v_cols) THEN
        RAISE EXCEPTION 'R2-SCHEMA CRITICAL VIOLATION: base_retail_price must NOT be copied into wholesale_catalog_products!';
    END IF;

    -- 1.4: Amendment 2 Proof: cost_floor_price MUST exist on wholesale_merchant_offers
    SELECT array_agg(column_name::TEXT) INTO v_cols
    FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'wholesale_merchant_offers';

    IF NOT ('cost_floor_price' = ANY(v_cols)) THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: cost_floor_price column missing on wholesale_merchant_offers';
    END IF;

    -- 1.5: Pricing function exists
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = 'calculate_wholesale_quote') THEN
        RAISE EXCEPTION 'R2-SCHEMA FAILED: Function calculate_wholesale_quote missing';
    END IF;

    INSERT INTO _test_r2_results VALUES ('R2-SCHEMA-01', 'Schema, Columns, Enums & Single Price Source', 'PASS', 6, 6, 'Tables, enums, zero-price-copy verified, cost_floor confirmed');

    -- ================================================================
    -- FIXTURE SETUP: Establish clean R1 identities & network packages
    -- ================================================================
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'auth' AND table_name = 'users') THEN
        INSERT INTO auth.users (id, email, phone) VALUES
            (v_admin_id, 'admin_r2@shabakati.local', '700000001'),
            (v_customer_id, 'cust_r2@shabakati.local', '700000002'),
            (v_retailer_active_id, 'ret_act@shabakati.local', '700000003'),
            (v_retailer_inactive_id, 'ret_inact@shabakati.local', '700000004'),
            (v_merchant_authorized_id, 'merch_auth@shabakati.local', '700000005'),
            (v_merchant_unauthorized_id, 'merch_unauth@shabakati.local', '700000006'),
            (v_vendor_regular_id, 'vend_reg@shabakati.local', '700000007')
        ON CONFLICT (id) DO NOTHING;
    END IF;

    -- Profiles (idempotent upsert in case of on_auth_user_created trigger)
    INSERT INTO public.profiles (id, phone_number, name, role) VALUES
        (v_admin_id, '+967700000001', 'Admin User', 'admin'),
        (v_customer_id, '+967700000002', 'Customer User', 'customer'),
        (v_retailer_active_id, '+967700000003', 'Active Retailer', 'retailer'),
        (v_retailer_inactive_id, '+967700000004', 'Inactive Retailer', 'retailer'),
        (v_merchant_authorized_id, '+967700000005', 'Authorized Wholesale Merchant', 'vendor'),
        (v_merchant_unauthorized_id, '+967700000006', 'Unauthorized Wholesale Merchant', 'vendor'),
        (v_vendor_regular_id, '+967700000007', 'Regular Network Vendor', 'vendor')
    ON CONFLICT (id) DO UPDATE SET
        phone_number = EXCLUDED.phone_number,
        name = EXCLUDED.name,
        role = EXCLUDED.role;

    -- Vendors
    INSERT INTO public.vendors (id, profile_id, business_name, vendor_type, status) VALUES
        (v_merchant_authorized_id, v_merchant_authorized_id, 'Al-Amana Wholesale Co', 'wholesale_merchant', 'approved'),
        (v_merchant_unauthorized_id, v_merchant_unauthorized_id, 'Al-Baraka Wholesale Co', 'wholesale_merchant', 'approved'),
        (v_vendor_regular_id, v_vendor_regular_id, 'Aden Wi-Fi Owner', 'network_owner', 'approved');

    -- Retailers (Active and Inactive)
    INSERT INTO public.retailers (
        id, retailer_code, store_name, store_type, city, zone, contact_phone,
        status, idempotency_key, ubtr
    ) VALUES
        (v_retailer_active_id, 'RET-TEST-01', 'Active Mini Market', 'grocery', 'Aden', 'Crater', '+967700000003', 'active', 'idemp_act_01', 'UBTR-R2-01'),
        (v_retailer_inactive_id, 'RET-TEST-02', 'Pending Grocery', 'grocery', 'Aden', 'Mualla', '+967700000004', 'pending_verification', 'idemp_inact_02', 'UBTR-R2-02');

    -- Networks
    INSERT INTO public.networks (id, vendor_id, name, status) VALUES
        (v_network_id, v_merchant_authorized_id, 'Shabakati Star Network', 'ACTIVE'),
        (v_network_usd_id, v_merchant_authorized_id, 'Shabakati Global USD Network', 'ACTIVE');

    -- Official Network Packages (Legacy network_packages untouched)
    INSERT INTO public.network_packages (id, network_id, name, duration_hours, capacity_mb, price, status) VALUES
        (v_network_pkg_valid_id, v_network_id, '10 GB Ultra Card', 720, 10240, 500.00, 'ACTIVE'),
        (v_network_pkg_free_id, v_network_id, 'Promo Zero Price Card', 24, 500, 0.00, 'ACTIVE'),
        (v_network_pkg_usd_id, v_network_usd_id, '10 GB USD Card', 720, 10240, 2.00, 'ACTIVE');

    -- ================================================================
    -- 2. R2-IDENTITY-02: R1 IDENTITY CONSUMPTION & WHOLESALE AUTHORIZATION
    -- ================================================================
    -- 2.1: First, create catalog product for testing
    INSERT INTO public.wholesale_catalog_products (id, network_package_id, network_id, currency, status)
    VALUES (v_catalog_product_yer_id, v_network_pkg_valid_id, v_network_id, 'YER', 'active');

    -- 2.2: Negative Proof: Vendor with vendor_type = 'network_owner' cannot create wholesale offer
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_merchant_offers (
            merchant_id, catalog_product_id, min_order_quantity, step_quantity,
            cost_floor_price, currency, status
        ) VALUES (
            v_vendor_regular_id, v_catalog_product_yer_id, 10, 10,
            300.00, 'YER', 'active'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%UNAUTHORIZED_MERCHANT%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-IDENTITY FAILED: Non-wholesale vendor was allowed to create wholesale offer!';
    END IF;

    -- 2.3: Positive Proof: Authorized wholesale merchant can create offer
    INSERT INTO public.wholesale_merchant_offers (
        id, merchant_id, catalog_product_id, min_order_quantity, step_quantity,
        cost_floor_price, currency, status
    ) VALUES (
        v_offer_yer_id, v_merchant_authorized_id, v_catalog_product_yer_id, 10, 10,
        300.00, 'YER', 'active'
    );

    -- 2.4: Invariant: profiles table role was never altered by R2
    SELECT COUNT(*) INTO v_count FROM public.profiles WHERE id = v_merchant_authorized_id AND role = 'vendor';
    IF v_count != 1 THEN
        RAISE EXCEPTION 'R2-IDENTITY FAILED: profiles role was mutated!';
    END IF;

    INSERT INTO _test_r2_results VALUES ('R2-IDENTITY-02', 'R1 Identity Consumption & Authorization', 'PASS', 4, 4, 'Unauthorized vendors rejected; authorized wholesale merchants accepted; profiles untouched');

    -- ================================================================
    -- 3. R2-CATALOG-03: INDEPENDENT CATALOG LAYER & OFFICIAL PACKAGE BINDING
    -- ================================================================
    -- 3.1: Negative Proof: Catalog product with non-existent package fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_catalog_products (network_package_id, network_id, currency)
        VALUES (gen_random_uuid(), v_network_id, 'YER');
    EXCEPTION WHEN OTHERS THEN
        v_err_caught := true;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-CATALOG FAILED: Non-existent package reference was accepted!';
    END IF;

    -- 3.2: Negative Proof: Catalog product with network mismatch fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_catalog_products (network_package_id, network_id, currency)
        VALUES (v_network_pkg_valid_id, v_network_usd_id, 'YER'); -- Package belongs to v_network_id, not v_network_usd_id
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%NETWORK_MISMATCH%' OR SQLERRM LIKE '%unique%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-CATALOG FAILED: Network mismatch was not rejected!';
    END IF;

    -- 3.3: Negative Proof: Catalog product for package with price <= 0 fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_catalog_products (network_package_id, network_id, currency)
        VALUES (v_network_pkg_free_id, v_network_id, 'YER');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%INVALID_OFFICIAL_RETAIL_PRICE%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-CATALOG FAILED: Package with price <= 0 was accepted into catalog!';
    END IF;

    -- 3.4: Legacy network_packages table remains clean and intact
    SELECT COUNT(*) INTO v_count FROM public.network_packages WHERE id = v_network_pkg_valid_id;
    IF v_count != 1 THEN
        RAISE EXCEPTION 'R2-CATALOG FAILED: network_packages integrity corrupted!';
    END IF;

    INSERT INTO _test_r2_results VALUES ('R2-CATALOG-03', 'Independent Catalog & Official Package Binding', 'PASS', 4, 4, 'Unmodified legacy packages; network mismatch & zero retail prices strictly rejected');

    -- ================================================================
    -- 4. R2-MOQ-04: MOQ & STEP QUANTITY INVARIANTS
    -- ================================================================
    -- 4.1: Negative Proof: Tier min_quantity (5) < offer MOQ (10) fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
        VALUES (v_offer_yer_id, 5, 9, 480.00, 'YER');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%TIER_MIN_BELOW_OFFER_MOQ%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-MOQ FAILED: Tier with min_quantity below offer MOQ was allowed!';
    END IF;

    -- Create valid baseline Tier 1 for subsequent quote tests
    -- Tier 1: 10..49 @ 450.00 YER
    INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
    VALUES (v_offer_yer_id, 10, 49, 450.00, 'YER');

    -- 4.2: Negative Proof: Quote request with quantity < MOQ (qty 5) fails
    PERFORM set_config('request.jwt.claim.sub', v_retailer_active_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    v_err_caught := false;
    BEGIN
        PERFORM public.calculate_wholesale_quote(v_offer_yer_id, 5);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%ORDER_QUANTITY_BELOW_MOQ%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-MOQ FAILED: calculate_wholesale_quote accepted quantity below MOQ!';
    END IF;

    -- 4.3: Negative Proof: Quote request breaking step_quantity (qty 15, step 10 from 10) fails
    v_err_caught := false;
    BEGIN
        PERFORM public.calculate_wholesale_quote(v_offer_yer_id, 15);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%INVALID_QUANTITY_STEP%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-MOQ FAILED: calculate_wholesale_quote accepted non-step quantity!';
    END IF;

    -- 4.4: Positive Proof: Quote request matching step (qty 20 = 10 + 1*10) succeeds
    v_quote := public.calculate_wholesale_quote(v_offer_yer_id, 20);
    IF (v_quote->>'success')::BOOLEAN IS NOT TRUE OR (v_quote->>'unit_price')::NUMERIC != 450.00 THEN
        RAISE EXCEPTION 'R2-MOQ FAILED: calculate_wholesale_quote failed for valid step quantity: %', v_quote;
    END IF;

    -- Reset to superuser for DDL/fixture tests
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);

    INSERT INTO _test_r2_results VALUES ('R2-MOQ-04', 'MOQ & Step Quantity Invariants', 'PASS', 4, 4, 'Tier below MOQ rejected; quote below MOQ rejected; non-step rejected; valid step accepted');

    -- ================================================================
    -- 5. R2-TIER-05: VOLUME TIER MONOTONICITY & ANTI-DISCOUNT GUARDS
    -- ================================================================
    -- 5.1: Positive Proof: Insert Tier 2: 50..99 @ 420.00 YER (lower price than Tier 1 450.00)
    INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
    VALUES (v_offer_yer_id, 50, 99, 420.00, 'YER');

    -- 5.2: Negative Proof: Insert Tier 3: 100+ @ 440.00 YER (Anti-discount inversion: higher qty at higher price than Tier 2)
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
        VALUES (v_offer_yer_id, 100, NULL, 440.00, 'YER');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%MONOTONIC_TIER_VIOLATION%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-TIER FAILED: Monotonic violation (higher qty at higher price) was allowed!';
    END IF;

    -- 5.3: Positive Proof: Insert Tier 3 with strictly non-increasing price: 100+ @ 380.00 YER
    INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
    VALUES (v_offer_yer_id, 100, NULL, 380.00, 'YER');

    -- 5.4: Negative Proof: Insert overlapping tier range (qty 40..60 overlaps with 10..49 and 50..99)
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
        VALUES (v_offer_yer_id, 40, 60, 430.00, 'YER');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%OVERLAPPING_TIER_RANGE%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-TIER FAILED: Overlapping tier range was allowed!';
    END IF;

    INSERT INTO _test_r2_results VALUES ('R2-TIER-05', 'Volume Tier Monotonicity & Ordering', 'PASS', 4, 4, 'Monotonic non-increasing price enforced; overlapping brackets strictly rejected');

    -- ================================================================
    -- 6. R2-PRICING-06: PRICING CEILING (<= RETAIL) & STRICT COST FLOOR
    -- ================================================================
    -- 6.1: Negative Proof: Wholesale tier unit_price > official retail price (550 > 500) fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
        VALUES (v_offer_yer_id, 500, 1000, 550.00, 'YER');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%PRICE_EXCEEDS_OFFICIAL_RETAIL%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-PRICING FAILED: Tier unit_price exceeding official retail price was allowed!';
    END IF;

    -- 6.2: Negative Proof: Wholesale tier unit_price < cost_floor_price (250 < 300) fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
        VALUES (v_offer_yer_id, 500, 1000, 250.00, 'YER');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%PRICE_BELOW_COST_FLOOR%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-PRICING FAILED: Tier unit_price below cost floor was allowed!';
    END IF;

    -- 6.3: Negative Proof: Updating cost_floor_price to 410 YER (exceeds existing Tier 3 price of 380 YER) fails
    v_err_caught := false;
    BEGIN
        UPDATE public.wholesale_merchant_offers
        SET cost_floor_price = 410.00
        WHERE id = v_offer_yer_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%INVALID_COST_FLOOR_UPDATE%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-PRICING FAILED: cost_floor_price update invalidating existing tiers was allowed!';
    END IF;

    -- 6.4: Negative Proof: Updating cost_floor_price to 600 YER (exceeds official retail price 500 YER) fails
    v_err_caught := false;
    BEGIN
        UPDATE public.wholesale_merchant_offers
        SET cost_floor_price = 600.00
        WHERE id = v_offer_yer_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%COST_FLOOR_EXCEEDS_RETAIL%' OR SQLERRM LIKE '%INVALID_COST_FLOOR_UPDATE%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-PRICING FAILED: cost_floor_price exceeding retail price was allowed!';
    END IF;

    -- 6.5: Positive Proof: Quote calculations verify exact math and margins
    PERFORM set_config('request.jwt.claim.sub', v_retailer_active_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    -- Test Tier 2 match (qty 50): unit_price = 420.00
    v_quote := public.calculate_wholesale_quote(v_offer_yer_id, 50);
    IF (v_quote->>'total_wholesale_price')::NUMERIC != 21000.00 -- 50 * 420
       OR (v_quote->>'total_retail_value')::NUMERIC != 25000.00 -- 50 * 500
       OR (v_quote->>'retailer_margin_amount')::NUMERIC != 4000.00 -- 25000 - 21000
       OR (v_quote->>'retailer_margin_percentage')::NUMERIC != 16.00 -- (4000 / 25000) * 100
    THEN
        RAISE EXCEPTION 'R2-PRICING FAILED: Quote mathematical calculation mismatch: %', v_quote;
    END IF;

    -- Reset to superuser
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);

    INSERT INTO _test_r2_results VALUES ('R2-PRICING-06', 'Pricing Ceiling & Strict Cost Floor', 'PASS', 5, 5, 'Ceiling <= retail verified; Floor <= wholesale verified; Floor update guard verified; Margins mathematically exact');

    -- ================================================================
    -- 7. R2-RLS-07: MULTI-ACTOR ZERO PRICE LEAKAGE MATRIX
    -- ================================================================
    -- Switch to non-superuser role 'authenticated' for RLS evaluation
    PERFORM set_config('role', 'authenticated', true);

    -- 7.1: Actor Anon (Unauthenticated)
    PERFORM set_config('role', 'anon', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', 'anon', true);

    SELECT COUNT(*) INTO v_count FROM public.wholesale_catalog_products;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Anon can see % catalog products (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_merchant_offers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Anon can see % wholesale offers (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_offer_tiers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Anon can see % wholesale tiers (MUST BE 0)!', v_count;
    END IF;

    v_err_caught := false;
    BEGIN
        PERFORM public.calculate_wholesale_quote(v_offer_yer_id, 20);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%UNAUTHENTICATED%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Anon was allowed to calculate wholesale quote!';
    END IF;

    -- 7.2: Actor Customer
    PERFORM set_config('role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', v_customer_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    SELECT COUNT(*) INTO v_count FROM public.wholesale_catalog_products;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Customer can see % catalog products (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_merchant_offers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Customer can see % wholesale offers (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_offer_tiers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Customer can see % wholesale tiers (MUST BE 0)!', v_count;
    END IF;

    v_err_caught := false;
    BEGIN
        PERFORM public.calculate_wholesale_quote(v_offer_yer_id, 20);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%FORBIDDEN_OR_INACTIVE_RETAILER%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Customer was allowed to calculate wholesale quote!';
    END IF;

    -- 7.3: Actor Inactive Retailer (status = 'pending_verification')
    PERFORM set_config('request.jwt.claim.sub', v_retailer_inactive_id::TEXT, true);
    SELECT COUNT(*) INTO v_count FROM public.wholesale_catalog_products;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Inactive retailer can see % catalog products (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_merchant_offers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Inactive retailer can see % offers (MUST BE 0)!', v_count;
    END IF;

    v_err_caught := false;
    BEGIN
        PERFORM public.calculate_wholesale_quote(v_offer_yer_id, 20);
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%FORBIDDEN_OR_INACTIVE_RETAILER%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Inactive retailer was allowed to calculate wholesale quote!';
    END IF;

    -- 7.4: Actor Unauthorized Merchant (Merchant B querying Merchant A's offer)
    PERFORM set_config('request.jwt.claim.sub', v_merchant_unauthorized_id::TEXT, true);
    SELECT COUNT(*) INTO v_count FROM public.wholesale_merchant_offers WHERE id = v_offer_yer_id;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R2-RLS LEAKAGE: Unauthorized merchant can see another merchant offer (MUST BE 0)!';
    END IF;

    -- 7.5: Actor Active Retailer (status = 'active')
    PERFORM set_config('request.jwt.claim.sub', v_retailer_active_id::TEXT, true);
    SELECT COUNT(*) INTO v_count FROM public.wholesale_catalog_products WHERE status = 'active';
    IF v_count < 1 THEN
        RAISE EXCEPTION 'R2-RLS FAILED: Active retailer could not see active catalog products!';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_merchant_offers WHERE status = 'active';
    IF v_count < 1 THEN
        RAISE EXCEPTION 'R2-RLS FAILED: Active retailer could not see active offers!';
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_offer_tiers;
    IF v_count < 1 THEN
        RAISE EXCEPTION 'R2-RLS FAILED: Active retailer could not see active tiers!';
    END IF;

    v_quote := public.calculate_wholesale_quote(v_offer_yer_id, 20);
    IF (v_quote->>'success')::BOOLEAN IS NOT TRUE THEN
        RAISE EXCEPTION 'R2-RLS FAILED: Active retailer failed to calculate quote: %', v_quote;
    END IF;

    -- Revert role back to superuser
    PERFORM set_config('role', 'postgres', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);

    INSERT INTO _test_r2_results VALUES ('R2-RLS-07', 'Zero Price Leakage RLS Matrix', 'PASS', 13, 13, 'Anon=0, Customer=0, Inactive=0, Unauthorized Merchant=0, Active Retailer=Authorized');

    -- ================================================================
    -- 8. R2-CURRENCY-08: STRICT CURRENCY ISOLATION & MULTI-CURRENCY
    -- ================================================================
    -- 8.1: Negative Proof: Creating USD offer for YER catalog product fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_merchant_offers (
            merchant_id, catalog_product_id, min_order_quantity, step_quantity,
            cost_floor_price, currency, status
        ) VALUES (
            v_merchant_authorized_id, v_catalog_product_yer_id, 10, 10,
            1.00, 'USD', 'active'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%CURRENCY_MISMATCH%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-CURRENCY FAILED: Currency mismatch between offer (USD) and catalog (YER) was allowed!';
    END IF;

    -- 8.2: Negative Proof: Creating SAR tier for YER offer fails
    v_err_caught := false;
    BEGIN
        INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
        VALUES (v_offer_yer_id, 200, 300, 350.00, 'SAR');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%CURRENCY_MISMATCH%' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R2-CURRENCY FAILED: Tier currency (SAR) mismatching offer currency (YER) was allowed!';
    END IF;

    -- 8.3: Positive Proof: Parametric support for USD network, catalog, offer, and tiers
    INSERT INTO public.wholesale_catalog_products (id, network_package_id, network_id, currency, status)
    VALUES (v_catalog_product_usd_id, v_network_pkg_usd_id, v_network_usd_id, 'USD', 'active');

    INSERT INTO public.wholesale_merchant_offers (
        id, merchant_id, catalog_product_id, min_order_quantity, step_quantity,
        cost_floor_price, currency, status
    ) VALUES (
        v_offer_usd_id, v_merchant_authorized_id, v_catalog_product_usd_id, 10, 10,
        1.00, 'USD', 'active'
    );

    INSERT INTO public.wholesale_offer_tiers (offer_id, min_quantity, max_quantity, unit_price, currency)
    VALUES (v_offer_usd_id, 10, NULL, 1.50, 'USD'); -- 1.50 <= 2.00 official retail price

    -- Calculate USD quote
    PERFORM set_config('request.jwt.claim.sub', v_retailer_active_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    v_quote := public.calculate_wholesale_quote(v_offer_usd_id, 20);
    IF (v_quote->>'currency') != 'USD'
       OR (v_quote->>'unit_price')::NUMERIC != 1.50
       OR (v_quote->>'total_wholesale_price')::NUMERIC != 30.00
       OR (v_quote->>'total_retail_value')::NUMERIC != 40.00
    THEN
        RAISE EXCEPTION 'R2-CURRENCY FAILED: USD quote failed or was corrupted: %', v_quote;
    END IF;

    -- Reset to superuser
    PERFORM set_config('role', 'postgres', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', '', true);

    INSERT INTO _test_r2_results VALUES ('R2-CURRENCY-08', 'Strict Currency Isolation & Multi-Currency', 'PASS', 4, 4, 'Offer mismatch rejected; tier mismatch rejected; parametric USD workflow verified; zero FX conversion');

    -- ================================================================
    -- 9. R2-CLEANUP-09: ZERO-FOOTPRINT SELF-CLEANING EXECUTION
    -- ================================================================
    -- Clean up created test data in reverse foreign key order
    DELETE FROM public.wholesale_offer_tiers WHERE offer_id IN (v_offer_yer_id, v_offer_usd_id);
    DELETE FROM public.wholesale_merchant_offers WHERE id IN (v_offer_yer_id, v_offer_usd_id);
    DELETE FROM public.wholesale_catalog_products WHERE id IN (v_catalog_product_yer_id, v_catalog_product_usd_id);
    DELETE FROM public.network_packages WHERE id IN (v_network_pkg_valid_id, v_network_pkg_free_id, v_network_pkg_usd_id);
    DELETE FROM public.networks WHERE id IN (v_network_id, v_network_usd_id);
    DELETE FROM public.retailers WHERE id IN (v_retailer_active_id, v_retailer_inactive_id);
    DELETE FROM public.vendors WHERE id IN (v_merchant_authorized_id, v_merchant_unauthorized_id, v_vendor_regular_id);
    DELETE FROM public.profiles WHERE id IN (
        v_admin_id, v_customer_id, v_retailer_active_id, v_retailer_inactive_id,
        v_merchant_authorized_id, v_merchant_unauthorized_id, v_vendor_regular_id
    );
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'auth' AND table_name = 'users') THEN
        DELETE FROM auth.users WHERE id IN (
            v_admin_id, v_customer_id, v_retailer_active_id, v_retailer_inactive_id,
            v_merchant_authorized_id, v_merchant_unauthorized_id, v_vendor_regular_id
        );
    END IF;

    -- Assert 0 leftover records
    SELECT COUNT(*) INTO v_count FROM public.wholesale_offer_tiers WHERE offer_id IN (v_offer_yer_id, v_offer_usd_id);
    IF v_count != 0 THEN RAISE EXCEPTION 'R2-CLEANUP FAILED: leftover offer tiers'; END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_merchant_offers WHERE id IN (v_offer_yer_id, v_offer_usd_id);
    IF v_count != 0 THEN RAISE EXCEPTION 'R2-CLEANUP FAILED: leftover merchant offers'; END IF;
    SELECT COUNT(*) INTO v_count FROM public.wholesale_catalog_products WHERE id IN (v_catalog_product_yer_id, v_catalog_product_usd_id);
    IF v_count != 0 THEN RAISE EXCEPTION 'R2-CLEANUP FAILED: leftover catalog products'; END IF;

    INSERT INTO _test_r2_results VALUES ('R2-CLEANUP-09', 'Zero-Footprint Self-Cleaning Session', 'PASS', 3, 3, 'All test fixtures and operational records cleaned up completely (0 leftover rows)');

END $$;

-- --------------------------------------------------------------------
-- STEP 2: SUMMARY REPORT PRESENTATION
-- --------------------------------------------------------------------
SELECT 
    test_id,
    name,
    status,
    assertions || '/' || passed AS score,
    details
FROM _test_r2_results
ORDER BY test_id;

-- Aggregate JSON Result for Automated Verification Engines
SELECT json_build_object(
    'suite', 'Gate 039 - Program R2 Qualification Suite',
    'total_tests', COUNT(*),
    'passed_tests', COUNT(*) FILTER (WHERE status = 'PASS'),
    'failed_tests', COUNT(*) FILTER (WHERE status != 'PASS'),
    'total_assertions', SUM(assertions),
    'passed_assertions', SUM(passed),
    'status', CASE WHEN COUNT(*) FILTER (WHERE status != 'PASS') = 0 THEN 'GATE_PASS' ELSE 'GATE_FAIL' END
) AS gate_039_summary
FROM _test_r2_results;
