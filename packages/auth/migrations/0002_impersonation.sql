-- A session acting as another user (D-077, `Auth.impersonate!`): as whom, and until when (milliseconds
-- since 1970). Null: the session is its own user's. The row stays its signer's (`user_id`), so
-- signing out, `sessions!` and `revoke!` go by who really signed in.
alter table auth_sessions add column acting_as text;
alter table auth_sessions add column acting_until bigint;
