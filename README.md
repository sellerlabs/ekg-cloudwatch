# `ekg-cloudwatch`

Register a thread, and suddenly all your [`ekg`][ekg] metrics get pushed to Amazon CloudWatch. Neat!

Inspired (and copied) from the [`ekg-statsd`][ekg-statsd] package.

# Usage:

Pass your EKG `Store` and the Amazonka `Env` to the function:

```haskell
import System.Metrics as EKG
import Network.AWS    as AWS

register :: EKG.Store -> AWS.Env -> IO CloudWatchId
register store env =
  forkCloudWatch
    (defaultCloudWatchEnv "MyApplication" env)
    store
```
