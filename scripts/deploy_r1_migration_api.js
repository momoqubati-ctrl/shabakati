/**
 * ==============================================================================
 * Shabakati Platform - Program R1 Migration Deployment Engine
 * Script: deploy_r1_migration_api.js
 * 
 * Execution Context: GitHub Actions CI/CD Runner ONLY
 * Authentication: process.env.SUPABASE_ACCESS_TOKEN (GitHub Secret ONLY)
 * Target: POST https://api.supabase.com/v1/projects/{ref}/database/migrations
 * 
 * Strict Guarantees:
 *   1. ZERO fallback channels: Uses ONLY official Management API migrations endpoint.
 *   2. ZERO SQL query execution for migration application.
 *   3. ZERO manual manipulation of schema_migrations ledger.
 *   4. ZERO CLI credentials (--token disallowed).
 *   5. EXACT identity matching: version === '20260919000001' && name === 'program_r1_retailer_identity'.
 *   6. Fail-Closed: Any network or API error halts execution immediately.
 * ==============================================================================
 */

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const process = require('node:process');

const ROOT_DIR = path.resolve(__dirname, '..');

// Enforce environment credentials only (No CLI arguments allowed)
const PROJECT_REF = process.env.SUPABASE_PROJECT_REF || 'ymmxajugsmydoqyrvkjv';
const ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN;

const MIGRATION_VERSION = '20260919000001';
const MIGRATION_NAME = 'program_r1_retailer_identity';
const MIGRATION_FILE_NAME = `${MIGRATION_VERSION}_${MIGRATION_NAME}.sql`;
const MIGRATION_PATH = path.join(ROOT_DIR, 'supabase', 'migrations', MIGRATION_FILE_NAME);

const MANAGEMENT_API_BASE = 'https://api.supabase.com/v1';

