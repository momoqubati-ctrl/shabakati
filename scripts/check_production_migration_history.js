/**
 * ==============================================================================
 * Shabakati Platform - Program R1 Production Migration History Checker
 * Script: check_production_migration_history.js
 * 
 * Mode: 100% PURE READ-ONLY HTTP GET
 * Target: GET https://api.supabase.com/v1/projects/{ref}/database/migrations
 * Zero DDL / Zero Mutations / Zero Database Connections
 * ==============================================================================
 */

const process = require('node:process');

const PROJECT_REF = process.env.SUPABASE_PROJECT_REF;
const ACCESS_TOKEN = process.env.SUPABASE_ACCESS_TOKEN;

const MIGRATION_VERSION = '20260919000001';
const MIGRATION_NAME = 'program_r1_retailer_identity';

const MANAGEMENT_API_BASE = 'https://api.supabase.com/v1';

async function checkHistory() {
    if (!PROJECT_REF || !ACCESS_TOKEN) {
        console.log(`environment: production`);
        console.log(`migration_version: ${MIGRATION_VERSION}`);
        console.log(`migration_name: ${MIGRATION_NAME}`);
        console.log(`status: UNKNOWN`);
        console.error('\n[MISSING_CREDENTIALS] SUPABASE_PROJECT_REF or SUPABASE_ACCESS_TOKEN not set in environment.');
        process.exit(1);
    }

    const url = `${MANAGEMENT_API_BASE}/projects/${encodeURIComponent(PROJECT_REF)}/database/migrations`;
    const headers = {
        'Authorization': `Bearer ${ACCESS_TOKEN}`,
        'Content-Type': 'application/json',
        'User-Agent': 'Shabakati-Migration-History-Checker/1.0'
    };

    let response;
    try {
        response = await fetch(url, { method: 'GET', headers });
    } catch (err) {
        console.log(`environment: production`);
        console.log(`migration_version: ${MIGRATION_VERSION}`);
        console.log(`migration_name: ${MIGRATION_NAME}`);
        console.log(`status: UNKNOWN`);
        console.error(`\n[NETWORK_ERROR] Failed to query Management API: ${err.message}`);
        process.exit(1);
    }

    if (!response.ok) {
        console.log(`environment: production`);
        console.log(`migration_version: ${MIGRATION_VERSION}`);
        console.log(`migration_name: ${MIGRATION_NAME}`);
        console.log(`status: UNKNOWN`);
        console.error(`\n[HTTP_ERROR] Management API returned status ${response.status}`);
        process.exit(1);
    }

    const raw = await response.text();
    let data;
    try {
        data = JSON.parse(raw);
    } catch {
        data = [];
    }

    const migrations = Array.isArray(data) ? data : [];
    const entry = migrations.find(m => String(m.version || '') === MIGRATION_VERSION);

    console.log(`environment: production`);
    console.log(`migration_version: ${MIGRATION_VERSION}`);
    console.log(`migration_name: ${MIGRATION_NAME}`);

    if (entry) {
        console.log(`status: APPLIED`);
        console.log(`remote_name: ${entry.name || 'unnamed'}`);
    } else {
        console.log(`status: NOT_APPLIED`);
    }
}

checkHistory();
