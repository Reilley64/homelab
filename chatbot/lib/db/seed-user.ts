import { text } from "node:stream/consumers";
import { config } from "dotenv";
import { createUser, getUser } from "./queries";

config({ path: ".env.local" });

const [email] = process.argv.slice(2);

if (!email) {
  console.error("usage: tsx lib/db/seed-user.ts <email>   # password on stdin");
  process.exit(1);
}

// ponytail: password on stdin, not argv — argv is readable by any process via
// `ps` and lands in shell history. Strip only the trailing newline the shell
// adds, never trim, so a password with edge whitespace still works.
const password = (await text(process.stdin)).replace(/\r?\n$/, "");

if (!password) {
  console.error("no password on stdin");
  process.exit(1);
}

const existing = await getUser(email);

if (existing.length > 0) {
  console.error(`user ${email} already exists`);
  process.exit(1);
}

await createUser(email, password);
console.log(`created ${email}`);
process.exit(0);
