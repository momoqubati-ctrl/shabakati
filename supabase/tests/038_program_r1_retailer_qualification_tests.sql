-- ====================================================================
-- Test Suite: Program R1 Hardened Qualification & Acceptance Gate (038)
-- File: 038_program_r1_retailer_qualification_tests.sql
-- Version: 3.3.0 (Enterprise UBTR, Zero-PII & Single-Session Gate)
-- 
-- Scope:
--   1. Schema & Constraints Deep Verification (DB-02, DB-03)
--   2. Atomic Registration & Central Enterprise UBTR Compliance (R1-RPC, R1-UBTR)
--   3. Strict Idempotency Ordering, Replay, & Conflict Guards (R1-IDEMP)
--   4. Role & Authorization Enforcement (Customer-only, Vendor/Admin Deny) (R1-AUTHZ)
--   5. Field & Audit Log Immutability Guards (Append-Only Proof) (R1-IMMUT)
--   6. Rigid State Machine Transitions & Metadata Invariants (R1-STATE)
--   7. Zero-PII Wholesale View Contract & Multi-Actor RLS Matrix (R1-PII, R1-RLS)
--   8. Self-Contained Execution & Single-Session Machine-Readable Summary
-- ====================================================================

-- --------------------------------------------------------------------
-- STEP 0: SESSION LEDGER INITIALIZATION
-- --------------------------------------------------------------------
CREATE TEMP TABLE IF NOT EXISTS _test_r1_fixtures (
    key TEXT PRIMARY KEY,
    id UUID NOT NULL
);

CREATE TEMP TABLE IF NOT EXISTS _test_r1_results (
    test_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    status TEXT NOT NULL,
    assertions INT NOT NULL,
    passed INT NOT NULL,
    details TEXT
);

GRANT ALL ON TABLE _test_r1_fixtures TO public;
GRANT ALL ON TABLE _test_r1_results TO public;

TRUNCATE TABLE _test_r1_fixtures;
TRUNCATE TABLE _test_r1_results;

INSERT INTO _test_r1_fixtures (key, id) VALUES
    ('admin_id', gen_random_uuid()),
    ('retailer_a_id', gen_random_uuid()),
    ('retailer_b_id', gen_random_uuid()),
    ('retailer_c_id', gen_random_uuid()),
    ('merchant_id', gen_random_uuid()),
    ('customer_id', gen_random_uuid()),
    ('vendor_id', gen_random_uuid());

-- --------------------------------------------------------------------
-- STEP 1: QUALIFICATION EXECUTION HARNESS
-- --------------------------------------------------------------------
DO $$
DECLARE
    v_admin_id UUID;
    v_retailer_a_id UUID;
    v_retailer_b_id UUID;
    v_retailer_c_id UUID;
    v_merchant_id UUID;
    v_customer_id UUID;
    v_vendor_id UUID;

    v_result JSONB;
    v_code_a VARCHAR(20);
    v_code_replay VARCHAR(20);
    v_ubtr_a VARCHAR(50);
    v_ubtr_replay VARCHAR(50);
    v_bt_rec RECORD;
    v_count INT;
    v_status retailer_status;
    v_verified_at TIMESTAMPTZ;
    v_verified_by UUID;
    v_rejection_reason TEXT;
    v_err_caught BOOLEAN;
