# MuleMart Inventory API — Presentation Q&A

Speak-out-loud answers for the demo. Use the short reply first; add the “why” only if they follow up.

---

## 1. Architecture

**What is this API?**  
Process API for MuleMart inventory. One contract in front of MySQL, Salesforce, JMS, Object Store, and a regional CSV folder.

**Why RAML + APIkit?**  
Design-first. APIkit routes `GET /inventory/{itemId}` to the flow named `get:\inventory\(itemId)...` and validates method, path, and media type. Console at `/console/` is docs UI, not the router.

**What is `inventory-api-main` vs the operation flows?**  
Main = HTTP listener `/api/*` + APIkit Router. Operation flows do the business work. Main’s error handler is APIKIT / CONNECTIVITY (404 / 405 / 415). `APP:VALIDATION`, `APP:NOT_FOUND`, and `APP:DUPLICATE` are on `globalErrorHandler` on the operation flows.

**Why On Error Propagate, not Continue, in the global handler?**  
We format JSON and set `vars.httpStatus`, then still fail so the listener uses error-response (`vars.httpStatus`). Continue would look like success and hit the 200 response.

**Why is HTTP status a variable, not the payload?**  
The listener reads `vars.httpStatus`. Payload is the JSON body. Studio “Undefined” is missing metadata, not a runtime bug.

---

## 2. Inventory math

**How is total / status / reorder calculated?**  
`InventoryLib.dwl`:

- Total = warehouse + regional
- Status: `>200` OVERSTOCK, `>=100` HEALTHY, `>=50` NORMAL, `>=10` LOW, else CRITICAL
- Reorder: if total `< 200` then `200 - total`, else `0`

**Do you reorder until OVERSTOCK?**  
No. Target is 200 = HEALTHY. OVERSTOCK is already too much. Reorder is a number (GET summary + CRITICAL JMS), not an auto-PO loop.

**When does procurement get a message?**  
Only when the new status is CRITICAL (total `< 10`). LOW and NORMAL do not publish that queue.

---

## 3. Cache

**Who writes the item cache?**  
Only `GET /inventory/{itemId}`. Miss → DB → transform → `os:store`. TTL 5 minutes. Store failures are On Error Continue so GET still returns.

**Who removes it?**  
PUT, PATCH, DELETE, and POST `/inventory/sync`. `os:remove` plus continue only on `OS:KEY_NOT_FOUND`.

**Who does not touch item cache?**

- GET list and GET summary — never cache
- POST create and bulk — they do not `os:remove`
- Regional CSV — updates MySQL/SF but does not invalidate. GET-by-id can be stale up to 5 minutes. Say that out loud; it is a real gap.

**Health cache is different.**  
Separate store, key `systemHealthStatus`, TTL 2 hours.

- GET `/health` only reads (contains → retrieve, else live check)
- Hourly scheduler live-checks and stores
- GET miss does not write

**Why cache only GET-by-id?**  
Hottest single-item read. List is filtered/paginated (bad cache key). Summary is a different shape. Writes drop the key so the next GET reloads.

---

## 4. Writes — PUT vs PATCH vs DELETE vs POST

**PUT vs PATCH?**  
PUT = full replace from body. PATCH = merge: body field, else keep DB. Both recalc total/status. Both 404 if missing. Both upsert Salesforce, maybe CRITICAL, audit UPDATE, drop cache.

**Can PATCH set `status` to INACTIVE?**  
No. Status is always `calculateStatus(total)`. Soft delete is DELETE only.

**DELETE?**  
Soft delete: `status = 'INACTIVE'`. Row stays. No body, no validation, no Salesforce, no CRITICAL. Audit DELETE. Drops cache.

**POST create?**  
Validate → exists? `APP:DUPLICATE` 409. Insert + Salesforce upsert + CRITICAL + audit CREATE (`oldValue` null). No cache remove.

**Why Salesforce upsert, not update?**  
External id `itemId__c`. Update-or-create in Salesforce. MySQL 404 does not mean Salesforce 404.

**Why `payload[0]`?**  
DB Select always returns a list. One row is still `[row]`.

---