async function callManagementApi(endpoint, method = 'GET', body = null, description = 'API Request') {
    const url = `${MANAGEMENT_API_BASE}${endpoint}`;
    const headers = {
        'Authorization': `Bearer ${ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent': 'Shabakati-CI-R1-Deployer/3.1'
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

async function main() {
    console.log('======================================================================');
    console.log(' [CI/CD] PROGRAM R1 OFFICIAL MIGRATION DEPLOYMENT ENGINE (v3.1)');
    console.log('======================================================================');

    // 1. Validate Credentials Presence (NO logging of token value)
    if (!ACCESS_TOKEN) {
        throw new Error('[FATAL] Missing SUPABASE_ACCESS_TOKEN in runner environment.');
    }
    if (!PROJECT_REF) {
        throw new Error('[FATAL] Missing SUPABASE_PROJECT_REF in runner environment.');
    }
    console.log('✓ Credentials verified in runner environment [CREDENTIALS REDACTED].');
    console.log(`✓ Target Project Ref: ${PROJECT_REF}`);

    // 2. Validate Migration File & Checksum
    if (!fs.existsSync(MIGRATION_PATH)) {
        throw new Error(`[FATAL] Migration file not found: ${MIGRATION_PATH}`);
    }
    const fileBuffer = fs.readFileSync(MIGRATION_PATH);
    const rawSha256 = crypto.createHash('sha256').update(fileBuffer).digest('hex');
    console.log(`✓ Migration File: ${MIGRATION_FILE_NAME} (${fileBuffer.length} bytes)`);
    console.log(`✓ Raw-byte SHA-256: ${rawSha256}`);

    const EXPECTED_RAW_SHA256 = '34d9e5d3e4da04fc2b58da34bec79a18d6e3872b81a1237a32993743b26f4510';
    if (rawSha256 !== EXPECTED_RAW_SHA256) {
        throw new Error(
            `[RAW HASH INTEGRITY FAILURE] Migration file raw-byte hash '${rawSha256}' does NOT match frozen RC-1 hash '${EXPECTED_RAW_SHA256}'. Execution is FAIL-CLOSED BLOCKED.`
        );
    }
    console.log(`✓ RC-1 Cryptographic Freeze Verified (Raw Bytes): EXACT MATCH (${EXPECTED_RAW_SHA256})`);

    // 3. Preflight Project Identity with Supabase Management API
    console.log('... Verifying Project Identity with Management API...');
    const projRes = await callManagementApi(`/projects/${encodeURIComponent(PROJECT_REF)}`, 'GET', null, 'Get Project Info');
    const project = projRes.data;
    console.log(`✓ Confirmed Project: ${project.name} (Status: ${project.status}, Region: ${project.region})`);

    // 4. Query Remote Migrations History via Official Management API ONLY
    console.log('... Querying applied migrations list via GET /database/migrations...');
    const listRes = await callManagementApi(
        `/projects/${encodeURIComponent(PROJECT_REF)}/database/migrations`,
        'GET',
        null,
        'Fetch Official Migrations List'
    );
    const appliedMigrations = Array.isArray(listRes.data) ? listRes.data : [];
    console.log(`✓ Retrieved ${appliedMigrations.length} applied migration(s) from remote ledger.`);

    // 5. EXACT Identity Verification
    const existing = appliedMigrations.find(m => String(m.version || '') === MIGRATION_VERSION);
    if (existing) {
        const remoteVersion = String(existing.version);
        const remoteName = String(existing.name || '');
        console.log(`ℹ Detected migration version ${MIGRATION_VERSION} in remote ledger.`);

        // EXACT matching only (No startsWith, No includes)
        if (remoteVersion === MIGRATION_VERSION && remoteName === MIGRATION_NAME) {
            console.log(`✓ EXACT Migration Identity MATCH: Version [${remoteVersion}] and Name [${remoteName}].`);
            console.log('✓ Migration was previously applied successfully. No action required.');
            process.exit(0);
        } else {
            throw new Error(
                `[CRITICAL LEDGER MISMATCH] Remote migration ${remoteVersion} has name '${remoteName}', ` +
                `which DOES NOT EXACTLY MATCH expected '${MIGRATION_NAME}'. Execution is FAIL-CLOSED BLOCKED.`
            );
        }
    }

    // 6. Apply Migration via Official Management API POST /database/migrations
    console.log(`... Applying migration ${MIGRATION_VERSION}_${MIGRATION_NAME} via POST /database/migrations...`);
    const migrationSql = fs.readFileSync(MIGRATION_PATH, 'utf8');

    const applyRes = await callManagementApi(
        `/projects/${encodeURIComponent(PROJECT_REF)}/database/migrations`,
        'POST',
        {
            name: MIGRATION_NAME,
            query: migrationSql
        },
        `Apply Migration ${MIGRATION_VERSION}`
    );

    console.log(`✓ Official Supabase Management API applied migration in ${applyRes.durationMs}ms.`);

    // 7. Post-Apply Exact Confirmation via GET /database/migrations
    console.log('... Verifying post-apply registration in remote ledger via GET /database/migrations...');
    const verifyListRes = await callManagementApi(
        `/projects/${encodeURIComponent(PROJECT_REF)}/database/migrations`,
        'GET',
        null,
        'Verify Post-Apply Migrations List'
    );
    const postMigrations = Array.isArray(verifyListRes.data) ? verifyListRes.data : [];
    const confirmed = postMigrations.find(m => String(m.version || '') === MIGRATION_VERSION && String(m.name || '') === MIGRATION_NAME);

    if (!confirmed) {
        throw new Error(
            `[FATAL] Migration ${MIGRATION_VERSION} with exact name '${MIGRATION_NAME}' ` +
            `could not be confirmed in remote ledger after application.`
        );
    }

    console.log(`✓ Migration ${confirmed.version} (${confirmed.name}) successfully confirmed in official Supabase ledger.`);
}

main().catch(err => {
    console.error(`\n❌ DEPLOYMENT FAILURE: ${err.message}`);
    process.exit(1);
});
