# reach.check runs earlier in the same VM during precommit, and sets the logger back to debug.
Logger.configure(level: :warning)

Mimic.copy(Anubis.Client)
ExUnit.start(capture_log: true)
