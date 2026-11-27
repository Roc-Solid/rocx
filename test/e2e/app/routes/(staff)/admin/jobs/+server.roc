import admin.JobsPage

## /admin/jobs: packages/admin's jobs page, behind this group's middleware (members only).
respond! = |{ request, .. }| JobsPage.respond!(request, { mount: "/admin/jobs" })
