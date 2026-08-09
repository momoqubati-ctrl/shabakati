-- Sub-Agent Commission Contract Tests
-- RED until relationship ownership and immutable policy boundaries exist.

DO $$
DECLARE
    v_oid OID;
    v_definition TEXT;
BEGIN
    SELECT p.oid INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_sub_agent_commission'
      AND pg_get_function_identity_arguments(p.oid) = 'uuid, uuid, uuid, text, numeric, text, jsonb';

    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'FEE-CONTRACT-034-001: sub-agent commission resolver signature is missing';
    END IF;

    SELECT pg_get_functiondef(v_oid) INTO v_definition;

    IF v_definition ILIKE '%vendors.commission_rate%' THEN
        RAISE EXCEPTION 'FEE-CONTRACT-034-002: sub-agent commission depends on vendor-platform commission';
    END IF;

    IF v_definition NOT ILIKE '%network%'
       OR v_definition NOT ILIKE '%sub_agent%'
       OR v_definition NOT ILIKE '%policy_version%' THEN
        RAISE EXCEPTION 'FEE-CONTRACT-034-003: resolver does not expose network-owner policy ownership and versioning';
    END IF;

    RAISE NOTICE 'Sub-agent commission resolver contract passed';
END;
$$;