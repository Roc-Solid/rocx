import guard.Flag
import guard.Flags

## The app's feature flags.
Features := [].{

	new_checkout : Flag
	new_checkout = Flag.define("new_checkout", "The one-page checkout", { ..Flags.rollout(25), users: ["ada"], groups: ["staff"] })
		.in_env("dev", Flags.on)

	maintenance : Flag
	maintenance = Flag.define("maintenance", "Down for maintenance", Flags.off)

	all : List(Flag)
	all = [Features.new_checkout, Features.maintenance]
}
