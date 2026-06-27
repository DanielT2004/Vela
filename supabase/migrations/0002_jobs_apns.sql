-- Vela — APNs push: record the device token + environment per analysis job so the server-side worker
-- can notify the phone when the job finishes (the local notification can't fire while the app is killed).
-- Both columns are NULLABLE: clients without a token (notification permission denied, token not yet
-- registered, or an older build) must still run the job — the worker simply skips the push.
alter table public.jobs add column if not exists device_token text;  -- APNs hex device token
alter table public.jobs add column if not exists apns_env    text;   -- 'sandbox' | 'production'
