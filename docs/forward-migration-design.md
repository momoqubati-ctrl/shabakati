# Forward Migration Design

**Status:** Design only; SQL implementation not created
**Predecessor:** `2482845 Add currency and fee contract tests`
**Scope:** Currency and fee contract hardening after the frozen baseline

## 1. Guardrails

This migration must be additive and forward-only.

```text
Historical migrations: immutable
Legacy purchase RPCs: unchanged
purchase-api: unchanged in this migration
network_packages: no currency or fee columns
Production: untouched until reviewed and released
```

The migration must not add compatibility overloads that preserve an old
financial commit boundary. Old signatures must be revoked or superseded only
after every approved caller is migrated and the permissions are checked.

## 2. Ordered Phases

### Phase A: Policy Contract Storage

Add versioned policy records for the four independent policy domains:

```text
currency
platform commission
gateway fee
sub-agent commission
```

Required policy semantics:

```text
policy_version INT NOT NULL
event_type
scope
priority
effective_from
effective_to
is_enabled
```

Resolution must reject zero or multiple effective rules. Equal-priority rows
must never be selected by implicit row order.

The existing `fin_policy_rules` remains a historical commission-policy source.
The forward design must either extend it with an explicit policy domain or add
a separate policy relation. It must not silently reinterpret the old table.

### Phase B: Resolver RPCs

Create four side-effect-free RPCs with the frozen signatures:

```text
resolve_transaction_currency(
  text, uuid, uuid, uuid, text, text, jsonb
)

resolve_platform_commission(
  text, uuid, uuid, numeric, text, jsonb
)

resolve_gateway_fee(
  text, text, text, numeric, text, uuid, uuid, jsonb
)

resolve_sub_agent_commission(
  uuid, uuid, uuid, text, numeric, text, jsonb
)
```

All returned decisions must include an integer `policy_version` and
`is_allowed`. A resolver must not write operational or financial state.

The implementation must return an explicit rejection for:

```text
invalid context
unsupported currency
inactive policy
expired policy
missing policy
ambiguous policy
invalid scope
```

### Phase C: Relationship and Snapshot Storage

Add a versioned Network Owner to Sub-Agent relationship policy with owner-only
mutation semantics. The exact table name is intentionally not frozen by the
contract tests; the relation must contain, at minimum:

```text
network_id
vendor_id or network-owner identity
sub_agent_id
commission_type
commission_rate and/or fixed_amount
policy_version
effective_from
effective_to
status
```

Extend `payment_intents` with immutable expected financial snapshot fields:

```text
currency_policy_version
platform_commission_expected
platform_commission_policy_version
gateway_fee_expected
gateway_fee_policy_version
sub_agent_commission_expected
sub_agent_commission_policy_version
```

Snapshot values are resolved once before provider initiation. Retries,
webhooks, reconciliation, and settlement read the snapshot and do not resolve
policies again.

### Phase D: Provider Facts

Extend `payment_gateway_operations` with provider facts only:

```text
gateway_fee_actual
gateway_fee_currency
```

Expected gateway fee remains on the Payment Intent snapshot. Provider response
and request payloads may retain raw evidence, but policy resolution must not
read provider facts.

### Phase E: Reconciliation

Extend reconciliation issue semantics to cover:

```text
CURRENCY_MISMATCH
FEE_MISMATCH
```

The reconciliation layer compares expected snapshot values with provider facts:

```text
expected fee vs actual fee -> variance -> ACCEPT | REVIEW | REJECT
```

Amount and currency mismatches remain hard verification failures. Fee variance
must not silently overwrite the expected snapshot.

### Phase F: Financial Commit Boundary

The final commit boundary must accept currency explicitly:

```text
wallet_commit_purchase(
  customer_id,
  vendor_id,
  amount,
  commission,
  currency,
  ubtr
)
```

The implementation must:

```text
select wallet by owner + owner_type + currency
select COA accounts by owner + account type + currency
write journal.currency explicitly
write every ledger_entry.currency explicitly
preserve debit = credit
separate commission revenue from gateway fee expense
post sub-agent payable separately
```

The old five-argument function must not remain as an executable bypass after
callers and grants are migrated.

### Phase G: Saga and API Wiring

Only after the resolver, snapshot, and commit boundaries are available:

1. Update `execute_wallet_purchase_saga` to use currency-scoped wallet lookup.
2. Update `resume_basgate_purchase_saga` to compare order, payment intent, and
   provider currency before reservation or ledger posting.
3. Update request idempotency to bind the original currency and snapshot.
4. Update `purchase-api` to select only package-owned columns and obtain the
   transaction currency from the resolver.
5. Preserve UBTR across retries and webhook resumes.

These are implementation steps in the same approved release sequence, but they
must not be mixed with historical migration edits.

## 3. Permissions

Every new resolver and financial boundary requires explicit grants:

```text
resolvers: callable only by the approved service boundary
financial commit: service_role only
policy mutation: Platform or Network Owner according to policy ownership
Sub-Agent: read/accept/operate only
```

After caller migration, inspect `pg_proc` and routine grants to ensure there is
no old overload or public execution path.

## 4. Deployment and Rollback

The migration is not production-ready until:

1. `030-037` are reviewed against the final SQL.
2. Existing YER rows have a deliberate backfill policy.
3. Existing payment intents and operations have explicit snapshot semantics.
4. Ledger and reconciliation regression tests pass.
5. Idempotency and UBTR replay tests pass.
6. Staging validation completes through the approved Git/GitHub release path.

Rollback must not delete posted journals or rewrite historical snapshots. A
failed rollout is handled by disabling new policy activation and preserving
existing immutable financial records for reconciliation.

## 5. Implementation Gate

Do not create the SQL migration until these design questions are explicitly
resolved:

```text
policy storage: extend fin_policy_rules or separate relation
policy version lifecycle and immutability
exact snapshot column nullability and defaults
provider fee source and currency semantics
fee variance tolerance and reconciliation authority
COA account identity for sub-agent payable
backfill behavior for existing transactions
```

The current repository state remains:

```text
contract tests: committed / RED
forward migration: not created
purchase-api: untouched
production database: untouched
```
