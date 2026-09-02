# MuleMart Inventory API — Architecture & Endpoint Reference

## 1. What this is

A MuleSoft **Process API** that gives MuleMart a single, governed view of inventory across a legacy MySQL warehouse database, regional CSV feeds, Salesforce, and a JMS-based alerting/eventing system. Built on Mule Runtime 4.7.0, APIKit-routed from a RAML-first design published to Anypoint Exchange.

## 2. Architecture

```
                              SOURCES
        ┌──────────────────┐          ┌──────────────────────┐
        │  MySQL Warehouse │          │  Regional CSV Files   │
        │   (inventory,    │          │  (/Regional-Updates)  │
        │  inventory_audit)│          └──────────┬────────────┘
        └────────┬─────────┘                     │ file:listener
                  │                               │ (polls every 10s)
                  │                               ▼
                  │                     ┌────────────────────┐
                  │                     │  Batch Job: CSV →   │
                  │                     │  DB + Salesforce     │
                  │                     └──────────┬───────────┘
                  │                                │
   ┌──────────────▼────────────────────────────────▼───────────────┐
   │                     PROCESS API  (this project)                │
   │                                                                  │
   │  HTTP Listener :8081/api/*  →  APIKit Router (RAML-driven)      │
   │                                                                  │
   │  ┌────────────────────────────────────────────────────────┐    │
   │  │  Flows: GET/POST/PUT/PATCH/DELETE /inventory,           │    │
   │  │  /inventory/{itemId}/summary, /inventory/bulk,           │    │
   │  │  /inventory/sync, /health                                │    │
   │  │                                                            │    │
   │  │  Shared logic:                                            │    │
   │  │   • InventoryLib.dwl — calculateTotal/Status/Reorder      │    │
   │  │   • validate-inventory-fields-subflow — negative-stock    │    │
   │  │     checks (APP:VALIDATION → 400)                         │    │
   │  │   • publish-inventory-update-event-subflow — writes an    │    │
   │  │     inventory_audit row AND publishes to                  │    │
   │  │     inventory.update.queue, called from every              │    │
   │  │     CREATE/UPDATE/DELETE path                              │    │
   │  │   • check-system-health-subflow — DB + Salesforce ping     │    │
   │  └────────────────────────────────────────────────────────┘    │
   │                                                                  │
   │  Caching (Object Store):                                        │
   │   • Inventory_Cache_ObjectStore — per-item GET cache, 5 min TTL │
   │   • Health_Status_ObjectStore — hourly-scheduler health snapshot│
   │                                                                  │
   │  Global error handling:                                         │
   │   APP:DUPLICATE→409  APP:NOT_FOUND→404  APP:VALIDATION→400      │
   │   CONNECTIVITY→503   APIKIT:BAD_REQUEST→400  etc.               │
   └───────────┬───────────────────────────────┬────────────────────┘
               │                                │
               ▼                                ▼
   ┌────────────────────┐          ┌──────────────────────────────┐
   │     Salesforce      │          │        JMS (ActiveMQ)         │
   │   Inventory__c       │          │  procurement.alert.queue      │
   │  (upsert, ext id =   │          │   (CRITICAL stock only)        │
   │   itemId)             │          │  inventory.update.queue        │
   └────────────────────┘          │   (every CREATE/UPDATE/DELETE) │
                                     └──────────────────────────────┘
```

**Layers, plainly:**
- **API layer** — RAML defines the contract; APIKit routes each verb+path to a matching flow by naming convention (e.g. `put:\inventory\(itemId):application\json:...`).
- **Business logic layer** — DataWeave transformations (`InventoryLib.dwl`) hold the one piece of logic everything else depends on: total inventory and status thresholds.
- **Integration layer** — DB connector (MySQL), Salesforce connector, JMS connector (ActiveMQ), File connector (CSV).
- **Caching layer** — Object Store connector, two named stores serving two different lifecycles (short-TTL per-item cache vs. long-TTL health snapshot).
- **Eventing layer** — two JMS queues with different purposes: alerting (only fires on CRITICAL) vs. general change auditing (fires on every mutation).
- **Governance layer** — Secure Properties (encrypted DB/Salesforce credentials), a global error handler mapping business/system errors to the right HTTP status codes.
- **Persistence/audit layer** — the `inventory` table (current state) and `inventory_audit` table (full history: `item_id, action, old_value, new_value, changed_at`, with `old_value`/`new_value` as JSON snapshots).

