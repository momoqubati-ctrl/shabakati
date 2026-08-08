-- Currency Resolver Behavioral Contract Tests
-- Purpose: Contract-first behavior checks for the transaction currency policy boundary.
-- These tests intentionally fail until the forward migration exposes the resolver.

DO $$
DECLARE
    v_result RECORD;
    v_repeat RECORD;
    v_function_definition TEXT;
    v_context JSONB := '{"source":"contract-test"}'::jsonb;
    v_customer_id UUID := '00000000-0000-0000-0000-000000000001';
BEGIN
    -- Dynamic SQL keeps this RED test loadable before the RPC exists.
    EXECUTE $query$
        SELECT currency, policy_version, is_allowed
        FROM public.resolve_transaction_currency(
            'CARD_PURCHASE',
            $1,
            $2,
            $3,
            'WALLET',
            $4,
            $5
        )
    $query$
    INTO v_result
    USING NULL::UUID, NULL::UUID, v_customer_id, NULL::TEXT, v_context;

    IF v_result.currency IS NULL
       OR v_result.policy_version IS NULL
       OR v_result.is_allowed IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-004: valid context did not return an allowed currency policy';
    END IF;

    EXECUTE $query$
        SELECT currency, policy_version, is_allowed
        FROM public.resolve_transaction_currency(
            '',
            $1,
            $2,
            $3,
            'WALLET',
            $4,
            $5
        )
    $query$
    INTO v_repeat
    USING NULL::UUID, NULL::UUID, v_customer_id, NULL::TEXT, v_context;

    IF v_repeat.is_allowed IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-005: invalid transaction context was allowed';
    END IF;

    EXECUTE $query$
        SELECT currency, policy_version, is_allowed
        FROM public.resolve_transaction_currency(
            'CARD_PURCHASE',
            $1,
            $2,
            $3,
            'WALLET',
            $4,
            $5
        )
    $query$
    INTO v_repeat
    USING NULL::UUID, NULL::UUID, v_customer_id, NULL::TEXT, v_context;

    IF v_result.currency IS DISTINCT FROM v_repeat.currency
       OR v_result.policy_version IS DISTINCT FROM v_repeat.policy_version
       OR v_result.is_allowed IS DISTINCT FROM v_repeat.is_allowed THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-006: identical transaction context returned different policy results';
    END IF;

    SELECT pg_get_functiondef(p.oid)
    INTO v_function_definition
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'resolve_transaction_currency'
    AND pg_get_function_identity_arguments(p.oid) = 'text, uuid, uuid, uuid, text, text, jsonb';

    IF v_function_definition ILIKE '%network_packages.currency%'
       OR v_function_definition ILIKE '%min_stock_alert%'
       OR v_function_definition ILIKE '%pkg.currency%' THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-007: resolver depends on retired package currency fields';
    END IF;

    -- A valid YER policy is allowed; an inline fallback is not. The decision
    -- must be backed by an auditable policy record and its version.
    IF v_function_definition NOT ILIKE '%fin_policy_rules%'
       OR v_function_definition NOT ILIKE '%policy_version%' THEN
        RAISE EXCEPTION
            'CURRENCY-CONTRACT-008: resolver is not backed by a versioned policy record';
    END IF;

    RAISE NOTICE 'Currency resolver behavioral assertions passed';
END;
$$;