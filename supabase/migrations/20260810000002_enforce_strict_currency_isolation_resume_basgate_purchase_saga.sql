-- Proposal: Strict Currency Isolation for resume_basgate_purchase_saga
-- Date: 2026-08-10
-- This is a surgical migration proposal. It preserves the original RPC
-- behaviour and injects a minimal set of currency-integrity checks.
-- DO NOT APPLY automatically; review and test in a qualification DB first.

CREATE OR REPLACE FUNCTION public.resume_basgate_purchase_saga(
    p_order_id       UUID,
    p_customer_id    UUID,
    p_provider_order_id VARCHAR(255),
    p_verified_amount   NUMERIC,
    p_verified_currency VARCHAR(10)
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_order           public.orders%ROWTYPE;
    v_card_id         UUID;
    v_ubtr_id         VARCHAR(255);
    v_package_id      UUID;
    v_delivery_id     UUID;
    -- currency integrity vars
    v_order_currency  VARCHAR(32);
    v_pi_currencies   TEXT[];
    v_pi_currency     TEXT;
    v_payment_currencies TEXT[];
    v_payment_currency TEXT;
BEGIN
    -- ── Guard: Fetch and Lock Order ──────────────────────────────────────────
    SELECT * INTO v_order
    FROM public.orders
    WHERE id = p_order_id
    FOR UPDATE; -- Pessimistic lock prevents concurrent webhook replay

    IF NOT FOUND THEN
        RETURN jsonb_build_object('success', false, 'error', 'Order not found: ' || p_order_id);
    END IF;

    -- ── Guard: Idempotency — already completed orders are silently accepted ──
    IF v_order.status IN ('COMPLETED', 'DELIVERED', 'CANCELLED') THEN
        RETURN jsonb_build_object(
            'success', true,
            'message', 'Order already in terminal state: ' || v_order.status,
            'order_id', p_order_id
        );
    END IF;

    -- ── Guard: Only WAITING_PAYMENT orders can be resumed ───────────────────
    IF v_order.status != 'WAITING_PAYMENT' THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Cannot resume order in state: ' || v_order.status
        );
    END IF;

    -- ── Guard: Amount Integrity (preserved from original RPC) ───────────────
    IF ABS(v_order.total_amount - p_verified_amount) > 0.01 THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', format('Amount mismatch: expected %s, verified %s', v_order.total_amount, p_verified_amount)
        );
    END IF;

    -- === CURRENCY ISOLATION CHECKS (SURGICAL ADDITION) ===
    -- 1) Canonical currency is orders.currency (must exist)
    v_order_currency := NULLIF(TRIM(COALESCE(v_order.currency, '')), '');
    IF v_order_currency IS NULL THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CURRENCY_UNKNOWN',
            'message', 'orders.currency missing for order ' || p_order_id
        );
    END IF;

    -- 2) If there are payment_intents for this order, their currency values MUST all equal orders.currency.
    --    If multiple distinct currencies appear, return an ambiguity error rather than picking one.
    SELECT array_remove(array_agg(DISTINCT NULLIF(TRIM(COALESCE(pi.currency, '')), '')), '')
    INTO v_pi_currencies
    FROM public.payment_intents pi
    WHERE pi.order_id = p_order_id;

    IF v_pi_currencies IS NOT NULL THEN
        IF array_length(v_pi_currencies, 1) > 1 THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'AMBIGUOUS_PAYMENT_INTENTS',
                'message', format('Multiple distinct payment_intents currencies for order %s: %s', p_order_id, array_to_string(v_pi_currencies, ','))
            );
        ELSE
            v_pi_currency := v_pi_currencies[1];
            IF lower(v_pi_currency) <> lower(v_order_currency) THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'CURRENCY_INTEGRITY_MISMATCH',
                    'message', format('payment_intents.currency %s does not match orders.currency %s', v_pi_currency, v_order_currency)
                );
            END IF;
        END IF;
    END IF;

    -- 3) If there are payments records for the given provider reference, all their currencies MUST equal orders.currency.
    --    If multiple distinct currencies exist, return an ambiguity error.
    SELECT array_remove(array_agg(DISTINCT NULLIF(TRIM(COALESCE(pay.currency, '')), '')), '')
    INTO v_payment_currencies
    FROM public.payments pay
    WHERE pay.provider_reference = p_provider_order_id;

    IF v_payment_currencies IS NOT NULL THEN
        IF array_length(v_payment_currencies, 1) > 1 THEN
            RETURN jsonb_build_object(
                'success', false,
                'error', 'AMBIGUOUS_PAYMENTS',
                'message', format('Multiple distinct payments currencies for provider_reference %s: %s', p_provider_order_id, array_to_string(v_payment_currencies, ','))
            );
        ELSE
            v_payment_currency := v_payment_currencies[1];
            IF lower(v_payment_currency) <> lower(v_order_currency) THEN
                RETURN jsonb_build_object(
                    'success', false,
                    'error', 'CURRENCY_INTEGRITY_MISMATCH',
                    'message', format('payments.currency %s does not match orders.currency %s', v_payment_currency, v_order_currency)
                );
            END IF;
        END IF;
    END IF;

    -- 4) The provider-verified currency MUST match orders.currency
    IF lower(trim(coalesce(p_verified_currency, ''))) <> lower(v_order_currency) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'CURRENCY_MISMATCH',
            'message', format('verified currency %s does not match orders.currency %s', coalesce(p_verified_currency, ''), v_order_currency)
        );
    END IF;
    -- === end currency checks ===

    -- =====================================================================
    -- Proceed with original implementation (unaltered below this point)
    -- (The remainder of the function is identical to the original RPC and
    -- retained here to preserve behaviour: locking, idempotency, UBTR,
    -- card reservation, order update, payment_intent update, events, ledger.)
    -- =====================================================================

    v_package_id := v_order.package_id;

    -- ── Step 1: Generate UBTR for this settlement ────────────────────────────
    v_ubtr_id := 'UBTR-' || to_char(NOW(), 'YYYYMMDDHH24MISS') || '-' || floor(random() * 9000 + 1000)::text;

    -- ── Step 2: Reserve an available card (atomic — prevents concurrent reservation) ──
    UPDATE public.cards
    SET status      = 'RESERVED',
        reserved_at = NOW(),
        updated_at  = NOW()
    WHERE id = (
        SELECT id FROM public.cards
        WHERE package_id = v_package_id
          AND status = 'AVAILABLE'
        ORDER BY created_at ASC
        LIMIT 1
        FOR UPDATE SKIP LOCKED -- Critical: skip rows locked by concurrent transactions
    )
    RETURNING id INTO v_card_id;

    IF v_card_id IS NULL THEN
        RETURN jsonb_build_object('success', false, 'error', 'No available cards for package: ' || v_package_id);
    END IF;

    -- ── Step 3: Mark Order as COMPLETED ─────────────────────────────────────
    UPDATE public.orders
    SET status         = 'COMPLETED',
        completed_at   = NOW(),
        updated_at     = NOW()
    WHERE id = p_order_id;

    -- ── Step 4: Update Payment Intent status ─────────────────────────────────
    UPDATE public.payment_intents
    SET status               = 'SETTLED',
        provider_confirmed_at = NOW(),
        updated_at           = NOW()
    WHERE order_id = p_order_id
      AND provider_order_id = p_provider_order_id;

    -- ── Step 5: Record Card Delivery Attempt ─────────────────────────────────
    INSERT INTO public.card_delivery_attempts (ubtr_id, order_id, card_id, customer_id, status, attempted_at)
    VALUES (v_ubtr_id, p_order_id, v_card_id, p_customer_id, 'DELIVERED', NOW())
    RETURNING id INTO v_delivery_id;

    -- Mark card as SOLD
    UPDATE public.cards
    SET status     = 'SOLD',
        sold_at    = NOW(),
        updated_at = NOW()
    WHERE id = v_card_id;

    -- ── Step 6: Emit Realtime Event (Flutter WebSocket will receive this) ────
    INSERT INTO public.order_events (ubtr_id, order_id, event_type, payload, created_at)
    VALUES (
        v_ubtr_id,
        p_order_id,
        'ORDER_COMPLETED',
        jsonb_build_object(
            'ubtr', v_ubtr_id,
            'payment_method', 'BASGATE',
            'provider_order_id', p_provider_order_id,
            'verified_amount', p_verified_amount,
            'currency', p_verified_currency,
            'card_id', v_card_id,
            'delivery_id', v_delivery_id
        ),
        NOW()
    );

    -- ── Step 7: Post Purchase Ledger Entry ───────────────────────────────────
    PERFORM public.wallet_commit_purchase(
        p_customer_id,
        (SELECT vendor_id FROM public.network_packages WHERE id = v_package_id LIMIT 1),
        p_verified_amount,
        p_verified_amount * 0.03, -- 3% platform commission
        v_ubtr_id
    );

    RETURN jsonb_build_object(
        'success',   true,
        'ubtr',      v_ubtr_id,
        'order_id',  p_order_id,
        'card_id',   v_card_id,
        'delivery_id', v_delivery_id,
        'status',    'COMPLETED'
    );

