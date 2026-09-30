# MuleMart Inventory API: Architecture

MuleMart Inventory API is a **MuleSoft Process API** running on Mule Runtime 4.7.0. It gives one governed view of inventory data that lives in four places: a MySQL warehouse database, regional CSV feeds, Salesforce, and an ActiveMQ messaging broker. The API contract is written first in RAML, and APIKit routes each request to a flow based on that contract. All the application logic is in one file, `src/main/mule/inventory-api.xml`, which has about 1,400 lines.

## 1. High-level picture

```
   Clients (Postman / consumers)          Regional CSV drops
            │ HTTP :8081/api/*                    │ file:listener (polls every 10s)
            ▼                                     ▼
 ┌─────────────────────────────────────────────────────────────┐
 │  API Gateway autodiscovery (apiId 21165822)                 │
 │  HTTP Listener → APIKit Router (RAML contract)              │
 │     ├─ CRUD flows  (/inventory, /inventory/{itemId})        │
 │     ├─ Read flows  (/summary, list w/ filters, /health)     │
 │     ├─ Async batch flows (/bulk, /sync, CSV listener)       │
 │     └─ Shared sub-flows + InventoryLib.dwl                  │
 │  Object Store caches · Secure Properties · Global errors    │
 └───────┬───────────────────┬───────────────────┬─────────────┘
         ▼                   ▼                   ▼
   MySQL (mulemart)     Salesforce          ActiveMQ (tcp://localhost:61616)
   inventory,           Inventory__c        procurement.alert.queue
   inventory_audit      (upsert on itemId)  inventory.update.queue
```

## 2. Layers

| Layer | Implementation | Responsibility |
|---|---|---|
| **Contract / API** | `src/main/resources/api/inventory-api.raml` (published to Exchange), `apikit:config` | Defines resources, types and validation. APIKit sends each verb+path to a flow named by its convention, e.g. `put:\inventory\(itemId):application\json:inventory-api-config` |
| **Entry / routing** | `inventory-api-main` (HTTP listener on `0.0.0.0:8081`, path `/api/*`), `inventory-api-console` | Receives requests, runs APIKit routing, and maps APIKit and connectivity errors to HTTP status codes |
| **Business logic** | `src/main/resources/InventoryLib.dwl` | Holds the core rules, shared by every flow: `calculateTotal`, `calculateStatus`, `calculateReorder` |
| **Integration** | DB, Salesforce, JMS and File connectors | Handles persistence, the CRM system of record, event publishing, and file intake |
| **Caching** | Object Store connector, 2 stores | `Inventory_Cache_ObjectStore` caches single items (5-minute TTL, up to 10k entries). `Health_Status_ObjectStore` holds a health snapshot (2-hour TTL) |
| **Eventing** | 2 JMS queues | Alerts go to a procurement queue; all changes go to an update queue |
| **Governance** | Secure Properties (Blowfish/CFB on `config.yaml`), `globalErrorHandler`, API Gateway autodiscovery | Encrypts credentials, returns a consistent `{code, message, timestamp}` error shape, and applies gateway policies |
| **Audit** | `inventory_audit` table | Stores the full change history: `item_id, action, old_value, new_value, changed_at`, with the old and new values as JSON |

## 3. Domain rule: the stock status engine

This is the one piece of logic every flow depends on:

```
totalInventory = warehouseStock + regionalStock   (nulls → 0)
  > 200 OVERSTOCK | ≥100 HEALTHY | ≥50 NORMAL | ≥10 LOW | <10 CRITICAL
reorderQuantity = 200 - total  (if total < 200, else 0)
```

Whenever an item's status is CRITICAL, the flow publishes a message to `procurement.alert.queue`. This check runs in every write path: create, PUT, PATCH, bulk, CSV and sync.

## 4. Flow catalog

### Synchronous CRUD flows (APIKit-routed)

