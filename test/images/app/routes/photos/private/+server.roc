import pf.Server

## GET /photos/private: a photo for those signed in: a signed-out visitor is refused, so it gets no
## copies anyone could fetch.
respond! = |_| Server.refused(401, "sign in to see it")
