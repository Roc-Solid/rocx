// A page's script that goes wrong twice: an error nothing catches, and a promise nothing catches
// the rejection of. packages/posthog's script sends both.
setTimeout(() => {
	null.total;
}, 0);
Promise.reject(new RangeError("price 12.50 is out of range"));
