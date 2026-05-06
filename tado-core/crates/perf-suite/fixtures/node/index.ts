// Minimal Node fixture for perf-suite adapter testing. Hits the
// Node adapter's DB-query and xproc-roundtrip regex patterns AND
// the proposal generator's repeated-fetch and forEach patterns.

import fetch from "node-fetch";

async function fetchPair(): Promise<unknown[]> {
  const a = await fetch("https://example.com/users/1");
  const b = await fetch("https://example.com/users/2");
  return [await a.json(), await b.json()];
}

async function loadAll(prisma: any) {
  for (const id of [1, 2, 3]) {
    await prisma.user.findUnique({ where: { id } });
  }
}

function logAll(items: number[]) {
  items.forEach((x) => {
    console.log(x);
  });
}

console.time("warmup");
console.timeEnd("warmup");

void fetchPair;
void loadAll;
void logAll;
