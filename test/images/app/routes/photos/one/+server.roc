import pf.Server
import ../../../Photos

## GET /photos/one: a PNG (with an alpha channel), as an app answers a photo it keeps.
respond! = |_| Server.bytes(200, [{ name: "content-type", value: "image/png" }], Photos.one)
