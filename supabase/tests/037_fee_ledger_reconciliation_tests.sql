-- Fee Ledger and Reconciliation Contract Tests
-- RED until fee separation and variance reconciliation are implemented.

DO $$
DECLARE
    v_issue_constraint TEXT;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.fin_coa_accounts
        WHERE code = '4001'
          AND LOWER(name) LIKE '%commission%'
    ) THEN
        RAISE EXCEPTION 'FEE-CONTRACT-037-001: commission revenue account is missing';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM public.fin_coa_accounts
        WHERE code = '5001'
          AND LOWER(name) LIKE '%gateway%'
    ) THEN
        RAISE EXCEPTION 'FEE-CONTRACT-037-002: gateway fee expense account is missing';
    END IF;

    SELECT pg_get_constraintdef(oid)
    INTO v_issue_constraint
    FROM pg_constraint
    WHERE conname = 'valid_reconciliation_issue';

    IF v_issue_constraint IS NULL
       OR v_issue_constraint NOT ILIKE '%CURRENCY_MISMATCH%'
       OR v_issue_constraint NOT ILIKE '%FEE_MISMATCH%' THEN
        RAISE EXCEPTION 'FEE-CONTRACT-037-003: reconciliation fee/currency issue types are missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'fin_post_payment_settlement'
          AND pg_get_functiondef(p.oid) ILIKE '%platform_commission + v_op.gateway_fee%'
    ) THEN
        RAISE EXCEPTION 'FEE-CONTRACT-037-004: gateway fee is still posted as commission revenue';
    END IF;

    RAISE NOTICE 'Fee ledger and reconciliation contract passed';
END;
$$;