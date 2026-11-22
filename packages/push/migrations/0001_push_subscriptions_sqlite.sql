-- Web Push subscriptions on SQLite (D-045): Postgres's table (0001_push_subscriptions.sql), its
-- moments milliseconds since the epoch in integer columns. A row for each browser that subscribed,
-- by its endpoint (the push service's URL for it), with its keys as the page sent them (base64url)
-- and whose it is (`owner`: the app's id for a user, or '' for a visitor). A push service's 404 or
-- 410 deletes it.
create table push_subscriptions (
    id integer primary key,
    endpoint text not null unique,
    p256dh text not null,
    auth text not null,
    owner text not null default '',
    created_at integer not null default (cast(unixepoch('subsec') * 1000 as integer)),
    last_sent_at integer,
    last_error text
);
create index push_subscriptions_owner on push_subscriptions (owner);
