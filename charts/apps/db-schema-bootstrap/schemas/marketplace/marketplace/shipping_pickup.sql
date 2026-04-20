-- shipping_pickup.sql — pickup-scheduling columns for marketplace-api.
--
-- This file extends the existing shipments and shipping_carrier_configs
-- tables with the fields needed to auto-schedule a Delhivery pickup when
-- a shipping label is created, and to track the pickup request that was
-- placed. Every statement is idempotent (ADD COLUMN IF NOT EXISTS) so
-- db-schema-bootstrap can replay this file safely on every 30-minute run.
--
-- Columns added to shipments:
--   pickup_request_id      — Delhivery's pr_id / pickup_id, stored as
--                            VARCHAR to cover both numeric and sentinel
--                            ("already-scheduled") values.
--   pickup_scheduled_for   — combined date + slot-start timestamp, used
--                            by the admin UI "Pickup: <day> <time>" row.
--
-- Columns added to shipping_carrier_configs:
--   auto_schedule_pickup      — master toggle; TRUE by default so
--                               existing rows opt in automatically.
--   default_pickup_slot_start — "HH:MM:SS" string, fed back to
--                               Delhivery as pickup_time.
--   default_pickup_slot_end   — only surfaced in the UI "Pickup: 14:00
--                               – 18:00" row; Delhivery only needs the
--                               start.
--
-- Schema deliberately leaves pickup_request_id un-indexed — it's only
-- read on a single-row fetch keyed by shipment id, and Delhivery's
-- pickup_id space is effectively opaque so an index would add write
-- cost for no read win.

ALTER TABLE IF EXISTS public.shipments
    ADD COLUMN IF NOT EXISTS pickup_request_id    VARCHAR(100),
    ADD COLUMN IF NOT EXISTS pickup_scheduled_for TIMESTAMPTZ;

ALTER TABLE IF EXISTS public.shipping_carrier_configs
    ADD COLUMN IF NOT EXISTS auto_schedule_pickup      BOOLEAN     NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS default_pickup_slot_start VARCHAR(8)  DEFAULT '14:00:00',
    ADD COLUMN IF NOT EXISTS default_pickup_slot_end   VARCHAR(8)  DEFAULT '18:00:00';
