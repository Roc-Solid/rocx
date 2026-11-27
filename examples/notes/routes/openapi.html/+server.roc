import pf.OpenApi

## The OpenAPI document in Scalar (`GET /openapi.html`), which reads openapi.json beside it.
respond! = |{ request, .. }| OpenApi.page_route(request, Scalar)
