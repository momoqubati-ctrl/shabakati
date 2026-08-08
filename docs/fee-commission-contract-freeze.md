# Fee and Commission Contract Freeze

**Status:** Contract baseline only; no runtime implementation
**Scope:** Currency, platform commission, gateway fee, and sub-agent commission
**Frozen assets:** Historical migrations, legacy purchase paths, and `purchase-api`

## 1. Domain Boundary

Transaction charges are first-class financial components. Each charge has an
independent policy, owner, bearer, recipient, currency, version, and settlement
meaning.

```text
Transaction Charges
  - GATEWAY_FEE
  - PLATFORM_COMMISSION
  - SUB_AGENT_COMMISSION
```

Resolvers produce policy decisions only. They must not insert or update orders,
payment intents, provider operations, wallets, journals, ledger entries, or
settlement records.

```text
Resolver -> Policy decision -> Transaction snapshot -> Financial operation
```

## 2. Resolver Contracts

All resolvers receive a transaction context. The context must be able to carry
the fields below even when a particular policy does not use every field:

```text
event_type
network_id
vendor_id
customer_id
sub_agent_id
payment_method
provider
transaction_amount
currency
requested_currency
transaction_context
```

Every resolver must return an explicit decision and policy version. Missing,
ambiguous, inactive, invalid, or unsupported policy data returns
`is_allowed = false`; it must never silently become a zero fee or default
currency.

### 2.1 Currency Resolver

```text
resolve_transaction_currency(
  event_type,
  network_id,
  vendor_id,
  customer_id,
  payment_method,
  requested_currency,
  transaction_context
)
```

Required result:

```text
currency       TEXT
  policy_version INT
is_allowed     BOOLEAN
```

The resolved currency becomes the immutable transaction currency when the
order/payment intent is created. `network_packages` is never a currency source.

### 2.2 Platform Commission Resolver

```text
resolve_platform_commission(
  event_type,
  network_id,
  vendor_id,
  transaction_amount,
  currency,
  transaction_context
)
```

Required result:

```text
fee_type             = PLATFORM_COMMISSION
commission_type      PERCENTAGE | FIXED | future extensible types
rate
fixed_amount
calculated_amount
currency
recipient            = PLATFORM
fee_bearer           policy-defined
  policy_version INT
is_allowed
```

The policy owner is the Platform. `vendors.commission_rate` is not a substitute
for this contract when a versioned policy snapshot is required.

### 2.3 Gateway Fee Resolver

```text
resolve_gateway_fee(
  provider,
  payment_method,
  event_type,
  transaction_amount,
  currency,
  network_id,
  vendor_id,
  transaction_context
)
```

Required result:

```text
fee_type             = GATEWAY_FEE
fee_calculation_type PERCENTAGE | FIXED | NONE | future extensible types
expected_amount
currency
recipient
fee_bearer           CUSTOMER | PLATFORM | VENDOR | SUB_AGENT | SPLIT
  policy_version INT
is_allowed
```

The resolver returns expected fee only. Actual provider fee is a provider fact,
not a policy result.

### 2.4 Sub-Agent Commission Resolver

```text
resolve_sub_agent_commission(
  network_id,
  vendor_id,
  sub_agent_id,
  event_type,
  transaction_amount,
  currency,
  transaction_context
)
```

Required result:

```text
fee_type             = SUB_AGENT_COMMISSION
commission_type      PERCENTAGE | FIXED | future extensible types
rate
fixed_amount
calculated_amount
currency
recipient            = SUB_AGENT
fee_bearer           = VENDOR by current default policy
  policy_version INT
is_allowed
```

The policy owner is the Network Owner. A Sub-Agent may view, accept, and
operate under a policy, but may not create, modify, approve, version, or change
its beneficiary or settlement account.

## 3. Policy Resolution Rules

An applicable policy must be uniquely and deterministically resolved.

```text
0 applicable rules  -> is_allowed = false
1 applicable rule   -> resolve and snapshot
>1 applicable rules -> is_allowed = false
```

Applicability must account for scope, enabled state, effective period, policy
version, and priority. Equal-priority ambiguity must not be resolved by an
implicit database row order.