## 3. Stock status engine

```
totalInventory = warehouseStock + regionalStock

  > 200        → OVERSTOCK
  100 – 200    → HEALTHY
  50 – 99      → NORMAL
  10 – 49      → LOW
  < 10         → CRITICAL   (fires procurement.alert.queue, reorderQuantity = 200 - totalInventory)
```

## 4. Endpoints

Base URL: `http://localhost:8081/api`

| Method | Path | Purpose | Notes |
|---|---|---|---|
| `GET` | `/health` | System health (DB + Salesforce connectivity) | Served from an hourly-refreshed cache; falls back to a live check only on cold start |
| `GET` | `/inventory` | List items | Query params: `status`, `region` (filter); `limit` (1–200, default 50), `offset` (pagination) |
| `POST` | `/inventory` | Create an item | Body: `{itemId, warehouseStock, regionalStock, region?, safetyStock?}`. Validates non-negative stock (400), rejects duplicate `itemId` (409), upserts to Salesforce, fires CRITICAL alert + audit/update event |
| `GET` | `/inventory/{itemId}` | Get one item | Served from Object Store cache (5 min TTL) when present, else DB |
| `PUT` | `/inventory/{itemId}` | Full update | Body must include `itemId` again (same schema as create). Recalculates total/status, invalidates cache, re-checks CRITICAL, writes audit row |
| `PATCH` | `/inventory/{itemId}` | Partial update | Any subset of `warehouseStock, regionalStock, region, safetyStock, status`. Missing fields default to current DB values |
| `DELETE` | `/inventory/{itemId}` | Soft delete | Sets `status = INACTIVE`, row is **not** removed from the DB; invalidates cache; writes audit row |
| `GET` | `/inventory/{itemId}/summary` | Compact status view | Returns `{itemId, totalInventory, status, reorderQuantity, region}` |
| `POST` | `/inventory/bulk` | Bulk create | Body: array of create-shaped items. Batch job (5000+ record capable), per-record error isolation, `202 ACCEPTED` immediately, final counts logged |
| `POST` | `/inventory/sync` | Full reconciliation | No body. Re-pulls every active DB row, re-upserts each to Salesforce, re-checks CRITICAL, re-publishes update events. Same async `202` pattern as `/bulk`. Manually triggered (no automatic schedule) — the safety net for when event-driven updates might have missed something |

### Standard error responses
All endpoints share the same `ErrorResponse` shape (`{code, message, timestamp}`) and status mapping:

| Status | Trigger |
|---|---|
| 400 | Malformed/invalid request body (`APIKIT:BAD_REQUEST`), or negative stock values (`APP:VALIDATION`) |
| 404 | Unknown route (`APIKIT:NOT_FOUND`), or valid route but item doesn't exist (`APP:NOT_FOUND`) |
| 409 | Duplicate `itemId` on create (`APP:DUPLICATE`) |
| 503 | MySQL or Salesforce unreachable (`CONNECTIVITY`, any connector) |

## 5. Event payloads

**`procurement.alert.queue`** (only when an item is/becomes CRITICAL):
```json
{ "itemId": "...", "currentStock": 7, "status": "CRITICAL", "region": "...", "reorderQuantity": 193, "timestamp": "..." }
```

**`inventory.update.queue`** (every CREATE/UPDATE/DELETE):
```json
{ "eventType": "CREATE|UPDATE|DELETE", "itemId": "...", "totalInventory": 7, "status": "...", "region": "...", "timestamp": "..." }
```

## 6. Testing

See `postman/mulemart-inventory-api.postman_collection.json` in this same folder — 7 folders / 25 requests covering every endpoint above plus the 404/409/400 error paths and a dedicated JMS-event verification sequence.
