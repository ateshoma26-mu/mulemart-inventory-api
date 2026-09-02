# MuleMart Inventory API — Live Demo Script

## Before you start

Confirm all of these are up and reachable:
- MySQL running, `inventory` + `inventory_audit` tables present
- ActiveMQ running (`tcp://localhost:61616`), console open at `http://localhost:8161/admin`
- Salesforce reachable (org logged in, `Inventory__c` list view open in a tab)
- App deployed and showing green/`DEPLOYED` in Anypoint Studio

Have visible on screen: **Postman**, the **ActiveMQ console**, and (if possible) the **Salesforce `Inventory__c` list view**.

Requests below are in `postman/mulemart-inventory-api.postman_collection.json` if you want to fire them from the collection instead of typing them live.

---

## The flow (~5 minutes, 6 calls)

### 1. Health check
`GET {{baseUrl}}/health`

Say: "Quick proof the system and both downstream connections — database and Salesforce — are up."

### 2. Create a healthy item
`POST {{baseUrl}}/inventory`
```json
{
  "itemId": "SKU-DEMO-001",
  "warehouseStock": 80,
  "regionalStock": 70,
  "safetyStock": 20,
  "region": "EU-WEST"
}
```
Show the response (`totalInventory: 150`, `status: HEALTHY`). Flip to Salesforce — show the record landed via upsert. Flip to ActiveMQ — `inventory.update.queue` ticked up by one, `procurement.alert.queue` did **not** move.

### 3. Create a CRITICAL item — the money shot
`POST {{baseUrl}}/inventory`
```json
{
  "itemId": "SKU-DEMO-002",
  "warehouseStock": 3,
  "regionalStock": 4,
  "safetyStock": 20,
  "region": "NA-EAST"
}
```
`totalInventory: 7` → `CRITICAL`. Flip to ActiveMQ — **both** queues tick up this time. Open the message in `procurement.alert.queue`, point at `reorderQuantity: 193`. This is the business-rule engine firing live.

### 4. Update it back to healthy
`PUT {{baseUrl}}/inventory/SKU-DEMO-002`
```json
{
  "itemId": "SKU-DEMO-002",
  "warehouseStock": 80,
  "regionalStock": 70,
  "safetyStock": 20,
  "region": "NA-EAST"
}
```
Narrate: the audit table now has a row for this change with `old_value`/`new_value` as full JSON snapshots of the item before and after — that's the governance/audit trail story.

### 5. Soft delete
`DELETE {{baseUrl}}/inventory/SKU-DEMO-002`

Then immediately:
`GET {{baseUrl}}/inventory/SKU-DEMO-002`

Show the record still exists but `status: "INACTIVE"` — proves soft delete (no hard deletes from the DB) in one before/after pair.

### 6. Bulk create
`POST {{baseUrl}}/inventory/bulk`
```json
[
  { "itemId": "SKU-BULK-001", "warehouseStock": 100, "regionalStock": 60, "safetyStock": 20, "region": "NA-WEST" },
  { "itemId": "SKU-BULK-002", "warehouseStock": 2, "regionalStock": 1, "safetyStock": 20, "region": "NA-WEST" }
]
```
Show the immediate `202 ACCEPTED`. Say: "This runs as a batch job designed to handle 5000+ records, with per-record error isolation — final counts get logged when it completes."

### Close
One line, no need to run it live: "And if anything ever drifts out of sync between the database and Salesforce, `POST /inventory/sync` reconciles everything — it's the manual safety net on top of all the event-driven updates you just saw."

---

## If asked "what's not done yet"

Be upfront: MUnit test coverage and the API Manager policies (rate limiting, client ID enforcement) are still open. Better to say so plainly than get caught by a direct question.