- `POST /inventory`: validate → reject a duplicate `itemId` (409) → insert into the DB → upsert to Salesforce → check for CRITICAL and alert → publish an update event.
- `GET /inventory`: filter by `status` or `region`, paginate with `limit` (1–200, default 50) and `offset`.
- `GET /inventory/{itemId}`: this is a **cache-aside** read. It checks the Object Store first. On a hit it returns the cached item. On a miss it reads the DB (404 if the item isn't found), stores the result in the cache, and returns it. Failures while writing to the cache are swallowed so they never break the read.
- `PUT /inventory/{itemId}`, in this order:
  1. Validate the payload.
  2. `SELECT` to confirm the item exists; raise `APP:NOT_FOUND` if not.
  3. `UPDATE` the DB.
  4. Upsert to Salesforce.
  5. Recalculate the status and publish a CRITICAL alert if needed.
  6. Build the old/new snapshot for the event.
  7. Publish the update event.
  8. Invalidate the cache (`OS:KEY_NOT_FOUND` is ignored).
  9. Build the response.
- `PATCH /inventory/{itemId}`: same pipeline as PUT, but any field not sent keeps its current DB value.
- `DELETE /inventory/{itemId}`: a **soft delete**. It sets `status = INACTIVE`, writes an audit record, publishes an event and invalidates the cache.
- `GET /inventory/{itemId}/summary`: a compact read model with `{itemId, totalInventory, status, reorderQuantity, region}`.

### Asynchronous batch flows (return 202 immediately)

- `POST /inventory/bulk` runs `bulkInventoryJob` (block size 100, `maxFailedRecords=-1`), which calls `process-inventory-item-subflow` for each record. Each record fails on its own without stopping the others, and final counts are logged at the end.
- `POST /inventory/sync` runs `fullInventorySyncJob`, which reads every active DB row again and, for each one, upserts to Salesforce, re-checks CRITICAL, re-publishes the event and clears the cache. It is a manual reconciliation safety net for anything the event-driven updates missed.
- `regional-csv-listener-flow` uses a file listener on `Regional-Updates/`. It converts the CSV to JSON and runs `regionalInventoryUpdateJob` through `process-regional-update-subflow`. Processed files move to `Processed-Files/`.

### Health

- `hourly-health-check-scheduler-flow` pings the DB and Salesforce every hour and stores the result in `Health_Status_ObjectStore`.
- `GET /health` returns the cached snapshot. It runs a live check only on a cold start, when no snapshot exists yet.

### Shared sub-flows (reuse points)

- `validate-inventory-fields-subflow`: rejects negative stock with `APP:VALIDATION` (400).
- `publish-inventory-update-event-subflow`: writes the audit row **and** publishes to `inventory.update.queue`. Every change goes through it, so the audit trail and the event stream stay in step.
- `check-system-health-subflow`: checks the DB and Salesforce, each in its own on-error-continue scope, so one failing dependency doesn't hide the status of the other.

## 5. Error-handling design

There are two tiers:

- **Main-flow handler:** `CONNECTIVITY` → 503. The `APIKIT:*` errors map to 400, 404, 405, 406, 415 and 501.
- **`globalErrorHandler`:** used by resource flows through `ref`. It maps the custom business errors `APP:DUPLICATE` → 409, `APP:NOT_FOUND` → 404 and `APP:VALIDATION` → 400.

Every error response uses the RAML `ErrorResponse` type.

## 6. Key design patterns

- **API-led / contract-first:** the RAML is written first, and the flows are generated from it and follow its naming.
- **Cache-aside with write-invalidation:** writes clear the cached entry rather than updating it, which avoids serving stale data.
- **Dual-write with event notification:** each change goes to MySQL (the operational source), then Salesforce (CRM), then JMS (for downstream consumers). The three writes are sequential and not transactional; the `/sync` endpoint exists to repair any drift between them.
- **Two queues for two jobs:** `procurement.alert.queue` gets only actionable CRITICAL alerts. `inventory.update.queue` gets every CREATE, UPDATE and DELETE as a change feed.
- **Batch jobs that isolate failures:** bulk, CSV and sync all use `maxFailedRecords=-1`, so one bad record never stops the job.
- **Soft delete plus an audit table:** nothing is physically removed, so the history stays complete.

## 7. Build, test and deployment

- **Maven:** built with the `mule-maven-plugin` 4.10.1. The MySQL driver and ActiveMQ client are shared libraries.
- **MUnit 3.2.1:** 5 suites covering GET, write, bulk/regional, validation and health. Coverage is reported with an 80% target, but `failBuild=false`, so low coverage doesn't fail the build.
- **Postman:** `postman/mulemart-inventory-api.postman_collection.json` has 25 requests, including the error paths and JMS verification.
- **Related docs:** `ARCHITECTURE.md`, `FLOW-WALKTHROUGH.md`, `DEMO-SCRIPT.md` and `PRESENTATION-QA.md` in this folder.

## 8. Observations

- **Exchange RAML and API Gateway:** the APIKit config uses the Exchange RAML dependency (`resource::29a7b6a7…:mulemart-inventory-api:1.0.0`), and `api-gateway:autodiscovery apiId="21165822"` is enabled. That means the app has to run with Anypoint Platform client credentials, or startup fails.
- **Hard-coded values:** the secure-properties **encryption key is written directly in `inventory-api.xml`**. The DB host, user, Salesforce username and broker URL are also inline instead of coming from `${...}` properties. The key is the main problem: anyone with the repo can decrypt `config.yaml`. It should be passed at runtime with `-Dmule.key=...`, and the other values should come from `config.yaml`.
- **Single-file structure:** all flows are in one XML file. Splitting it into files such as `global.xml`, `inventory-crud.xml`, `batch.xml` and `health.xml` would be easier to maintain, but it isn't required.