EXCEPTION
    WHEN OTHERS THEN
        -- Full rollback is automatic in plpgsql on exception.
        RETURN jsonb_build_object(
            'success', false,
            'error',   SQLERRM,
            'sqlstate', SQLSTATE
        );
END;
$$;


    -- ─── 2. cancel_pending_order ──────────────────────────────────────────────────
    -- Called by bas-webhook when BasGate confirms payment FAILED.
    -- Atomically: cancels order → releases any reserved cards → emits PAYMENT_FAILED event.

    CREATE OR REPLACE FUNCTION public.cancel_pending_order(
        p_order_id UUID,
        p_reason   TEXT DEFAULT 'Payment failed or rejected'
    ) RETURNS JSONB
    LANGUAGE plpgsql
    SECURITY DEFINER
    SET search_path = public
    AS $$
    DECLARE
        v_order   public.orders%ROWTYPE;
        v_ubtr_id VARCHAR(255);
    BEGIN
        SELECT * INTO v_order
        FROM public.orders
        WHERE id = p_order_id
        FOR UPDATE;

        IF NOT FOUND THEN
            RETURN jsonb_build_object('success', false, 'error', 'Order not found');
        END IF;

        -- Idempotency: already cancelled is fine
        IF v_order.status = 'CANCELLED' THEN
            RETURN jsonb_build_object('success', true, 'message', 'Order already cancelled');
        END IF;

        -- Only cancel if still in a pre-completion state
        IF v_order.status IN ('COMPLETED', 'DELIVERED') THEN
            RETURN jsonb_build_object('success', false, 'error', 'Cannot cancel completed order');
        END IF;

        v_ubtr_id := 'UBTR-CANCEL-' || to_char(NOW(), 'YYYYMMDDHH24MISS');

        -- Release any cards that were reserved for this order
        UPDATE public.cards
        SET status     = 'AVAILABLE',
            reserved_at = NULL,
            updated_at = NOW()
        WHERE id IN (
            SELECT card_id FROM public.card_delivery_attempts
            WHERE order_id = p_order_id AND status = 'RESERVED'
        );

        -- Cancel the order
        UPDATE public.orders
        SET status       = 'CANCELLED',
            cancelled_at = NOW(),
            cancel_reason = p_reason,
            updated_at   = NOW()
        WHERE id = p_order_id;

        -- Emit PAYMENT_FAILED Realtime event so Flutter can show error UI
        INSERT INTO public.order_events (ubtr_id, order_id, event_type, payload, created_at)
        VALUES (
            v_ubtr_id,
            p_order_id,
            'PAYMENT_FAILED',
            jsonb_build_object('reason', p_reason, 'order_id', p_order_id),
            NOW()
        );

        RETURN jsonb_build_object('success', true, 'order_id', p_order_id, 'status', 'CANCELLED');

    EXCEPTION
        WHEN OTHERS THEN
            RETURN jsonb_build_object('success', false, 'error', SQLERRM);
    END;
    $$;
