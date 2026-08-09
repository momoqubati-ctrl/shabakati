-- Currency Contract Tests
-- Purpose: Contract-first checks for the transaction-level currency boundary.
-- These tests intentionally fail until the forward migration exposes the resolver.

DO $$
DECLARE
    v_resolver_oid OID;
    v_resolver_signature TEXT;
    v_output_names TEXT[];
    v_output_types TEXT[];
    v_retired_columns TEXT[];
BEGIN
    -- The resolver must be a database domain boundary, not application-local logic.
    SELECT p.oid, pg_get_function_identity_arguments(p.oid)
    INTO v_resolver_oid, v_resolver_signature
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
            AND p.proname = 'resolve_transaction_currency'
            AND pg_get_function_identity_arguments(p.oid) = 'text, uuid, uuid, uuid, text, text, jsonb';

    IF v_resolver_oid IS NULL THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-001: resolve_transaction_currency(text, uuid, uuid, uuid, text, text, jsonb) is missing';
    END IF;

    -- The resolver result must carry the exact auditable contract.
    SELECT
        ARRAY_AGG(arg_name ORDER BY ordinal_position),
        ARRAY_AGG(arg_type ORDER BY ordinal_position)
    INTO v_output_names, v_output_types
    FROM (
        SELECT
            u.ordinality AS ordinal_position,
            u.arg_name,
            format_type(u.arg_type, NULL) AS arg_type
        FROM pg_proc p
        CROSS JOIN LATERAL unnest(p.proallargtypes, p.proargnames, p.proargmodes)
            WITH ORDINALITY AS u(arg_type, arg_name, arg_mode, ordinality)
        WHERE p.oid = v_resolver_oid
          AND u.arg_mode = 't'
    ) outputs;

    IF v_output_names IS DISTINCT FROM ARRAY['currency', 'policy_version', 'is_allowed']
    OR v_output_types IS DISTINCT FROM ARRAY['text', 'integer', 'boolean'] THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-002: resolver return contract is %, %; expected names %, types %',
            v_output_names,
            v_output_types,
            ARRAY['currency', 'policy_version', 'is_allowed'],
            ARRAY['text', 'integer', 'boolean'];
    END IF;

    -- Product/inventory data must not regain the retired currency contract.
    SELECT ARRAY_AGG(column_name ORDER BY column_name)
    INTO v_retired_columns
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'network_packages'
      AND column_name IN ('currency', 'min_stock_alert');

    IF v_retired_columns IS NOT NULL THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-003: network_packages contains retired columns: %',
            ARRAY_TO_STRING(v_retired_columns, ', ');
    END IF;

    RAISE NOTICE 'Currency contract metadata assertions passed for resolver %', v_resolver_signature;
END;
$$;