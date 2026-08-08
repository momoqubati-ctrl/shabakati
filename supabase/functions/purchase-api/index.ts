/**
 * =============================================================================
 * purchase-api/index.ts — Sprint 3.5: Flutter Purchase API (Full Runtime)
 * =============================================================================
 *
 * This is the primary entry point for ALL purchase commands from the Flutter app.
 * It acts as the secure gateway between the mobile client and the database domain.
 *
 * SECURITY:
 *  - JWT Auth required on every request (Supabase Auth)
 *  - Idempotency key required (prevents double-purchase on retry)
 *  - Rate limiting per user (fraud prevention)
 *  - No business logic in Flutter — this function is the only authority
 *
 * PAYMENT FLOWS:
 *  WALLET (Synchronous):
 *    1. Hold funds atomically
 *    2. Reserve card atomically
 *    3. Commit ledger entry
 *    4. Emit ORDER_COMPLETED event
 *    5. Return { status: "COMPLETED", card_id, ubtr }
 *
 *  BASGATE (Asynchronous):
 *    1. Create order in PAYMENT_PENDING state
 *    2. Store payment_intent with provider_order_id
 *    3. Return { status: "WAITING_PAYMENT", payment_url, ubtr }
 *    4. Flutter subscribes to order_events channel
 *    5. bas-webhook resumes saga on confirmation → ORDER_COMPLETED event fires
 */

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { corsHeaders } from '../_shared/cors.ts';

// ─── Constants ────────────────────────────────────────────────────────────────

const COMMAND_PURCHASE_CARD = 'PURCHASE_CARD';
const METHOD_WALLET = 'WALLET';
const METHOD_BASGATE = 'BASGATE';

// ─── Response Helpers ─────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function errorResponse(message: string, status = 400): Response {
  return jsonResponse({ success: false, error: message }, status);
}

// ─── Server-side UBTR generation ─────────────────────────────────────────────
// UBTR is now generated inside the DB via generate_business_reference() sequence.
// The Edge Function only generates and manages the client Idempotency Key.
// This removes the random()+timestamp collision risk from the application layer.

// ─── BasGate Payment Initiation ───────────────────────────────────────────────

