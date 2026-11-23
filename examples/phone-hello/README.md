# phone-hello

D-063's spike screen: one page that runs in a browser and, unchanged, as native Android views
(spike/native-apps/README.md). It has a counter (a signal, a button, a text hole), a value read
from `GET /api/greeting` through the app's contract (`Api`, under `<Loading>`), and a field whose
text a button posts to `POST /api/echo`, the typed answer shown.

```sh
bin/rocx dev examples/phone-hello    # the browser's, at http://localhost:8080
native/android/build.sh examples/phone-hello    # the phone's APK (spike/native-apps/README.md)
```
