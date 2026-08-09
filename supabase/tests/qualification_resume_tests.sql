-- Qualification tests for resume_basgate_purchase_saga currency isolation
-- This script assumes all base migrations have been applied to the test DB.
-- It executes a sequence of tests A..L described in the spec. Any failure raises an exception.

\set ON_ERROR_STOP on

-- Helper: reset relevant tables for each test
CREATE OR REPLACE FUNCTION test_reset() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    -- Clean orders, cards, payment_intents, payments, card_delivery_attempts, order_events
    TRUNCATE public.card_delivery_attempts, public.order_events, public.payment_intents, public.payments, public.orders, public.cards, public.network_packages, public.vendors RESTART IDENTITY CASCADE;
END; $$;

-- Set up baseline vendor and package
SELECT test_reset();
DO $$
DECLARE
  v_vendor_id UUID := gen_random_uuid();
  v_pkg_id UUID := gen_random_uuid();
BEGIN
  INSERT INTO public.vendors(id, name, created_at) VALUES (v_vendor_id, 'VENDOR1', NOW());
  CREATE TEMP TABLE IF NOT EXISTS tmp_vendor(id UUID) ON COMMIT DROP;
  INSERT INTO tmp_vendor(id) VALUES (v_vendor_id);

  INSERT INTO public.network_packages(id, vendor_id, created_at) VALUES (v_pkg_id, v_vendor_id, NOW());
  CREATE TEMP TABLE IF NOT EXISTS tmp_pkg(id UUID) ON COMMIT DROP;
  INSERT INTO tmp_pkg(id) VALUES (v_pkg_id);
END $$;

-- Create a few cards for package
INSERT INTO public.cards(id, package_id, status, created_at) VALUES
  (gen_random_uuid(), (SELECT id FROM tmp_pkg LIMIT 1), 'AVAILABLE', NOW()),
  (gen_random_uuid(), (SELECT id FROM tmp_pkg LIMIT 1), 'AVAILABLE', NOW());

-- Utility to create order
CREATE OR REPLACE FUNCTION mk_order(p_currency TEXT, p_amount NUMERIC, p_status TEXT DEFAULT 'WAITING_PAYMENT') RETURNS UUID LANGUAGE plpgsql AS $$
DECLARE o_id UUID;
BEGIN
  INSERT INTO public.orders(id, package_id, customer_id, total_amount, currency, status, created_at, updated_at)
  VALUES (gen_random_uuid(), (SELECT id FROM tmp_pkg LIMIT 1), gen_random_uuid(), p_amount, p_currency, p_status, NOW(), NOW()) RETURNING id INTO o_id;
  RETURN o_id;
END; $$;

-- Test A: PASS all YER
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-A'; BEGIN PERFORM test_reset();
  o := mk_order('YER', 100.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 100.00, 'YER', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 100.00, 'YER', 'basgate', pid, 'pending');
  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 100.00, 'YER');
  IF r->>'success' <> 'true' THEN RAISE EXCEPTION 'Test A failed: %', r; END IF; END $$;

-- Test B: BLOCK payment_intent USD
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-B';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 50.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 50.00, 'USD', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 50.00, 'YER', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 50.00, 'YER');
  IF r->>'error' IS NULL OR r->>'error' NOT IN ('CURRENCY_INTEGRITY_MISMATCH','AMBIGUOUS_PAYMENT_INTENTS') THEN RAISE EXCEPTION 'Test B failed: expected currency integrity error, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test B failed: side-effects detected after failure';
  END IF;
END $$;

-- Test C: BLOCK payments USD
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-C';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 20.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 20.00, 'YER', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 20.00, 'USD', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 20.00, 'YER');
  IF r->>'error' IS NULL OR r->>'error' NOT IN ('CURRENCY_INTEGRITY_MISMATCH','AMBIGUOUS_PAYMENTS') THEN RAISE EXCEPTION 'Test C failed: expected currency integrity error, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test C failed: side-effects detected after failure';
  END IF;
END $$;

-- Test D: BLOCK verified USD
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-D';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 10.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 10.00, 'YER', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 10.00, 'YER', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 10.00, 'USD');
  IF r->>'error' IS NULL OR r->>'error' <> 'CURRENCY_MISMATCH' THEN RAISE EXCEPTION 'Test D failed: expected CURRENCY_MISMATCH, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test D failed: side-effects detected after failure';
  END IF;
END $$;

-- Test E: BLOCK orders.currency NULL
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-E';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  -- create order with NULL currency
  INSERT INTO public.orders(id, package_id, customer_id, total_amount, currency, status, created_at, updated_at)
    VALUES (gen_random_uuid(), (SELECT id FROM tmp_pkg LIMIT 1), gen_random_uuid(), 5.00, NULL, 'WAITING_PAYMENT', NOW(), NOW()) RETURNING id INTO o;
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 5.00, 'YER', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 5.00, 'YER');
  IF r->>'error' IS NULL OR r->>'error' <> 'CURRENCY_UNKNOWN' THEN RAISE EXCEPTION 'Test E failed: expected CURRENCY_UNKNOWN, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test E failed: side-effects detected after failure';
  END IF;
END $$;

