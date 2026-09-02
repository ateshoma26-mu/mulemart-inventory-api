# POST /inventory — Box-by-Box Flow Walkthrough

This traces the exact execution path of a single `POST /inventory` request, box by box as it would appear on Anypoint Studio's canvas — starting with the global error handler (since it wraps everything and needs to be understood first), then every component in order, ending inside the shared `publish-inventory-update-event-subflow`.

PUT/PATCH/DELETE follow the identical shape from "Set Variable `newItem`" onward, just with an `existing` row fetched first (so `eventOldValue` is a real snapshot instead of `null`), and DELETE skips straight to setting `status = INACTIVE` instead of recalculating totals.

## Part 1 — `globalErrorHandler` (the wrapper)

This isn't a box in the canvas flow itself — it's a separate reusable Error Handler component (`inventory-api.xml`, near the top of the file) that PUT, PATCH, POST, and DELETE all reference. Three typed catch-blocks, checked in order against whatever error got raised:

| Catches | Sets | Returns |
|---|---|---|
| `APP:DUPLICATE` | `httpStatus = 409` | `{code: "DUPLICATE", message, timestamp}` |
| `APP:NOT_FOUND` | `httpStatus = 404` | `{code: "NOT_FOUND", message, timestamp}` |
| `APP:VALIDATION` | `httpStatus = 400` | `{code: "VALIDATION_ERROR", message, timestamp}` |

Think of it as three `catch` blocks sitting off to the side — nothing runs unless something downstream explicitly raises one of these three error types.

(Separately, the top-level `inventory-api-main` flow's own error-handler also catches `CONNECTIVITY` errors → `503`, and the various `APIKIT:*` routing errors → 400/404/405/406/415/501. That one wraps *every* endpoint, not just the CRUD ones.)

## Part 2 — the `POST /inventory` flow, box by box

**Box 1 — HTTP Listener** (in `inventory-api-main`, not this flow itself)
Receives the request on `:8081/api/*`.

**Box 2 — APIKit Router**
Reads method + path, matches the RAML resource, routes to *this* flow by name (`post:\inventory:application\json:...`) — this naming convention is how APIKit finds the right flow with zero manual routing code.

**Box 3 — Set Variable `newItem`**
`vars.newItem = payload` — grabs the incoming JSON body once so every later box can reference `vars.newItem` instead of `payload` (which gets overwritten by DB/Salesforce calls later).

**Box 4 — Flow Reference → `validate-inventory-fields-subflow`**
Jumps into the shared validation subflow:
- *Inside it:* one **Choice** checks if `warehouseStock`, `regionalStock`, or `safetyStock` is negative.
- If so → **Raise Error `APP:VALIDATION`** — immediately unwinds up to `globalErrorHandler`, which catches it and returns `400`. Everything below never runs.
- If not, the subflow just falls through and control returns to the main flow.

**Box 5 — DB Select** (`SELECT item_id FROM inventory WHERE item_id = :itemId`)
Checks whether this `itemId` already exists.

**Box 6 — Choice (duplicate check)**
- **When** the select returned a row (`sizeOf(payload) > 0`) → **Raise Error `APP:DUPLICATE`** → caught by `globalErrorHandler` → `409`. Stop here.
- **Otherwise** → continue into the boxes below.

**Box 7 — DB Insert**
Writes the new row: `itemId, warehouseStock, regionalStock, totalInventory` (computed via `calculateTotal`), `safetyStock, status` (computed via `calculateStatus`), `region`.

**Box 8 — Salesforce Upsert**
Pushes the same computed record to `Inventory__c`, keyed on `itemId__c` as the external ID — this is what makes it an upsert (create-or-update) rather than a plain insert on the Salesforce side.

**Box 9 — Set Variable `itemStatus`**
Recomputes and stores `calculateStatus(calculateTotal(...))` into a variable, so the next two boxes don't have to recompute it themselves.

**Box 10 — Choice (CRITICAL check)**
- **When** `vars.itemStatus == "CRITICAL"` → **Box 11: JMS Publish** to `procurement.alert.queue` with `itemId, currentStock, status, region, reorderQuantity, timestamp`.
- **Otherwise** → skip straight past, no alert.

**Boxes 12–18 — Six `Set Variable`s** (`eventOldValue`, `eventNewValue`, `eventType`, `eventItemId`, `eventTotalInventory`, `eventStatus`, `eventRegion`)
These exist purely to hand off a consistent, pre-named set of variables to the *shared* subflow coming next — since that subflow is called from 7 different places, it can't know each caller's own variable names, so every caller sets these same six `vars.eventX` names right before calling it. `eventOldValue` is `null` here specifically because this is a CREATE — there's no "before" state.

**Box 19 — Flow Reference → `publish-inventory-update-event-subflow`** — see Part 3 below.

**Box 20 — Transform Message**
Builds the actual HTTP response body: `itemId, warehouseStock, regionalStock, totalInventory, safetyStock, status, region`.

**(wrapping) `<error-handler ref="globalErrorHandler"/>`**
Attached to the whole flow — this is what actually catches the `APP:DUPLICATE`/`APP:VALIDATION` raises from boxes 4 and 6 and converts them to the right HTTP response.

## Part 3 — inside `publish-inventory-update-event-subflow` (the finish line)

Two boxes, always run together, called from all 7 CREATE/UPDATE/DELETE paths in the app (POST, PUT, PATCH, DELETE, the bulk-create subflow, the regional-CSV-update subflow, and the sync subflow):

**Box A — DB Insert into `inventory_audit`**
`INSERT INTO inventory_audit (item_id, action, old_value, new_value, changed_at) VALUES (...)` — using exactly the six `vars.eventX` variables the caller just set. `action` = `eventType` (`CREATE` in this trace). This is the permanent audit trail.

**Box B — JMS Publish to `inventory.update.queue`**
`{eventType, itemId, totalInventory, status, region, timestamp}` — the general-purpose "something changed" event, separate from the CRITICAL-only alert queue.

Then control returns to the caller (back to Box 20 in Part 2), and the response goes out.
