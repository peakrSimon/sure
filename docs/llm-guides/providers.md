# Provider guidance

This fork has no bank, brokerage, crypto-exchange, on-chain wallet or property
valuation integrations: every account is created and updated manually, or through
CSV/PDF imports. `Account#linked?` is always false (see
[`Account::Linkable`](../../app/models/account/linkable.rb)). Do not reintroduce
account aggregation providers.

The remaining external providers are concept providers selected through
[`Provider::Registry`](../../app/models/provider/registry.rb): exchange rates,
security prices, LLMs and classification. Read [architecture](architecture.md) for
concepts and `Provided` concerns, and [adding a securities provider](adding-a-securities-provider.md)
for the complete securities workflow.

## Support diagnostics

When a provider call or import path encounters a recoverable error, suspicious
partial response or other support-relevant incident, prefer
[`DebugLogEntry.capture`](../../app/models/debug_log_entry.rb) over `Rails.logger.*`
so operators can inspect it in the super-admin `/settings/debug` UI.

- Include `category`, `level`, `message`, `source`, `provider_key` and useful
  structured `metadata`.
- Attach `family`, `account` or `user` whenever available so support can filter
  and trace the affected records.
- Reserve raw Rails logging for low-value local noise; incidents operators need
  to investigate belong in the debug log.

## Transaction metadata

`Transaction#extra` is shown as raw JSON under "Additional details" on the
transaction page. The pending-transaction machinery in
[`Transaction`](../../app/models/transaction.rb) (`PENDING_PROVIDERS`, pending
scopes) is retained but inert: no remaining import path writes pending flags.
