import admin.JobsPage

## /admin/jobs: packages/admin's jobs page, the queue of the jobs plugin, with a link back to the
## status admin. Only with the admin's session (this group's middleware).
respond! = |{ request, .. }| JobsPage.respond!(request, { mount: "/admin/jobs", back: { label: "Status admin", href: "/admin" } })
