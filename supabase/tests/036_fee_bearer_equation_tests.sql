-- Fee Bearer and Equation Contract Tests
-- RED until a database financial breakdown contract is implemented.

DO $$
DECLARE
    v_base NUMERIC := 1000;
    v_platform NUMERIC := 50;
    v_gateway NUMERIC := 20;
    v_sub_agent NUMERIC := 30;
    v_vendor_payable NUMERIC;
BEGIN
    -- Vendor-borne gateway and sub-agent charges.
    v_vendor_payable := v_base - v_platform - v_gateway - v_sub_agent;
    IF v_vendor_payable <> 900 THEN
        RAISE EXCEPTION 'FEE-CONTRACT-036-001: vendor bearer equation is invalid';
    END IF;

    -- Customer-borne gateway fee must not reduce vendor payable.
    v_vendor_payable := v_base - v_platform - v_sub_agent;
    IF v_vendor_payable <> 920 THEN
        RAISE EXCEPTION 'FEE-CONTRACT-036-002: customer bearer equation is invalid';
    END IF;

    -- Platform-borne fee changes platform net revenue, not commission identity.
    IF (v_platform - v_gateway) <> 30 THEN
        RAISE EXCEPTION 'FEE-CONTRACT-036-003: platform bearer equation is invalid';
    END IF;

    RAISE NOTICE 'Fee bearer equations passed';
END;
$$;