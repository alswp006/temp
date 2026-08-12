/* Offline upload queue.

   The single worst moment for this app is standing in a canteen basement with
   one bar of signal, taking a photo, and losing it. So photos go into IndexedDB
   first and are drained whenever the network comes back — the shutter never
   depends on connectivity. */

const DB_NAME = "sikpan";
const STORE = "outbox";
const VERSION = 1;

let dbPromise = null;

function openDb() {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE, { keyPath: "id", autoIncrement: true });
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

async function tx(mode, fn) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const t = db.transaction(STORE, mode);
    const store = t.objectStore(STORE);
    const result = fn(store);
    t.oncomplete = () => resolve(result?.result ?? result);
    t.onerror = () => reject(t.error);
  });
}

export async function enqueue(entry) {
  return tx("readwrite", (s) => s.add({ ...entry, queuedAt: Date.now() }));
}

export async function all() {
  return tx("readonly", (s) => s.getAll());
}

export async function remove(id) {
  return tx("readwrite", (s) => s.delete(id));
}

export async function count() {
  return (await all()).length;
}

/** Try to send everything queued. Returns how many made it. */
export async function drain(sendFn) {
  const items = await all();
  let sent = 0;
  for (const item of items) {
    try {
      await sendFn(item);
      await remove(item.id);
      sent += 1;
    } catch (err) {
      // A 4xx will never succeed on retry — drop it rather than blocking the
      // queue forever behind a permanently bad request.
      if (err?.status >= 400 && err.status < 500) {
        await remove(item.id);
      }
      break;
    }
  }
  return sent;
}
