import pf.OpenApi
import ../../Generated/Api

## The endpoints' OpenAPI document (`GET /openapi.json`), which rocx writes (`Api.openapi`).
respond! = |{ request, .. }| OpenApi.document_route(request, Api.openapi)
