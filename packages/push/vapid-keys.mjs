#!/usr/bin/env node
// Makes a VAPID key pair for Web Push (packages/push), and prints it as the server reads it from
// its environment: the public key (an uncompressed P-256 point, 65 bytes) and the private key (its
// 32-byte scalar), both base64url. Keep the private key secret; the public key the page subscribes
// with (`GET /push/key` answers it). A browser subscribed with one public key can only be sent to
// with that pair: changing the keys means every browser subscribes again.
//
//     node packages/push/vapid-keys.mjs >> .env
import { generateKeyPairSync } from "node:crypto";

const { privateKey } = generateKeyPairSync("ec", { namedCurve: "P-256" });
const { x, y, d } = privateKey.export({ format: "jwk" });
const point = Buffer.concat([Buffer.from([4]), Buffer.from(x, "base64url"), Buffer.from(y, "base64url")]);
console.log(`VAPID_PUBLIC_KEY=${point.toString("base64url")}`);
console.log(`VAPID_PRIVATE_KEY=${d}`);
console.log("VAPID_SUBJECT=mailto:you@example.com");
