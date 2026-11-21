-- Web Push subscriptions (packages/push): a row for each browser that subscribed, by its endpoint
-- (the push service's URL for it), with its keys as the page sent them (base64url) and whose it is
-- (`owner`: the app's id for a user, or '' for a visitor). A push service's 404 or 410 deletes it.
create table push_subscriptions (
    id bigserial primary key,
    endpoint text not null unique,
    p256dh text not null,
    auth text not null,
    owner text not null default '',
    created_at timestamptz not null default now(),
    last_sent_at timestamptz,
    last_error text
);
create index push_subscriptions_owner on push_subscriptions (owner);
