import pf.OpenApi

## The OpenAPI document in Swagger (`GET /openapi.html`), which reads openapi.json beside it.
respond! = |{ request, .. }| OpenApi.page_route(request, Swagger)
