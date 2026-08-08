-- Gateway Fee Contract Tests
-- RED until expected-fee policy and provider-fact boundaries are implemented.

DO $$
DECLARE
    v_oid OID;
    v_definition TEXT;
    v_missing_columns TEXT[];
BEGIN
    SELECT p.oid INTO v_oid
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_gateway_fee'
      AND pg_get_function_identity_arguments(p.oid) = 'text, text, text, numeric, text, uuid, uuid, jsonb';

    IF v_oid IS NULL THEN
        RAISE EXCEPTION 'FEE-CONTRACT-033-001: gateway fee resolver signature is missing';
    END IF;

    SELECT pg_get_functiondef(v_oid) INTO v_definition;

    IF v_definition ILIKE '%gateway_fee_actual%'
       OR v_definition ILIKE '%response_payload%'
       OR v_definition ILIKE '%INSERT INTO%' THEN
        RAISE EXCEPTION 'FEE-CONTRACT-033-002: gateway policy resolver must not resolve provider facts or write state';
    END IF;

    SELECT ARRAY_AGG(required_column ORDER BY required_column)
    INTO v_missing_columns
    FROM unnest(ARRAY['gateway_fee_actual', 'gateway_fee_currency']) AS required(required_column)
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name = 'payment_gateway_operations'
          AND c.column_name = required.required_column
    );

    IF v_missing_columns IS NOT NULL THEN
        RAISE EXCEPTION 'FEE-CONTRACT-033-003: provider fee fact columns are missing: %',
            ARRAY_TO_STRING(v_missing_columns, ', ');
    END IF;

    RAISE NOTICE 'Gateway fee resolver contract passed';
END;
$$;