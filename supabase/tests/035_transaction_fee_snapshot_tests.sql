-- Transaction Financial Snapshot Contract Tests
-- RED until payment intents persist immutable policy results.

DO $$
DECLARE
    v_required_columns TEXT[] := ARRAY[
        'currency',
        'currency_policy_version',
        'platform_commission_expected',
        'platform_commission_policy_version',
        'gateway_fee_expected',
        'gateway_fee_policy_version',
        'sub_agent_commission_expected',
        'sub_agent_commission_policy_version'
    ];
    v_missing TEXT[];
BEGIN
    SELECT ARRAY_AGG(required_column ORDER BY required_column)
    INTO v_missing
    FROM unnest(v_required_columns) AS required(required_column)
    WHERE NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'public'
          AND c.table_name = 'payment_intents'
          AND c.column_name = required.required_column
    );

    IF v_missing IS NOT NULL THEN
        RAISE EXCEPTION 'FEE-CONTRACT-035-001: payment intent snapshot columns missing: %',
            ARRAY_TO_STRING(v_missing, ', ');
    END IF;

    IF NOT EXISTS (
        SELECT 1
                FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
                JOIN pg_proc p ON p.oid = t.tgfoid
        WHERE n.nspname = 'public'
          AND c.relname = 'payment_intents'
          AND NOT t.tgisinternal
          AND (t.tgtype & 16) <> 0
                    AND pg_get_functiondef(p.oid) ILIKE '%RAISE EXCEPTION%'
                    AND pg_get_functiondef(p.oid) ILIKE '%snapshot%'
    ) THEN
        RAISE EXCEPTION 'FEE-CONTRACT-035-002: payment intent snapshot has no update guard';
    END IF;

    RAISE NOTICE 'Transaction financial snapshot contract passed';
END;
$$;