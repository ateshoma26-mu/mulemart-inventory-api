%dw 2.0

fun calculateTotal(warehouse, regional) = 
    (warehouse default 0) + (regional default 0)

fun calculateStatus(total) = 
    if (total > 200) "OVERSTOCK"
    else if (total >= 100) "HEALTHY"
    else if (total >= 50) "NORMAL"
    else if (total >= 10) "LOW"
    else "CRITICAL"

fun calculateReorder(total) = 
    if (total < 200) (200 - total) else 0