Policy versions are part of the transaction audit record. A policy change must
affect new transactions only; it must not alter an existing snapshot.

## 4. Transaction Financial Snapshot

The snapshot is created after policy resolution and before provider initiation.

```text
ORDER
  - canonical currency
  - commercial context

PAYMENT INTENT
  - base amount
  - currency
  - platform commission expected
  - gateway fee expected
  - sub-agent commission expected
  - currency policy version
  - platform commission policy version
  - gateway fee policy version
  - sub-agent commission policy version
```

The snapshot is immutable for retries, webhook handling, reconciliation, and
settlement. Those stages must not re-resolve policies.

## 5. Provider Operation and Reconciliation

`payment_gateway_operations` represents provider facts and provider lifecycle,
not a second policy resolution.

Expected values remain in the transaction snapshot. Actual values are captured
from the provider when available:

```text
gateway_fee_expected
gateway_fee_actual
gateway_fee_variance
provider_amount
provider_currency
```

Expected and actual values must never be overwritten with one another.

```text
expected = 20 YER
actual   = 25 YER
variance = 5 YER
```

Fee mismatch is resolved through reconciliation policy:

```text
ACCEPT | REVIEW | REJECT
```

Amount and currency mismatches remain hard financial verification failures.

## 6. Fee Bearer Mathematics

Let:

```text
B = base transaction amount
P = platform commission
G = gateway fee
S = sub-agent commission
```

### CUSTOMER

```text
customer_paid = B + G
vendor_base    = B
```

Gateway fee is not deducted from vendor payable.

### PLATFORM

```text
customer_paid = B
vendor_base    = B
platform_net   = P - G
```

Platform Commission remains revenue and Gateway Fee remains expense.

### VENDOR

```text
customer_paid  = B
vendor_payable = B - P - G - S
```

### SUB_AGENT

The current default is that Sub-Agent Commission is borne by the Vendor:

```text
customer_paid    = B
vendor_share     = B - P - G - S
sub_agent_payable = S
```

### SPLIT

No single split formula is frozen. A split policy must explicitly define the
shares and their bearer semantics before it can be implemented or tested.

## 7. Ledger Contract

The ledger must preserve the financial meaning of each charge:

```text
PLATFORM_COMMISSION -> Commission Revenue (COA 4001)
GATEWAY_FEE         -> Gateway Fee Expense (COA 5001)
SUB_AGENT_COMMISSION -> Sub-Agent Payable
```

Gateway Fee must never be posted as Commission Revenue. Every journal and entry
must use the transaction currency and remain balanced:

```text
journal.currency = ledger_entry.currency = transaction.currency
total debits = total credits
```

## 8. Compatibility and Freeze Rules

The following remain untouched until contract tests and a forward migration are
approved:

```text
Historical migrations
Legacy card_categories purchase RPCs
purchase-api
Production database
```

No currency or fee column is added to `network_packages`. No legacy RPC is
removed, overloaded, or redirected as part of this contract freeze.

## 9. Repository Change Control

All actions that modify repository artifacts must use the authorized Git/GitHub
workflow. This includes SQL tests, migrations, RPCs, Edge Functions,
application code, schema changes, configuration, documentation, and generated
artifacts.

The following rules are mandatory:

1. No direct production database modification is permitted.
2. No migration may be executed against production merely to make a test pass.
3. Every implementation change must be created as a tracked repository change.
4. Every change must be reviewed through Git diff.
5. Every change must be committed through the authorized Git/GitHub workflow.
6. Every change must be validated before deployment.
7. Deployment must use the approved release path.
8. Historical migrations remain immutable.
9. The production database remains untouched until the approved forward migration
  is reviewed and explicitly released.

## 10. Test Suite After Contract Freeze

```text
030/031  Currency resolver contract and behavior
032      Fee policy resolver contracts and ownership
033      Gateway fee expected/actual behavior
034      Sub-agent commission ownership and settlement
035      Transaction snapshot immutability
036      Fee reconciliation and variance resolution
037      Fee ledger separation and balance invariants
```

The tests must be written against these contracts before runtime RPCs or schema
changes are introduced.