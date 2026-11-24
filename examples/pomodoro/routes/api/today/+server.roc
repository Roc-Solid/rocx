import pf.Server
import pf.Endpoint
import ../../../Pomodoro
import ../../../Store

## GET /api/today: the focus sessions done today, and the day's goal. The page reads it (and reads
## it again after a session is recorded, as a submission's answer has the page's reads read again).
get! : { request : Server.Request, params : {}, context : {} } => Try(Pomodoro.Today, Endpoint.Refusal)
get! = |_| Store.today!({})