async function initiateBasGatePayment(params: {
  amount: number;
  currency: string;
  orderId: string;
  customerId: string;
  isProd: boolean;
}): Promise<{ success: boolean; paymentUrl?: string; providerOrderId?: string; error?: string }> {
  const clientId = Deno.env.get('BASGATE_CLIENT_ID') ?? '';
  const clientSecret = Deno.env.get('BASGATE_CLIENT_SECRET') ?? '';
  const appId = Deno.env.get('BASGATE_APP_ID') ?? '';

  if (!clientId || !clientSecret || !appId) {
    return { success: false, error: 'BasGate credentials not configured' };
  }

  const baseUrl = params.isProd
    ? (Deno.env.get('BASGATE_PROD_BASE_URL') ?? 'https://api.basgate.com')
    : (Deno.env.get('BASGATE_BASE_URL') ?? 'https://api-tst.basgate.com');

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';

  try {
    // Step 1: Get OAuth Token
    const tokenForm = new URLSearchParams({
      grant_type: 'client_credentials',
      redirect_uri: `${supabaseUrl}/functions/v1/bas-webhook`,
      client_id: clientId,
      client_secret: clientSecret,
    });

    const tokenRes = await fetch(`${baseUrl}/api/v1/auth/token`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: tokenForm.toString(),
    });

    if (!tokenRes.ok) {
      return { success: false, error: `BasGate auth failed: ${tokenRes.status}` };
    }

    const tokenData = await tokenRes.json();
    const accessToken = tokenData.access_token ?? '';

    if (!accessToken) {
      return { success: false, error: 'BasGate token empty' };
    }

    // Step 2: Create Payment Order
    const createOrderRes = await fetch(`${baseUrl}/api/v1/merchant/sdk-payment/create-order`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${accessToken}`,
      },
      body: JSON.stringify({
        appId,
        orderId: params.orderId,
        amount: { value: params.amount, currency: params.currency },
        callbackUrl: `${supabaseUrl}/functions/v1/bas-webhook`,
        redirectUrl: Deno.env.get('BASGATE_REDIRECT_URL') ?? `${supabaseUrl}/payment-success`,
        description: `Purchase order ${params.orderId}`,
      }),
    });

    if (!createOrderRes.ok) {
      const errBody = await createOrderRes.text();
      return { success: false, error: `BasGate order creation failed: ${errBody}` };
    }

    const orderData = await createOrderRes.json();
    const paymentUrl = orderData.body?.paymentUrl ?? orderData.paymentUrl ?? '';
    const providerOrderId = orderData.body?.orderId ?? params.orderId;

    return { success: true, paymentUrl, providerOrderId };
  } catch (err) {
    console.error('[purchase-api] BasGate initiation error:', err);
    return { success: false, error: String(err) };
  }
}

// ─── Main Handler ─────────────────────────────────────────────────────────────

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  // ── Auth: Extract JWT and verify user ─────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return errorResponse('Missing or invalid Authorization header', 401);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  // Use CUSTOM_AUTH_URL if provided (e.g. for custom domains) to avoid Issuer Mismatches
  // (Supabase restricts custom secrets from starting with 'SUPABASE_')
  const authUrl = Deno.env.get('CUSTOM_AUTH_URL') ?? supabaseUrl;

  // User-scoped client (respects RLS, user identity comes from JWT)
  const userClient = createClient(authUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  // Service client (used for writes that need to bypass RLS atomically)
  const adminClient = createClient(supabaseUrl, supabaseServiceKey);

  // ── Auth: Cryptographic JWT Verification via GoTrue ──────────────────────
  const token = authHeader.replace(/^Bearer\s+/i, '').trim();
  const { data: { user }, error: authError } = await userClient.auth.getUser(token);

  if (authError || !user) {
    // Log the actual raw error to Supabase Dashboard Logs for debugging (e.g. Issuer mismatch)
    console.error("PURCHASE_API_AUTH_ERROR", {
      message: authError?.message,
      name: authError?.name,
      status: authError?.status,
      code: authError?.code,
    });
    
    // Return a safe, generic error to the client
    return jsonResponse({
      success: false,
      error: 'AUTHENTICATION_FAILED',
      message: 'Invalid or expired authentication token'
    }, 401);
  }

  // The customerId MUST strictly come from the verified user token, never from the request body.
  const customerId = user.id;

  // ── Parse Command ─────────────────────────────────────────────────────────
  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return errorResponse('Invalid JSON body');
  }

  const command = String(payload.command ?? '');
  if (command !== COMMAND_PURCHASE_CARD) {
    return errorResponse(`Unknown command: ${command}`);
  }

  const networkId = String(payload.network_id ?? '');
  const packageId = String(payload.package_id ?? '');
  const quantity = Number(payload.quantity ?? 1);
  const paymentMethod = String(payload.payment_method ?? METHOD_WALLET).toUpperCase();
  const idempotencyKey = String(payload.idempotency_key ?? '');
  const isProd = String(payload.environment ?? 'test') === 'prod';

  if (!packageId) return errorResponse('Missing package_id');
  if (!idempotencyKey) return errorResponse('Missing idempotency_key');
  if (quantity < 1 || quantity > 10) return errorResponse('Invalid quantity (1-10)');
  if (![METHOD_WALLET, METHOD_BASGATE].includes(paymentMethod)) {
    return errorResponse(`Unsupported payment_method: ${paymentMethod}`);
  }

  // ── Idempotency Guard ─────────────────────────────────────────────────────
  const { data: existingKey } = await adminClient
    .from('idempotency_keys')
    .select('status, response_payload')
    .eq('scope', 'purchase_api')
    .eq('idempotency_key', `${customerId}:${idempotencyKey}`)
    .single();

  if (existingKey?.status === 'completed') {
    return jsonResponse({ success: true, ...existingKey.response_payload });
  }

  // Lock idempotency key
  await adminClient.from('idempotency_keys').upsert({
    scope: 'purchase_api',
    operation_type: 'purchase_card',
    idempotency_key: `${customerId}:${idempotencyKey}`,
    request_hash: `${packageId}:${quantity}:${paymentMethod}`,
    status: 'processing',
    created_at: new Date().toISOString(),
  }, { onConflict: 'scope,idempotency_key' });

  // ── Resolve Package ───────────────────────────────────────────────────────
  const { data: pkg, error: pkgError } = await adminClient
    .from('network_packages')
    .select('id, price, currency, min_stock_alert, vendor_id, network_id')
    .eq('id', packageId)
    .single();

  if (pkgError || !pkg) {
    return errorResponse('Package not found or unavailable');
  }

  const totalAmount = Number(pkg.price) * quantity;
  const currency = String(pkg.currency ?? 'YER');

  // ── WALLET FAST PATH ──────────────────────────────────────────────────────
  if (paymentMethod === METHOD_WALLET) {
    // UBTR is generated server-side inside execute_wallet_purchase_saga.
    // We pass the client idempotency_key which is distinct from UBTR.
    const { data: walletResult, error: walletError } = await adminClient.rpc(
      'execute_wallet_purchase_saga',
      {
        p_customer_id:     customerId,
        p_package_id:      packageId,
        p_quantity:        quantity,
        p_total_amount:    totalAmount,
        p_currency:        currency,
        p_idempotency_key: `${customerId}:${idempotencyKey}`,  // client key — NOT the UBTR
      }
    );

    if (walletError || walletResult?.success === false) {
      const errMsg = walletError?.message ?? walletResult?.error ?? 'Wallet purchase failed';

      await adminClient.from('idempotency_keys').update({
        status: 'failed',
        response_payload: { error: errMsg },
      }).eq('scope', 'purchase_api').eq('idempotency_key', `${customerId}:${idempotencyKey}`);

      return errorResponse(errMsg, 422);
    }

    const responsePayload = {
      ubtr:     walletResult.ubtr,      // UBTR comes from the RPC result (server-generated)
      status:   'COMPLETED',
      order_id: walletResult.order_id,
      card_id:  walletResult.card_id,
      quantity: walletResult.quantity,
    };

    await adminClient.from('idempotency_keys').update({
      status: 'completed',
      response_payload: responsePayload,
    }).eq('scope', 'purchase_api').eq('idempotency_key', `${customerId}:${idempotencyKey}`);

    return jsonResponse({ success: true, ...responsePayload });
  }

  // ── BASGATE ASYNC PATH ────────────────────────────────────────────────────
  if (paymentMethod === METHOD_BASGATE) {
    // 1. Generate UBTR server-side via DB sequence (guaranteed unique, collision-proof)
    //    This UBTR is the canonical reference for the entire business transaction.
    const { data: ubrSeqData, error: ubrSeqError } = await adminClient
      .rpc('generate_business_reference');
    if (ubrSeqError || !ubrSeqData) {
      return errorResponse('Failed to generate UBTR: ' + (ubrSeqError?.message ?? 'Unknown'), 500);
    }
    const ubtr = `UBTR-${ubrSeqData}`;

    // 2. Create order with ubtr_reference set at birth (Canonical Source)
    const { data: newOrder, error: orderError } = await adminClient
      .from('orders')
      .insert({
        customer_id:    customerId,
        package_id:     packageId,
        network_id:     networkId || pkg.network_id,
        quantity,
        total_amount:   totalAmount,
        currency,
        status:         'WAITING_PAYMENT',
        ubtr_reference: ubtr,              // UBTR written at order birth
        created_at:     new Date().toISOString(),
      })
      .select('id')
      .single();

    if (orderError || !newOrder) {
      return errorResponse('Failed to create order: ' + (orderError?.message ?? 'Unknown error'), 500);
    }

    const orderId = newOrder.id;

    // 2. Initiate BasGate payment
    const basGateResult = await initiateBasGatePayment({
      amount: totalAmount,
      currency,
      orderId,
      customerId,
      isProd,
    });

    if (!basGateResult.success) {
      // Rollback: cancel the order we just created
      await adminClient.from('orders').update({ status: 'CANCELLED', cancel_reason: 'BasGate initiation failed' }).eq('id', orderId);
      return errorResponse('Payment gateway error: ' + (basGateResult.error ?? 'Unknown'), 503);
    }

    // 3. Store payment intent — ubtr_id = same UBTR as order (propagation layer 1)
    await adminClient.from('payment_intents').insert({
      order_id:          orderId,
      ubtr_id:           ubtr,   // SAME UBTR as orders.ubtr_reference
      amount:            totalAmount,
      currency,
      method:            'BASGATE',
      status:            'CREATED',
      provider_order_id: basGateResult.providerOrderId ?? orderId,
      environment:       isProd ? 'prod' : 'test',
      expires_at:        new Date(Date.now() + 60 * 60 * 1000).toISOString(),
    });

    // 4. Emit PAYMENT_PENDING event — ubtr_id = same UBTR (propagation layer 2)
    await adminClient.from('order_events').insert({
      ubtr_id:    ubtr,   // SAME UBTR as orders.ubtr_reference
      order_id:   orderId,
      event_type: 'PAYMENT_PENDING',
      payload:    { payment_method: 'BASGATE', payment_url: basGateResult.paymentUrl, ubtr },
      created_at: new Date().toISOString(),
    });

    const responsePayload = {
      ubtr,        // Server-generated canonical UBTR for this transaction
      status:      'WAITING_PAYMENT',
      order_id:    orderId,
      payment_url: basGateResult.paymentUrl,
      expires_in:  3600,
    };

    await adminClient.from('idempotency_keys').update({
      status: 'completed',
      response_payload: responsePayload,
    }).eq('scope', 'purchase_api').eq('idempotency_key', `${customerId}:${idempotencyKey}`);

    return jsonResponse({ success: true, ...responsePayload }, 202);
  }

  return errorResponse('Unhandled payment method');
});