-- Test F: BLOCK verified NULL
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-F';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 7.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 7.00, 'YER', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 7.00, 'YER', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 7.00, NULL);
  IF r->>'error' IS NULL THEN RAISE EXCEPTION 'Test F failed: expected failure when verified is NULL, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test F failed: side-effects detected after failure';
  END IF;
END $$;

-- Test G: PASS when no payment_intent/payments but verified matches orders
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-G'; BEGIN PERFORM test_reset();
  o := mk_order('YER', 3.00);
  -- no payment_intent, no payment
  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 3.00, 'YER');
  IF r->>'success' <> 'true' THEN RAISE EXCEPTION 'Test G failed: %', r; END IF; END $$;

-- Test H: IDEMPOTENCY
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-H'; BEGIN PERFORM test_reset();
  o := mk_order('YER', 1.00, 'COMPLETED');
  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 1.00, 'YER');
  IF r->>'success' <> 'true' THEN RAISE EXCEPTION 'Test H failed: expected idempotent success, got %', r; END IF; END $$;

-- Test I: LATE SUCCESS matching currency
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-I'; BEGIN PERFORM test_reset();
  o := mk_order('YER', 9.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status, provider_order_id) VALUES (gen_random_uuid(), o, 9.00, 'YER', 'CREATED', pid);
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 9.00, 'YER', 'basgate', pid, 'pending');
  -- simulate provider status 1202 by calling resume with verified
  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 9.00, 'YER');
  IF r->>'success' <> 'true' THEN RAISE EXCEPTION 'Test I failed: %', r; END IF; END $$;

-- Test J: LATE SUCCESS currency mismatch
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-J';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 11.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status, provider_order_id) VALUES (gen_random_uuid(), o, 11.00, 'YER', 'CREATED', pid);
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 11.00, 'YER', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 11.00, 'USD');
  IF r->>'error' IS NULL THEN RAISE EXCEPTION 'Test J failed: expected currency mismatch, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test J failed: side-effects detected after failure';
  END IF;
END $$;

-- Test K: AMBIGUOUS_PAYMENT_INTENTS
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-K';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 14.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 14.00, 'YER', 'CREATED');
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 14.00, 'USD', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 14.00, 'YER', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 14.00, 'YER');
  IF r->>'error' IS NULL OR r->>'error' <> 'AMBIGUOUS_PAYMENT_INTENTS' THEN RAISE EXCEPTION 'Test K failed: expected ambiguous payment_intents, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test K failed: side-effects detected after failure';
  END IF;
END $$;

-- Test L: AMBIGUOUS_PAYMENTS
DO $$ DECLARE r JSONB; o UUID; pid TEXT := 'PR-L';
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 16.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 16.00, 'YER', 'CREATED');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 16.00, 'YER', 'basgate', pid, 'pending');
  INSERT INTO public.payments(id, user_id, total_amount, currency, provider, provider_reference, status) VALUES (gen_random_uuid(), gen_random_uuid(), 16.00, 'USD', 'basgate', pid, 'pending');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 16.00, 'YER');
  IF r->>'error' IS NULL OR r->>'error' <> 'AMBIGUOUS_PAYMENTS' THEN RAISE EXCEPTION 'Test L failed: expected ambiguous payments, got %', r; END IF;

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Test L failed: side-effects detected after failure';
  END IF;
END $$;

-- Atomicity checks: ensure failed attempts made no side-effects
DO $$ DECLARE o UUID; pid TEXT := 'PR-ATOMIC'; r JSONB; c_count INTEGER; ev_count INTEGER;
    pi_before INT; pay_before INT; cards_before INT; ev_before INT; journals_before INT; wallets_before NUMERIC;
    pi_after INT; pay_after INT; cards_after INT; ev_after INT; journals_after INT; wallets_after NUMERIC;
BEGIN PERFORM test_reset();
  o := mk_order('YER', 77.00);
  INSERT INTO public.payment_intents(id, order_id, amount, currency, status) VALUES (gen_random_uuid(), o, 77.00, 'USD', 'CREATED');
  SELECT COUNT(*) INTO pi_before FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_before FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_before FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_before FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_before FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_before FROM public.wallets;

  r := public.resume_basgate_purchase_saga(o, gen_random_uuid(), pid, 77.00, 'YER');

  SELECT COUNT(*) INTO pi_after FROM public.payment_intents WHERE order_id = o;
  SELECT COUNT(*) INTO pay_after FROM public.payments WHERE provider_reference = pid;
  SELECT COUNT(*) INTO cards_after FROM public.cards WHERE status IN ('RESERVED','SOLD');
  SELECT COUNT(*) INTO ev_after FROM public.order_events WHERE order_id = o;
  SELECT COUNT(*) INTO journals_after FROM public.fin_journals WHERE reference_type = 'order' AND reference_id = o;
  SELECT COALESCE(SUM(balance),0) INTO wallets_after FROM public.wallets;

  IF pi_before <> pi_after OR pay_before <> pay_after OR cards_before <> cards_after OR ev_before <> ev_after OR journals_before <> journals_after OR wallets_before <> wallets_after THEN
    RAISE EXCEPTION 'Atomicity failed: side-effects observed after refusal';
  END IF;
END $$;

-- Concurrency test hint: This CI run is single-threaded; for concurrency test we provide a guidance script to run locally or in CI matrix.
-- End of tests
\echo 'ALL QUALIFICATION TESTS PASSED'
