import push.Push

## The public key (`GET /push/key`, packages/push), which a page subscribes with.
respond! = |{ request, .. }| Push.key_route!(request)