BEGIN
    SELECT id INTO v_admin_id FROM _test_r1_fixtures WHERE key = 'admin_id';
    SELECT id INTO v_retailer_a_id FROM _test_r1_fixtures WHERE key = 'retailer_a_id';
    SELECT id INTO v_retailer_b_id FROM _test_r1_fixtures WHERE key = 'retailer_b_id';
    SELECT id INTO v_retailer_c_id FROM _test_r1_fixtures WHERE key = 'retailer_c_id';
    SELECT id INTO v_merchant_id FROM _test_r1_fixtures WHERE key = 'merchant_id';
    SELECT id INTO v_customer_id FROM _test_r1_fixtures WHERE key = 'customer_id';
    SELECT id INTO v_vendor_id FROM _test_r1_fixtures WHERE key = 'vendor_id';

    -- ----------------------------------------------------------------
    -- 1. DB-01: SCHEMA, CONSTRAINTS & COLUMNS VERIFICATION
    -- ----------------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'store_type') THEN
        RAISE EXCEPTION 'DB-01 FAILED: Enum store_type missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'retailer_status') THEN
        RAISE EXCEPTION 'DB-01 FAILED: Enum retailer_status missing';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'vendor_type') THEN
        RAISE EXCEPTION 'DB-01 FAILED: Enum vendor_type missing';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_enum e 
        JOIN pg_type t ON e.enumtypid = t.oid 
        WHERE t.typname = 'user_role' AND e.enumlabel = 'retailer'
    ) THEN
        RAISE EXCEPTION 'DB-01 FAILED: user_role missing retailer value';
    END IF;

    -- Verify idempotency_key UNIQUE constraint on public.retailers
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints tc
        JOIN information_schema.key_column_usage kcu 
          ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
        WHERE tc.table_schema = 'public' 
          AND tc.table_name = 'retailers' 
          AND tc.constraint_type = 'UNIQUE'
          AND kcu.column_name = 'idempotency_key'
    ) THEN
        RAISE EXCEPTION 'DB-01 FAILED: Missing UNIQUE constraint on retailers.idempotency_key';
    END IF;

    INSERT INTO _test_r1_results VALUES ('R1-SCHEMA-01', 'Schema Types & Constraints', 'PASS', 5, 5, 'All enums, unique idempotency_key constraint verified');

    -- ----------------------------------------------------------------
    -- 2. SETUP TEST ACCOUNTS IN AUTH.USERS, PROFILES & VENDORS
    -- ----------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'auth' AND table_name = 'users') THEN
        INSERT INTO auth.users (id, email, phone) VALUES
            (v_admin_id, 'admin@shabakati.local', '770000001'),
            (v_retailer_a_id, 'cust_a@shabakati.local', '770000002'),
            (v_retailer_b_id, 'cust_b@shabakati.local', '770000003'),
            (v_retailer_c_id, 'cust_c@shabakati.local', '770000004'),
            (v_customer_id, 'plain@shabakati.local', '770000005'),
            (v_vendor_id, 'vendor@shabakati.local', '770000006'),
            (v_merchant_id, 'wholesale@shabakati.local', '770000007')
        ON CONFLICT (id) DO NOTHING;
    END IF;

    INSERT INTO public.profiles (id, name, role, phone_number, email) VALUES
        (v_admin_id, 'Admin User', 'admin', '770000001', 'admin@shabakati.local'),
        (v_retailer_a_id, 'Customer A', 'customer', '770000002', 'cust_a@shabakati.local'),
        (v_retailer_b_id, 'Customer B', 'customer', '770000003', 'cust_b@shabakati.local'),
        (v_retailer_c_id, 'Customer C', 'customer', '770000004', 'cust_c@shabakati.local'),
        (v_customer_id, 'Plain Customer', 'customer', '770000005', 'plain@shabakati.local'),
        (v_vendor_id, 'Network Vendor', 'vendor', '770000006', 'vendor@shabakati.local'),
        (v_merchant_id, 'Wholesale Merchant', 'vendor', '770000007', 'wholesale@shabakati.local')
    ON CONFLICT (id) DO UPDATE SET role = EXCLUDED.role, name = EXCLUDED.name;

    INSERT INTO public.vendors (id, business_name, vendor_type, wholesale_license_number) VALUES
        (v_vendor_id, 'Alpha Network', 'network_owner', NULL),
        (v_merchant_id, 'Yemen Wholesale Cards', 'wholesale_merchant', 'WL-SANAA-2026-09')
    ON CONFLICT (id) DO UPDATE SET vendor_type = EXCLUDED.vendor_type, wholesale_license_number = EXCLUDED.wholesale_license_number;

    -- ----------------------------------------------------------------
    -- 3. R1-AUTHZ: STRICT REGISTRATION AUTHORIZATION GUARD
    -- ----------------------------------------------------------------
    -- 3.1: Vendor cannot register as retailer
    PERFORM set_config('request.jwt.claim.sub', v_vendor_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.register_retailer_profile(
            p_store_name => 'Vendor Illegal Store',
            p_idempotency_key => 'test-vendor-illegal-key'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%FORBIDDEN_ROLE%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-AUTHZ FAILED: Vendor was not blocked by FORBIDDEN_ROLE';
    END IF;

    -- 3.2: Admin cannot register as retailer
    PERFORM set_config('request.jwt.claim.sub', v_admin_id::TEXT, true);
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.register_retailer_profile(
            p_store_name => 'Admin Illegal Store',
            p_idempotency_key => 'test-admin-illegal-key'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%FORBIDDEN_ROLE%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-AUTHZ FAILED: Admin was not blocked by FORBIDDEN_ROLE';
    END IF;

    INSERT INTO _test_r1_results VALUES ('R1-AUTHZ-01', 'Registration Role Isolation', 'PASS', 2, 2, 'Vendors and Admins strictly blocked with FORBIDDEN_ROLE');

    -- ----------------------------------------------------------------
    -- 4. R1-RPC & R1-UBTR: REGISTRATION & CENTRAL ENTERPRISE UBTR INTEGRATION
    -- ----------------------------------------------------------------
    PERFORM set_config('request.jwt.claim.sub', v_retailer_a_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    v_result := public.register_retailer_profile(
        p_store_name => 'بقالة الأمانة النموذجية',
        p_store_type => 'grocery',
        p_city => 'صنعاء',
        p_zone => 'حدة',
        p_exact_address => 'شارع بيروت - جوار بنك اليمن الدولي',
        p_contact_phone => '771234567',
        p_whatsapp_phone => '771234567',
        p_commercial_registry => 'CR-SANAA-88412',
        p_owner_national_id => '1001099234',
        p_idempotency_key => 'idemp-key-retailer-a-001'
    );

    IF (v_result->>'success')::BOOLEAN != TRUE THEN
        RAISE EXCEPTION 'R1-RPC FAILED: Registration returned success=false: %', v_result;
    END IF;

    v_code_a := v_result->>'retailer_code';
    v_ubtr_a := v_result->>'ubtr';

    IF v_code_a IS NULL OR v_code_a NOT LIKE 'RET-%' THEN
        RAISE EXCEPTION 'R1-RPC FAILED: Invalid retailer code format: %', v_code_a;
    END IF;

    -- Assert UBTR follows central format (UBTR-15digits) and NOT local mock format
    IF v_ubtr_a IS NULL OR v_ubtr_a LIKE 'UBTR-RET-%' OR v_ubtr_a LIKE 'UBTR-ADM-%' THEN
        RAISE EXCEPTION 'R1-UBTR FAILED: UBTR is using prohibited local string format: %', v_ubtr_a;
    END IF;

    -- Verify central business_transactions record exists
    SELECT * INTO v_bt_rec 
    FROM public.business_transactions 
    WHERE created_source = 'RETAILER_REGISTRATION' 
      AND created_by = v_retailer_a_id;

    IF v_bt_rec.id IS NULL THEN
        RAISE EXCEPTION 'R1-UBTR FAILED: No record created in central public.business_transactions';
    END IF;

    IF v_bt_rec.business_reference < 100000000000000 THEN
        RAISE EXCEPTION 'R1-UBTR FAILED: business_reference % does not originate from global sequence', v_bt_rec.business_reference;
    END IF;

    IF v_ubtr_a != public._ubtr_display(v_bt_rec.business_reference) THEN
        RAISE EXCEPTION 'R1-UBTR FAILED: Stored UBTR (%) != central _ubtr_display (%)', v_ubtr_a, public._ubtr_display(v_bt_rec.business_reference);
    END IF;

    -- Verify profiles.role upgraded to 'retailer'
    IF (SELECT role FROM public.profiles WHERE id = v_retailer_a_id) != 'retailer' THEN
        RAISE EXCEPTION 'R1-RPC FAILED: User role was not upgraded to retailer in profiles';
    END IF;

    INSERT INTO _test_r1_results VALUES ('R1-UBTR-01', 'Enterprise UBTR Integration', 'PASS', 6, 6, 'Central sequence, _ubtr_display, and business_transactions verified');

    -- ----------------------------------------------------------------
    -- 5. R1-IDEMP: STRICT IDEMPOTENCY SEQUENCE & CONFLICT GUARDS
    -- ----------------------------------------------------------------
    -- 5.1: Same user + same key -> Idempotent Replay (even though role is now 'retailer'!)
    v_result := public.register_retailer_profile(
        p_store_name => 'بقالة الأمانة النموذجية (تعديل متجاهل)',
        p_idempotency_key => 'idemp-key-retailer-a-001'
    );

    IF (v_result->>'success')::BOOLEAN != TRUE OR (v_result->>'is_idempotent_replay')::BOOLEAN != TRUE THEN
        RAISE EXCEPTION 'R1-IDEMP FAILED: Replay failed on same key: %', v_result;
    END IF;

    IF (v_result->>'retailer_code') != v_code_a OR (v_result->>'ubtr') != v_ubtr_a THEN
        RAISE EXCEPTION 'R1-IDEMP FAILED: Replay returned different identity payload';
    END IF;

    -- 5.2: Different user + same key -> IDEMPOTENCY_CONFLICT
    PERFORM set_config('request.jwt.claim.sub', v_retailer_b_id::TEXT, true);
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.register_retailer_profile(
            p_store_name => 'متجر بي',
            p_idempotency_key => 'idemp-key-retailer-a-001'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%IDEMPOTENCY_CONFLICT%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IDEMP FAILED: Re-using key across accounts was not blocked with IDEMPOTENCY_CONFLICT';
    END IF;

    -- 5.3: Same user (A) + new key -> ALREADY_REGISTERED
    PERFORM set_config('request.jwt.claim.sub', v_retailer_a_id::TEXT, true);
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.register_retailer_profile(
            p_store_name => 'بقالة الأمانة فرع 2',
            p_idempotency_key => 'idemp-key-retailer-a-002-different'
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%ALREADY_REGISTERED%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IDEMP FAILED: Registered user submitting new key was not blocked with ALREADY_REGISTERED';
    END IF;

    INSERT INTO _test_r1_results VALUES ('R1-IDEMP-01', 'Idempotency Replay & Conflict Guards', 'PASS', 5, 5, 'Replay preserves payload; cross-account conflict & duplicate registration blocked');

    -- Register Retailer B normally for multi-tenant tests
    PERFORM set_config('request.jwt.claim.sub', v_retailer_b_id::TEXT, true);
    PERFORM public.register_retailer_profile(
        p_store_name => 'سوبرماركت البركة',
        p_store_type => 'supermarket',
        p_city => 'صنعاء',
        p_zone => 'الصافية',
        p_contact_phone => '779876543',
        p_idempotency_key => 'idemp-key-retailer-b-001'
    );

    -- Register Retailer C for rejection state tests
    PERFORM set_config('request.jwt.claim.sub', v_retailer_c_id::TEXT, true);
    PERFORM public.register_retailer_profile(
        p_store_name => 'كشك الأمل',
        p_store_type => 'kiosk',
        p_city => 'صنعاء',
        p_zone => 'التحرير',
        p_contact_phone => '771122334',
        p_idempotency_key => 'idemp-key-retailer-c-001'
    );

    -- ----------------------------------------------------------------
    -- 6. R1-IMMUT: FIELD & AUDIT LOG IMMUTABILITY GUARDS
    -- ----------------------------------------------------------------
    -- 6.1: Direct update of retailer_code is strictly blocked
    v_err_caught := FALSE;
    BEGIN
        UPDATE public.retailers SET retailer_code = 'RET-99999' WHERE id = v_retailer_a_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%IMMUTABILITY_VIOLATION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IMMUT FAILED: Direct retailer_code update was not blocked';
    END IF;

    -- 6.2: Direct update of idempotency_key is strictly blocked
    v_err_caught := FALSE;
    BEGIN
        UPDATE public.retailers SET idempotency_key = 'hacked-key' WHERE id = v_retailer_a_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%IMMUTABILITY_VIOLATION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IMMUT FAILED: Direct idempotency_key update was not blocked';
    END IF;

    -- 6.3: Direct update of status by non-admin is blocked
    PERFORM set_config('request.jwt.claim.sub', v_retailer_a_id::TEXT, true);
    v_err_caught := FALSE;
    BEGIN
        UPDATE public.retailers SET status = 'active' WHERE id = v_retailer_a_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%SECURITY_VIOLATION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IMMUT FAILED: Direct status update by retailer was not blocked';
    END IF;

    -- 6.4: Audit log is strictly APPEND-ONLY: UPDATE is blocked
    v_err_caught := FALSE;
    BEGIN
        UPDATE public.retailer_audit_logs SET reason = 'Tampered reason' WHERE retailer_id = v_retailer_a_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%IMMUTABILITY_VIOLATION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IMMUT FAILED: UPDATE on retailer_audit_logs was not blocked';
    END IF;

    -- 6.5: Audit log is strictly APPEND-ONLY: DELETE is blocked
    v_err_caught := FALSE;
    BEGIN
        DELETE FROM public.retailer_audit_logs WHERE retailer_id = v_retailer_a_id;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%IMMUTABILITY_VIOLATION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-IMMUT FAILED: DELETE on retailer_audit_logs was not blocked';
    END IF;

    INSERT INTO _test_r1_results VALUES ('R1-IMMUT-01', 'Field & Audit Immutability', 'PASS', 5, 5, 'retailer_code, idempotency_key, and audit logs are provably immutable');

    -- ----------------------------------------------------------------
    -- 7. R1-STATE: RIGID STATE MACHINE & METADATA INVARIANTS
    -- ----------------------------------------------------------------
    PERFORM set_config('request.jwt.claim.sub', v_admin_id::TEXT, true);

    -- 7.1: Valid Transition: pending -> active (APPROVE)
    v_result := public.admin_verify_retailer(
        p_retailer_id => v_retailer_a_id,
        p_action => 'APPROVE',
        p_reason => 'مستندات مكتملة ومطابقة للشروط'
    );
    IF (v_result->>'success')::BOOLEAN != TRUE THEN
        RAISE EXCEPTION 'R1-STATE FAILED: Admin APPROVE failed: %', v_result;
    END IF;

    SELECT status, verified_at, verified_by INTO v_status, v_verified_at, v_verified_by 
    FROM public.retailers WHERE id = v_retailer_a_id;

    IF v_status != 'active' OR v_verified_at IS NULL OR v_verified_by != v_admin_id THEN
        RAISE EXCEPTION 'R1-STATE FAILED: Invariants for active state violated: status=%, verified_at=%, verified_by=%', v_status, v_verified_at, v_verified_by;
    END IF;

    -- 7.2: Invalid Transition: active -> APPROVE (already active)
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.admin_verify_retailer(v_retailer_a_id, 'APPROVE');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%INVALID_STATE_TRANSITION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-STATE FAILED: active -> APPROVE was not rejected';
    END IF;

    -- 7.3: Valid Transition: active -> SUSPEND
    v_result := public.admin_verify_retailer(v_retailer_a_id, 'SUSPEND', 'إيقاف احترازي مؤقت');
    IF (v_result->>'new_status') != 'suspended' THEN
        RAISE EXCEPTION 'R1-STATE FAILED: SUSPEND failed: %', v_result;
    END IF;

    -- 7.4: Valid Transition: suspended -> ACTIVATE
    v_result := public.admin_verify_retailer(v_retailer_a_id, 'ACTIVATE', 'استئناف النشاط بعد انتفاء السبب');
    IF (v_result->>'new_status') != 'active' THEN
        RAISE EXCEPTION 'R1-STATE FAILED: ACTIVATE failed: %', v_result;
    END IF;

    -- 7.5: Valid Transition: pending -> REJECT on Retailer C (requires reason)
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.admin_verify_retailer(v_retailer_c_id, 'REJECT', ''); -- Empty reason must fail
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%REASON_REQUIRED%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-STATE FAILED: REJECT without reason was not rejected';
    END IF;

    v_result := public.admin_verify_retailer(v_retailer_c_id, 'REJECT', 'البيانات التجارية غير صحيحة');
    SELECT status, rejection_reason INTO v_status, v_rejection_reason FROM public.retailers WHERE id = v_retailer_c_id;
    IF v_status != 'rejected' OR v_rejection_reason IS NULL THEN
        RAISE EXCEPTION 'R1-STATE FAILED: Invariants for rejected state violated: status=%, reason=%', v_status, v_rejection_reason;
    END IF;

    -- 7.6: Invalid Transition: rejected -> APPROVE (terminal state)
    v_err_caught := FALSE;
    BEGIN
        PERFORM public.admin_verify_retailer(v_retailer_c_id, 'APPROVE');
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM LIKE '%INVALID_STATE_TRANSITION%' THEN
            v_err_caught := TRUE;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'R1-STATE FAILED: rejected -> APPROVE was not rejected';
    END IF;

    INSERT INTO _test_r1_results VALUES ('R1-STATE-01', 'Rigid State Machine & Invariants', 'PASS', 8, 8, 'Valid transitions pass; invalid transitions & missing reasons strictly rejected');

    -- ----------------------------------------------------------------
    -- 8. R1-PII: ZERO-PII WHOLESALE VIEW CONTRACT TEST
    -- ----------------------------------------------------------------
    -- Assert allowed columns exist in retailer_wholesale_directory
    DECLARE
        v_view_cols TEXT[];
        v_forbidden_found TEXT[];
    BEGIN
        SELECT array_agg(column_name::TEXT) INTO v_view_cols
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'retailer_wholesale_directory';

        IF NOT ('id' = ANY(v_view_cols)) OR NOT ('retailer_code' = ANY(v_view_cols)) OR NOT ('store_name' = ANY(v_view_cols)) THEN
            RAISE EXCEPTION 'R1-PII FAILED: Missing core public columns in retailer_wholesale_directory';
        END IF;

        -- Assert forbidden sensitive columns DO NOT exist in the View definition
        SELECT array_agg(col) INTO v_forbidden_found
        FROM unnest(ARRAY[
            'owner_national_id',
            'commercial_registry',
            'exact_address',
            'verified_by',
            'rejection_reason',
            'idempotency_key',
            'business_transaction_id'
        ]) AS col
        WHERE col = ANY(v_view_cols);

        IF v_forbidden_found IS NOT NULL AND array_length(v_forbidden_found, 1) > 0 THEN
            RAISE EXCEPTION 'R1-PII CRITICAL SECURITY VIOLATION: Forbidden columns % found in wholesale view!', v_forbidden_found;
        END IF;

        INSERT INTO _test_r1_results VALUES ('R1-PII-01', 'Zero-PII Wholesale View Contract', 'PASS', 4, 4, 'View definition strictly excludes national ID, exact address, registry, and audit links');
    END;

    -- ----------------------------------------------------------------
    -- 9. R1-RLS: MULTI-ACTOR RLS POLICIES & ROW ISOLATION
    -- ----------------------------------------------------------------
    -- Switch to non-superuser role 'authenticated' to evaluate RLS
    PERFORM set_config('role', 'authenticated', true);

    -- 9.1: Wholesale Merchant Actor
    PERFORM set_config('request.jwt.claim.sub', v_merchant_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);

    -- Wholesale Merchant query on raw retailers table -> MUST RETURN EXACTLY 0 ROWS (PII Protection)
    SELECT COUNT(*) INTO v_count FROM public.retailers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Wholesale merchant can view % rows on raw retailers table (MUST BE 0)!', v_count;
    END IF;

    -- Wholesale Merchant query on retailer_wholesale_directory -> MUST SEE ACTIVE ONLY (Retailer A = 1, Retailer B = pending/0)
    SELECT COUNT(*) INTO v_count FROM public.retailer_wholesale_directory;
    IF v_count != 1 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Wholesale directory should show 1 active retailer, got %', v_count;
    END IF;

    -- Wholesale Merchant cannot see audit logs
    SELECT COUNT(*) INTO v_count FROM public.retailer_audit_logs;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Wholesale merchant can view % rows on retailer_audit_logs (MUST BE 0)!', v_count;
    END IF;

    -- 9.2: Retailer A Actor
    PERFORM set_config('request.jwt.claim.sub', v_retailer_a_id::TEXT, true);
    SELECT COUNT(*) INTO v_count FROM public.retailers;
    IF v_count != 1 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Retailer A cannot see own profile (expected 1, got %)', v_count;
    END IF;

    -- Retailer A cannot see Retailer B's profile
    SELECT COUNT(*) INTO v_count FROM public.retailers WHERE id = v_retailer_b_id;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Retailer A can see Retailer B profile (tenant leak!)';
    END IF;

    -- 9.3: Plain Customer Actor
    PERFORM set_config('request.jwt.claim.sub', v_customer_id::TEXT, true);
    SELECT COUNT(*) INTO v_count FROM public.retailers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Plain customer can see % retailer profiles (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.retailer_wholesale_directory;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Plain customer can see % wholesale directory rows (MUST BE 0)!', v_count;
    END IF;

    -- 9.4: Anonymous Actor
    PERFORM set_config('role', 'anon', true);
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claim.role', 'anon', true);
    SELECT COUNT(*) INTO v_count FROM public.retailers;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Anonymous user can see % retailers (MUST BE 0)!', v_count;
    END IF;
    SELECT COUNT(*) INTO v_count FROM public.retailer_wholesale_directory;
    IF v_count != 0 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Anonymous user can see % wholesale directory rows (MUST BE 0)!', v_count;
    END IF;

    -- 9.5: Admin Actor (under authenticated role with admin claim)
    PERFORM set_config('role', 'authenticated', true);
    PERFORM set_config('request.jwt.claim.sub', v_admin_id::TEXT, true);
    PERFORM set_config('request.jwt.claim.role', 'authenticated', true);
    SELECT COUNT(*) INTO v_count FROM public.retailers;
    IF v_count < 3 THEN
        RAISE EXCEPTION 'R1-RLS FAILED: Admin cannot see all retailers (expected >= 3, got %)', v_count;
    END IF;

    -- Restore session role to postgres for results recording and fixture cleanup
    PERFORM set_config('role', 'postgres', true);

    INSERT INTO _test_r1_results VALUES ('R1-RLS-01', 'Multi-Actor RLS & PII Isolation Matrix', 'PASS', 10, 10, 'Raw retailers table blocks wholesale; directory allows active; retailers isolated; anon blocked; admin full');

    -- ----------------------------------------------------------------
    -- 10. SELF-CONTAINED CLEANUP (ZERO RESIDUAL FOOTPRINT)
    -- ----------------------------------------------------------------
    -- Temporarily disable triggers for deterministic test fixture removal
    ALTER TABLE public.retailer_audit_logs DISABLE TRIGGER trg_prevent_retailer_audit_mutation;
    
    DELETE FROM public.retailer_audit_logs WHERE retailer_id IN (SELECT id FROM _test_r1_fixtures);
    DELETE FROM public.retailers WHERE id IN (SELECT id FROM _test_r1_fixtures);
    DELETE FROM public.vendors WHERE id IN (SELECT id FROM _test_r1_fixtures);
    DELETE FROM public.wallets WHERE user_id IN (SELECT id FROM _test_r1_fixtures);
    DELETE FROM public.profiles WHERE id IN (SELECT id FROM _test_r1_fixtures);

    DELETE FROM public.business_transaction_links WHERE business_transaction_id IN (
        SELECT id FROM public.business_transactions WHERE created_by IN (SELECT id FROM _test_r1_fixtures)
    );
    DELETE FROM public.business_transaction_status_history WHERE business_transaction_id IN (
        SELECT id FROM public.business_transactions WHERE created_by IN (SELECT id FROM _test_r1_fixtures)
    );
    DELETE FROM public.business_transactions WHERE created_by IN (SELECT id FROM _test_r1_fixtures);

    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'auth' AND table_name = 'users') THEN
        DELETE FROM auth.users WHERE id IN (SELECT id FROM _test_r1_fixtures);
    END IF;

    ALTER TABLE public.retailer_audit_logs ENABLE TRIGGER trg_prevent_retailer_audit_mutation;

    INSERT INTO _test_r1_results VALUES ('R1-CLEANUP-01', 'Self-Contained Fixture Cleanup', 'PASS', 1, 1, 'All test accounts, retailers, transactions, and audit fixtures cleanly purged');

    RAISE NOTICE '=======================================================';
    RAISE NOTICE 'ALL PROGRAM R1 QUALIFICATION TESTS PASSED SUCCESSFULLY';
    RAISE NOTICE '=======================================================';
END $$;

-- --------------------------------------------------------------------
-- STEP 2: MACHINE-READABLE STRUCTURED RESULTS OUTPUT (SINGLE SESSION)
-- --------------------------------------------------------------------
SELECT 
    json_build_object(
        'suite', '038',
        'overall_status', CASE WHEN count(*) FILTER (WHERE status != 'PASS') = 0 THEN 'PASS' ELSE 'FAIL' END,
        'total_tests', count(*),
        'passed_tests', count(*) FILTER (WHERE status = 'PASS'),
        'failed_tests', count(*) FILTER (WHERE status != 'PASS'),
        'results', json_agg(row_to_json(r))
    ) AS qualification_suite_summary
FROM _test_r1_results r;