## 5. Async / batch

**Why 202 on bulk and sync?**  
Work is a batch job. HTTP returns Accepted immediately. Result is logged in On Complete, not the HTTP body.

**`maxFailedRecords="-1"`?**  
Never abort the job because N records failed. Each failure is one record; the rest continue.

**`blockSize="100"`?**  
Process 100 records per block.

**Does bulk use the same logic as POST?**  
Yes, `process-inventory-item-subflow` (validate, duplicate, insert, Salesforce, CRITICAL, CREATE event). POST duplicates that inline; it does not `flow-ref` the subflow. Duplicate in bulk fails the record, not HTTP 409.

**What does sync do?**  
Select `status != 'INACTIVE'`. Per row: recalc total/status in MySQL, Salesforce upsert, cache remove, CRITICAL, audit UPDATE. Repair derived columns; do not just push stale totals to Salesforce.

---

## 6. CSV regional

**How does it start?**  
Not HTTP. File Listener (On New or Updated File), poll 10000 ms on the listener’s Fixed Frequency. `*.csv` in inbound, then move to processed.

**Insert?**  
Never. Missing `itemId` → `APP:NOT_FOUND` on that record. Warehouse stays from DB; CSV sets regional (plus region, lastUpdated).

**Bad column names?**  
Mapped by header name. Expected: `itemId,regionalStock,region,lastUpdated`. Wrong names → nulls / `regionalStock` 0 → usually not-found per row. File still moved (`applyPostActionWhenFailed="true"`). Bad types on the right names can fail the whole Transform before batch.

---

## 7. Errors and events

**Three APP errors?**  
`VALIDATION` 400, `NOT_FOUND` 404, `DUPLICATE` 409.

**Local Try vs global handler?**  
Cache store/remove Trys are local (continue). `APP:*` uses the flow `globalErrorHandler`.

**What does the publish subflow do?**  
Insert `inventory_audit` + JMS `inventory.update.queue`. Callers set `eventOldValue`, `eventNewValue`, `eventType`, and related vars. Used by POST, PUT, PATCH, DELETE, bulk, sync, CSV.

**Two JMS queues?**  
`procurement.alert.queue` = CRITICAL only. `inventory.update.queue` = every create/update/delete.

---

## 8. Trap questions

**GET list empty = 404?**  
No. Empty array `[]`. 404 is only one item missing.

**GET summary cached?**  
No.

**POST after GET of the same id?**  
Create does not clear cache; the key usually did not exist.

**CSV then GET-by-id?**  
Can show old regional for up to 5 minutes. Sync / PUT / PATCH / DELETE would have cleared it.

**Why so many Set Variables before publish?**  
Subflow has no arguments. Variables are the contract.

**Why not one subflow for POST and bulk?**  
Bulk already uses it; HTTP POST was left copied. Same steps, two places — a maintainability smell.

**`inventory-apiFlow` empty `{}`?**  
Unused stub. Safe to delete; does not run.

---

## 9. Compare these

- **GET by id** — HTTP 200. Does not insert. **Stores** item cache. No event.
- **GET list / summary** — HTTP 200. Does not insert. No cache. No event.
- **POST / bulk** — HTTP 201 / 202. Inserts. No cache change. CREATE event.
- **PUT / PATCH** — HTTP 200. No insert. **Removes** item cache. UPDATE event.
- **DELETE** — HTTP 200. Soft delete (no row remove). **Removes** item cache. DELETE event.
- **Sync** — HTTP 202. No insert. **Removes** item cache. UPDATE event.
- **CSV** — No HTTP. No insert. **Does not** touch cache. UPDATE event.

---

## 10. One-liners

- **Idempotent?** PUT/PATCH of the same body yes (same end state). POST create is not (409). CSV re-drop of the same file updates again.
- **Transaction across DB + Salesforce?** Not a single XA transaction. Salesforce after DB; Salesforce fail can leave MySQL updated (eventual / best-effort dual write).
- **Secrets?** `config.yaml` + secure properties, not plaintext in flows.
- **Pagination?** List: `limit` default 50, clamp 1–200; `offset` default 0.
