import push.Push

## A subscription a page posts (`POST /push/subscribe`, packages/push): a visitor's ("").
respond! = |{ request, .. }| Push.subscribe_route!(request, "")
