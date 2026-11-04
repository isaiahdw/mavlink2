# Test fixtures

| File | Source |
| --- | --- |
| `common.xml`, `standard.xml`, `minimal.xml` | pymavlink 2.4.50's `dialects/v20/` (MAVLink message definitions, LGPLv3) |
| `pymavlink_common.json` | pymavlink 2.4.50 on those files: per message id the name, `crc_extra`, payload length, wire order, field types and array lengths; and packed payloads for a set of messages |
| `command_cancel.xml` | `common.xml` plus `COMMAND_CANCEL` (80) and `MAV_RESULT_CANCELLED` as the current `common.xml` defines them; pymavlink 2.4.50 predates both |
