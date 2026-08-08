-- Platform Commission Contract Tests
-- RED until the versioned platform commission resolver is implemented.

DO $$
DECLARE
    v_oid OID;
    v_definition TEXT;
BEGIN
    SELECT p.oid INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_platform_commission'
      AND pg_get_function_identity_arguments(p.oid) = 'text, uuid, uuid, numeric, text, jsonb';

    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'FEE-CONTRACT-032-001: platform commission resolver signature is missing';
    END IF;

    SELECT pg_get_functiondef(v_oid) INTO v_definition;

    IF v_definition ILIKE '%vendors.commission_rate%'
       OR v_definition ILIKE '%INSERT INTO%'
       OR v_definition ILIKE '%UPDATE%ledger%' THEN
        RAISE EXCEPTION 'FEE-CONTRACT-032-002: resolver uses legacy runtime data or financial side effects';
    END IF;

    RAISE NOTICE 'Platform commission resolver contract passed';
END;
$$;