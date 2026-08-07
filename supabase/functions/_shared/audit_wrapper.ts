import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.39.0';
import { corsHeaders } from './cors.ts';

export type SourceApp = 'client_app' | 'merchant_app' | 'admin_app' | 'edge_function' | 'db_trigger' | 'system_cron';

export function sanitizePayload(data: any): any {
  if (!data || typeof data !== 'object') return data;
  if (Array.isArray(data)) return data.map(sanitizePayload);

  const masked: Record<string, any> = {};
  const sensitiveKeys = [
    'password', 'pass', 'otp', 'pin', 'token', 'access_token', 'refresh_token',
    'authorization', 'secret', 'client_secret', 'card_secret', 'encrypted_code',
    'card_code', 'cvv', 'card_number'
  ];

  for (const [key, val] of Object.entries(data)) {
    if (sensitiveKeys.includes(key.toLowerCase())) {
      masked[key] = '***MASKED***';
    } else if (typeof val === 'object' && val !== null) {
      masked[key] = sanitizePayload(val);
    } else {
      masked[key] = val;
    }
  }

  return masked;
}

export function withAuditLogging(
  functionName: string,
  sourceApp: SourceApp,
  handler: (req: Request, supabase: any, auditCtx: { traceId: string; userId?: string }) => Promise<Response>
) {
  return async (req: Request): Promise<Response> => {
    if (req.method === 'OPTIONS') {
      return new Response('ok', { headers: corsHeaders });
    }

    const startTime = performance.now();
    const traceId = req.headers.get('x-trace-id') || `TRC_${Date.now()}_${Math.random().toString(36).substring(2, 9)}`;
    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const supabaseServiceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const supabase = createClient(supabaseUrl, supabaseServiceKey);

    let userId: string | undefined = undefined;
    const authHeader = req.headers.get('Authorization');
    if (authHeader) {
      const token = authHeader.replace('Bearer ', '');
      try {
        const { data: { user } } = await supabase.auth.getUser(token);
        if (user) userId = user.id;
      } catch (_) {}
    }

    const url = new URL(req.url);
    const reqMethod = req.method;
    const reqPath = url.pathname;
    const reqParams = Object.fromEntries(url.searchParams.entries());

    let reqBody: any = {};
    const clonedReq = req.clone();
    try {
      reqBody = await clonedReq.json();
    } catch (_) {}

    const reqHeaders: Record<string, string> = {};
    req.headers.forEach((val, key) => {
      reqHeaders[key] = val;
    });

    let resStatusCode = 200;
    let resBody: any = {};
    let isSuccess = true;
    let errorMessage: string | null = null;
    let response: Response;

    try {
      response = await handler(req, supabase, { traceId, userId });
      resStatusCode = response.status;
      isSuccess = resStatusCode >= 200 && resStatusCode < 400;

      const clonedRes = response.clone();
      try {
        resBody = await clonedRes.json();
        if (!isSuccess && resBody.error) {
          errorMessage = typeof resBody.error === 'string' ? resBody.error : JSON.stringify(resBody.error);
        }
      } catch (_) {}
    } catch (err: any) {
      isSuccess = false;
      resStatusCode = 500;
      errorMessage = err.message || String(err);
      resBody = { error: errorMessage };
      response = new Response(
        JSON.stringify({ error: errorMessage }),
        { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
      );
    } finally {
      const executionTimeMs = Math.round((performance.now() - startTime) * 100) / 100;

      // إرسال سجل التدقيق في الخلفية دون تعطيل استجابة العميل (Fire and forget async background task)
      (async () => {
        try {
          await supabase.rpc('record_system_global_audit_log', {
            p_trace_id: traceId,
            p_source_app: sourceApp,
            p_user_id: userId || null,
            p_action_name: functionName,
            p_request_path: reqPath,
            p_request_method: reqMethod,
            p_request_headers: sanitizePayload(reqHeaders),
            p_request_body: sanitizePayload(reqBody),
            p_request_params: reqParams,
            p_response_status_code: resStatusCode,
            p_response_body: sanitizePayload(resBody),
            p_is_success: isSuccess,
            p_error_message: errorMessage,
            p_execution_time_ms: executionTimeMs,
            p_ip_address: reqHeaders['x-forwarded-for'] || reqHeaders['cf-connecting-ip'] || null,
            p_user_agent: reqHeaders['user-agent'] || null,
            p_app_version: reqHeaders['x-app-version'] || null,
            p_device_id: reqHeaders['x-device-id'] || null,
          });
        } catch (logErr) {
          console.warn('Audit wrapper background logging warning:', logErr);
        }
      })();
    }

    // إلحاق trace_id في ترويسات الرد للعميل
    const newHeaders = new Headers(response.headers);
    newHeaders.set('x-trace-id', traceId);
    return new Response(response.body, {
      status: response.status,
      statusText: response.statusText,
      headers: newHeaders
    });
  };
}
