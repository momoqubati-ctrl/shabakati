/**
 * ==============================================================================
 * Shabakati Platform - Program R2 Production Deep Contract & RLS Verification
 * Script: run_r2_production_verification.js
 * Version: 1.0.0 (Wholesale Catalog, Offers & Tiered Pricing)
 * 
 * Execution Context: Read-Only Verification (CI/CD or Admin Verification)
 * Mode: 100% STRICTLY READ-ONLY
 *   - ZERO DDL / ZERO DML
 *   - ZERO nextval() / ZERO sequence consumption
 *   - ZERO RPC execution with mutations or side-effects
 *   - PURE metadata, PostgREST contract, and catalog inspection
 * 
 * Target: Production Supabase Database & PostgREST Data API
 * Security: ZERO token logging, ZERO credential fragments in logs or reports.
 * ==============================================================================
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const process = require('node:process');

const ROOT_DIR = path.resolve(__dirname, '..');

// Environment Credentials (Never passed via CLI flags)
const PROJECT_REF = process.env.SUPABASE_PROJECT_REF || 'ymmxajugsmydoqyrvkjv';
const ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN;

const MIGRATION_VERSION = '20260920000001';
const MIGRATION_NAME = 'program_r2_wholesale_catalog_pricing';
const MIGRATION_FILE_NAME = `${MIGRATION_VERSION}_${MIGRATION_NAME}.sql`;
const MIGRATION_PATH = path.join(ROOT_DIR, 'supabase', 'migrations', MIGRATION_FILE_NAME);
const REPORT_PATH = path.join(ROOT_DIR, 'r2_production_audit_report.json');

const PRODUCTION_DATA_API_URL = process.env.SUPABASE_URL || 'https://api.alhawia.store';
const PRODUCTION_ANON_KEY = process.env.SUPABASE_ANON_KEY;

const MANAGEMENT_API_BASE = 'https://api.supabase.com/v1';

async function callManagementApi(endpoint, method = 'GET', body = null, description = 'API Request') {
    if (!ACCESS_TOKEN) {
        return { status: 0, durationMs: 0, data: null, skipped: true };
    }
    const url = `${MANAGEMENT_API_BASE}${endpoint}`;
    const headers = {
        'Authorization': `Bearer ${ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent': 'Shabakati-Production-Verifier/R2'
    };

    const startTime = Date.now();
    let response;
    try {
        response = await fetch(url, {
            method,
            headers,
            body: body ? JSON.stringify(body) : undefined
        });
    } catch (networkErr) {
        throw new Error(`[Network Failure] Failed to reach Supabase Management API (${url}): ${networkErr.message}`);
    }

    const durationMs = Date.now() - startTime;
    const rawText = await response.text();

    let responseData;
    try {
        responseData = JSON.parse(rawText);
    } catch {
        responseData = rawText;
    }

    if (!response.ok) {
        const errorDetail = typeof responseData === 'object' ? JSON.stringify(responseData) : rawText;
        const err = new Error(`[HTTP ${response.status}] ${description} failed: ${errorDetail}`);
        err.status = response.status;
        err.durationMs = durationMs;
        err.data = responseData;
        throw err;
    }

    return {
        status: response.status,
        durationMs,
        data: responseData
    };
}

async function callPostgrest(pathWithQuery, options = {}) {
    if (!PRODUCTION_ANON_KEY) {
        return {
            status: 0,
            durationMs: 0,
            data: { error: 'SUPABASE_ANON_KEY missing in environment' },
            skipped: true
        };
    }
    const url = `${PRODUCTION_DATA_API_URL}/rest/v1${pathWithQuery}`;
    const headers = {
        'apikey': PRODUCTION_ANON_KEY,
        'Authorization': `Bearer ${PRODUCTION_ANON_KEY}`,
        'Content-Type': 'application/json',
        ...(options.headers || {})
    };

    const startTime = Date.now();
    const response = await fetch(url, {
        method: options.method || 'GET',
        headers,
        body: options.body ? JSON.stringify(options.body) : undefined
    });

    const durationMs = Date.now() - startTime;
    const rawText = await response.text();

    let data;
    try {
        data = JSON.parse(rawText);
    } catch {
        data = rawText;
    }

    return {
        status: response.status,
        durationMs,
        data,
        headers: response.headers
    };
}

async function main() {
    console.log('======================================================================');
    console.log(' [READ-ONLY] SHABAKATI PROGRAM R2 PRODUCTION DEEP VERIFICATION');
    console.log('======================================================================');
    console.log(`✓ Timestamp: ${new Date().toISOString()}`);
    console.log(`✓ Target Data API: ${PRODUCTION_DATA_API_URL}`);
    console.log(`✓ Project Ref: ${PROJECT_REF}`);

    if (!PRODUCTION_ANON_KEY) {
        console.error('\n❌ [FATAL] SUPABASE_ANON_KEY is missing in environment.');
        console.error('    Security rule: Must be supplied strictly via GitHub Actions Secret (SUPABASE_ANON_KEY).');
        process.exit(1);
    }

    const report = {
        timestamp: new Date().toISOString(),
        target_api: PRODUCTION_DATA_API_URL,
        project_ref: PROJECT_REF,
        program: 'R2: Wholesale Catalog, Offers & Tiered Pricing',
        migration_version: MIGRATION_VERSION,
        migration_name: MIGRATION_NAME,
        checks: []
    };

    function recordCheck(code, description, status, details = {}) {
        report.checks.push({ code, description, status, details });
        const icon = status === 'PASS' ? '✓' : '❌';
        console.log(` ${icon} [${code}] ${description}: ${status}`);
        if (status !== 'PASS') {
            console.error('    Details:', JSON.stringify(details, null, 2));
        }
    }

    // -------------------------------------------------------------------------
    // CHECK 1: File Checksum & Integrity
    // -------------------------------------------------------------------------
    console.log('\n--- 1. Cryptographic File Integrity Lock ---');
    if (!fs.existsSync(MIGRATION_PATH)) {
        recordCheck('R2-FILE-01', 'Migration file existence', 'FAIL', { path: MIGRATION_PATH });
    } else {
        const fileBuffer = fs.readFileSync(MIGRATION_PATH);
        const actualSha = crypto.createHash('sha256').update(fileBuffer).digest('hex');
        const expectedSha = '179d908b67aea21843991d61b7b2ff309771f6692cf2ba942a0e79678dd1ebda';
        const isMatch = actualSha === expectedSha;
        recordCheck('R2-FILE-01', 'Raw-Byte SHA-256 integrity lock', isMatch ? 'PASS' : 'FAIL', {
            expected: expectedSha,
            actual: actualSha,
            size_bytes: fileBuffer.length
        });
    }

    // -------------------------------------------------------------------------
    // CHECK 2: Remote Migration Ledger Confirmation
    // -------------------------------------------------------------------------
    console.log('\n--- 2. Production Migrations Ledger Verification ---');
    if (!ACCESS_TOKEN) {
        recordCheck('R2-LEDGER-01', 'Migration present in remote ledger', 'FAIL', { reason: 'No SUPABASE_ACCESS_TOKEN provided in environment' });
    } else {
        try {
            const ledgerRes = await callManagementApi(
                `/projects/${PROJECT_REF}/database/migrations`,
                'GET',
                null,
                'Fetch Migrations Ledger'
            );
            const list = Array.isArray(ledgerRes.data)
                ? ledgerRes.data
                : (Array.isArray(ledgerRes.data?.result) ? ledgerRes.data.result : []);
            const r2Migration = list.find(m => {
                const name = (m.name || '').toLowerCase();
                const ver = (m.version || '').toString();
                return name.includes(MIGRATION_NAME) || ver === MIGRATION_VERSION || name.includes(MIGRATION_VERSION);
            });

            if (r2Migration) {
                recordCheck('R2-LEDGER-01', 'Migration present in remote ledger', 'PASS', {
                    version: r2Migration.version,
                    name: r2Migration.name,
                    total_migrations: list.length
                });
            } else {
                recordCheck('R2-LEDGER-01', 'Migration present in remote ledger', 'FAIL', {
                    searched_version: MIGRATION_VERSION,
                    searched_name: MIGRATION_NAME,
                    total_migrations: list.length
                });
            }
        } catch (err) {
            recordCheck('R2-LEDGER-01', 'Migration present in remote ledger', 'FAIL', { error: err.message });
        }
    }

    // -------------------------------------------------------------------------
    // CHECK 3: PostgREST Schema Table Verification & Zero Price Leakage
    // -------------------------------------------------------------------------
    console.log('\n--- 3. PostgREST Tables & Zero Price Leakage Verification ---');
    
    // 3.1: wholesale_catalog_products
    const catRes = await callPostgrest('/wholesale_catalog_products?select=id,network_id,network_package_id,currency,status&limit=5');
    if (catRes.status === 200 && Array.isArray(catRes.data) && catRes.data.length === 0) {
        recordCheck('R2-TABLE-01', 'wholesale_catalog_products table live & 0 rows for anon', 'PASS', {
            http_status: catRes.status,
            rows_returned: catRes.data.length
        });
    } else {
        recordCheck('R2-TABLE-01', 'wholesale_catalog_products table live & 0 rows for anon', 'FAIL', {
            http_status: catRes.status,
            response: catRes.data
        });
    }

    // 3.2: wholesale_merchant_offers
    const offRes = await callPostgrest('/wholesale_merchant_offers?select=id,merchant_id,catalog_product_id,min_order_quantity,step_quantity,cost_floor_price,currency,status&limit=5');
    if (offRes.status === 200 && Array.isArray(offRes.data) && offRes.data.length === 0) {
        recordCheck('R2-TABLE-02', 'wholesale_merchant_offers table live & 0 rows for anon', 'PASS', {
            http_status: offRes.status,
            rows_returned: offRes.data.length
        });
    } else {
        recordCheck('R2-TABLE-02', 'wholesale_merchant_offers table live & 0 rows for anon', 'FAIL', {
            http_status: offRes.status,
            response: offRes.data
        });
    }

    // 3.3: wholesale_offer_tiers
    const tierRes = await callPostgrest('/wholesale_offer_tiers?select=id,offer_id,min_quantity,max_quantity,unit_price,currency&limit=5');
    if (tierRes.status === 200 && Array.isArray(tierRes.data) && tierRes.data.length === 0) {
        recordCheck('R2-TABLE-03', 'wholesale_offer_tiers table live & 0 rows for anon', 'PASS', {
            http_status: tierRes.status,
            rows_returned: tierRes.data.length
        });
    } else {
        recordCheck('R2-TABLE-03', 'wholesale_offer_tiers table live & 0 rows for anon', 'FAIL', {
            http_status: tierRes.status,
            response: tierRes.data
        });
    }

    // -------------------------------------------------------------------------
    // CHECK 4: Amendment 1 Proof - Single Source of Truth (Zero Price Copy)
    // -------------------------------------------------------------------------
    console.log('\n--- 4. Amendment 1 Verification: Zero Price Copy to Catalog ---');
    const negPriceRes = await callPostgrest('/wholesale_catalog_products?select=base_retail_price&limit=1');
    if (negPriceRes.status === 400 && negPriceRes.data && negPriceRes.data.code === '42703') {
        recordCheck('R2-AMEND-01', 'base_retail_price strictly excluded from wholesale_catalog_products', 'PASS', {
            http_status: negPriceRes.status,
            error_code: negPriceRes.data.code,
            message: negPriceRes.data.message
        });
    } else {
        recordCheck('R2-AMEND-01', 'base_retail_price strictly excluded from wholesale_catalog_products', 'FAIL', {
            http_status: negPriceRes.status,
            response: negPriceRes.data
        });
    }

    // -------------------------------------------------------------------------
    // CHECK 5: Amendment 2 Proof - Strict Cost Floor Column Proof
    // -------------------------------------------------------------------------
    console.log('\n--- 5. Amendment 2 Verification: Strict Cost Floor Column ---');
    const costFloorRes = await callPostgrest('/wholesale_merchant_offers?select=cost_floor_price&limit=1');
    if (costFloorRes.status === 200) {
        recordCheck('R2-AMEND-02', 'cost_floor_price confirmed present on wholesale_merchant_offers', 'PASS', {
            http_status: costFloorRes.status
        });
    } else {
        recordCheck('R2-AMEND-02', 'cost_floor_price confirmed present on wholesale_merchant_offers', 'FAIL', {
            http_status: costFloorRes.status,
            response: costFloorRes.data
        });
    }

    // -------------------------------------------------------------------------
    // CHECK 6: Read-Only RPC Guard Verification
    // -------------------------------------------------------------------------
    console.log('\n--- 6. RPC calculate_wholesale_quote Read-Only & Auth Guard ---');
    const dummyOfferId = '00000000-0000-0000-0000-000000000001';
    const rpcRes = await callPostgrest('/rpc/calculate_wholesale_quote', {
        method: 'POST',
        body: {
            p_offer_id: dummyOfferId,
            p_quantity: 10
        }
    });

    // Anonymous caller MUST be rejected with UNAUTHENTICATED
    if (rpcRes.status >= 400 && (JSON.stringify(rpcRes.data).includes('UNAUTHENTICATED') || rpcRes.status === 401 || rpcRes.status === 403)) {
        recordCheck('R2-RPC-01', 'calculate_wholesale_quote live & rejects unauthenticated requests', 'PASS', {
            http_status: rpcRes.status,
            rejection_message: rpcRes.data.message || rpcRes.data
        });
    } else {
        recordCheck('R2-RPC-01', 'calculate_wholesale_quote live & rejects unauthenticated requests', 'FAIL', {
            http_status: rpcRes.status,
            response: rpcRes.data
        });
    }

    // -------------------------------------------------------------------------
    // CHECK 7: Official Retail Price Dependency (network_packages.price)
    // -------------------------------------------------------------------------
    console.log('\n--- 7. Official Retail Price Source Dependency Verification ---');
    const npRes = await callPostgrest('/network_packages?select=id,name,price,status,network_id&limit=5');
    if (npRes.status === 200 && Array.isArray(npRes.data)) {
        recordCheck('R2-DEP-01', 'network_packages.price source contract verified live on production', 'PASS', {
            http_status: npRes.status,
            rows_visible: npRes.data.length,
            note: 'Confirmed columns contract analysis on live PostgREST'
        });
    } else {
        recordCheck('R2-DEP-01', 'network_packages.price source contract verified live on production', 'FAIL', {
            http_status: npRes.status,
            response: npRes.data
        });
    }

    // -------------------------------------------------------------------------
    // CHECK 8: R1 Dependency Integrity Proof (Retailers & Wholesale Merchant RPC)
    // -------------------------------------------------------------------------
    console.log('\n--- 8. Program R1 Identity Dependencies Integrity ---');
    const r1RetRes = await callPostgrest('/retailers?select=id,retailer_code,status&limit=1');
    const r1RpcRes = await callPostgrest('/rpc/is_wholesale_merchant', {
        method: 'POST',
        body: { p_user_id: '00000000-0000-0000-0000-000000000001' }
    });

    const isR1Intact = (r1RetRes.status === 200) && (r1RpcRes.status === 200);
    recordCheck('R2-DEP-02', 'R1 Identity & Governance contracts remain live and unmutated', isR1Intact ? 'PASS' : 'FAIL', {
        retailers_http: r1RetRes.status,
        is_wholesale_merchant_http: r1RpcRes.status,
        is_wholesale_merchant_result: r1RpcRes.data
    });

    // -------------------------------------------------------------------------
    // AUDIT REPORT PERSISTENCE
    // -------------------------------------------------------------------------
    const passCount = report.checks.filter(c => c.status === 'PASS').length;
    const failCount = report.checks.filter(c => c.status === 'FAIL').length;
    const skippedCount = report.checks.filter(c => c.status === 'SKIPPED').length;
    const isFullAcceptance = (report.checks.length === 10) && (passCount === 10) && (failCount === 0) && (skippedCount === 0);

    report.summary = {
        total_checks: report.checks.length,
        passed: passCount,
        failed: failCount,
        skipped: skippedCount,
        not_run: 0,
        overall_status: isFullAcceptance ? 'ACCEPTANCE_PASS' : (failCount > 0 ? 'ACCEPTANCE_FAIL' : 'ACCEPTANCE_PENDING')
    };

    fs.writeFileSync(REPORT_PATH, JSON.stringify(report, null, 2), 'utf-8');
    console.log(`\n✓ Audit report saved to: ${REPORT_PATH}`);

    if (!isFullAcceptance) {
        if (failCount > 0) {
            console.error(`\n❌ [AUDIT FAILED]: ${failCount} of ${report.checks.length} checks failed.`);
        } else if (skippedCount > 0) {
            console.error(`\n⚠️ [AUDIT INCOMPLETE]: ${skippedCount} check(s) were SKIPPED. Full 10/10 PASS required for ACCEPTANCE_PASS.`);
        } else {
            console.error(`\n⚠️ [AUDIT INCOMPLETE]: Expected 10 checks with 10 PASS, got ${passCount} passed out of ${report.checks.length}.`);
        }
        process.exit(1);
    }

    console.log('\n======================================================================');
    console.log(` [AUDIT COMPLETE] ALL 10/10 PRODUCTION CHECKS PASSED (0 FAILURES, 0 SKIPPED)`);
    console.log('======================================================================');
}

main().catch(err => {
    console.error('\n❌ [VERIFIER FATAL]:', err.message);
    process.exit(1);
});
