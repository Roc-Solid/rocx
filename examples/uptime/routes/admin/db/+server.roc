import pf.Db
import pf.Random
import pf.Server
import admin.Admin
import admin.AdminPage
import ../../../Middlewares

middleware = Middlewares.admin

## /admin/db: packages/admin's pages for the app's tables, where monitors are added, edited and
## deleted (the database's checks, in migrations/0001_uptime.sql, refuse what doesn't make sense, and
## the form shows why). Only with the admin's session.
respond! : { request : Server.Request, params : {}, context : {} } => Server.Response
respond! = |{ request, context, .. }| AdminPage.respond!(request, context, tables, { all!: Db.all!, run!: Db.run!, random!: Random.bytes!, backend!: Db.backend! })

tables : Admin.Config({})
tables = {
	mount: "/admin/db",
	title: "Status",
	back: { label: "Status admin", href: "/admin" },
	access: |_| Edit,
	tables: [
		{
			name: "monitors",
			list: ["id", "name", "url", "method", "expected_status", "interval_s", "group_name", "paused"],
			search: ["name", "url"],
			ordering: ["group_name", "id"],
			read_only: ["streak", "next_check_at", "created_at"],
			labels: [("url", "URL"), ("expected_status", "Expected status"), ("interval_s", "Every (seconds)"), ("timeout_ms", "Timeout (ms)"), ("threshold", "Failures before an incident"), ("group_name", "Group")],
		},
		{ name: "incidents", list: ["id", "monitor_id", "title", "opened_at", "closed_at"], search: ["title"], ordering: ["-opened_at"] },
		{ name: "incident_updates", list: ["id", "incident_id", "at", "state", "author"], search: ["body"], ordering: ["-at"], widgets: [("body", LongText)] },
		{ name: "subscribers", list: ["id", "email", "created_at"], search: ["email"], read_only: ["token", "created_at"] },
		{ name: "checks", list: ["id", "monitor_id", "at", "up", "status", "latency_ms", "error"], ordering: ["-at"], create: Bool.False, read_only: ["monitor_id", "at", "up", "status", "latency_ms", "error"] },
		{ name: "daily", list: ["monitor_id", "day", "checks", "up"], ordering: ["-day"], create: Bool.False },
	],
}
