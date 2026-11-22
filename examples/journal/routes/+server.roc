import pf.Server
import intl.Intl
import intl.Locale
import ../I18n

## `/`: to the journal in the reader's language, the one their browser asks for first
## (`Accept-Language`) of the two it is written in, or English.
respond! : { request : Server.Request, params : {}, context : c } => Server.Response
respond! = |{ request, .. }| Server.redirect("/${Intl.choose(I18n.supported, Locale.wanted(request, "locale")).tag()}")
