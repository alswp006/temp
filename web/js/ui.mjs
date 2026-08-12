/* Tiny DOM helpers. Deliberately not a framework — the whole UI is a handful
   of screens and a build step would cost more than it saves. */

export function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === null || v === undefined || v === false) continue;
    if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else if (k === "style" && typeof v === "object") Object.assign(el.style, v);
    else if (k.startsWith("on") && typeof v === "function") {
      el.addEventListener(k.slice(2).toLowerCase(), v);
    } else if (v === true) el.setAttribute(k, "");
    else el.setAttribute(k, v);
  }
  for (const child of children.flat(Infinity)) {
    if (child === null || child === undefined || child === false) continue;
    el.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return el;
}

export function clear(node) {
  while (node.firstChild) node.removeChild(node.firstChild);
  return node;
}

let toastTimer;
export function toast(message, ms = 2600) {
  const el = document.getElementById("toast");
  el.textContent = message;
  el.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove("show"), ms);
}

export const fmt = {
  kcal: (v) => `${Math.round(v || 0).toLocaleString("ko-KR")}`,
  g: (v) => `${Math.round(v || 0)}g`,
  g1: (v) => `${(Math.round((v || 0) * 10) / 10).toFixed(1)}g`,
  kg: (v) => (v === null || v === undefined ? "–" : `${v.toFixed(1)}kg`),
  pct: (v) => `${Math.round((v || 0) * 100)}%`,
  date: (iso) => {
    const d = new Date(iso + (iso.length === 10 ? "T00:00:00" : ""));
    return `${d.getMonth() + 1}월 ${d.getDate()}일`;
  },
  time: (iso) =>
    new Date(iso).toLocaleTimeString("ko-KR", {
      hour: "2-digit",
      minute: "2-digit",
    }),
  weekday: (iso) =>
    ["일", "월", "화", "수", "목", "금", "토"][
      new Date(iso + (iso.length === 10 ? "T00:00:00" : "")).getDay()
    ],
};

export const MEAL_LABEL = {
  breakfast: "조식",
  lunch: "중식",
  dinner: "석식",
  snack: "간식",
};

export const MEAL_ICON = {
  breakfast: "🌅",
  lunch: "🍚",
  dinner: "🌙",
  snack: "🍎",
};

export const CATEGORY_LABEL = {
  rice: "밥",
  soup: "국·찌개",
  main: "주찬",
  side: "부찬",
  kimchi: "김치",
  dessert: "후식",
};

export const SCOPE_LABEL = {
  "diet:read": "식단 조회",
  "diet:write": "식단 대리 기록",
  "workout:read": "운동 조회",
  "workout:write": "운동 대리 기록",
  "weight:read": "체중 조회",
  "photo:read": "사진 원본 조회",
  "goal:propose": "목표 제안",
};

export function meter(value, target, { warnOver = true } = {}) {
  const ratio = target ? Math.min(value / target, 1.4) : 0;
  const over = warnOver && target && value > target;
  return h(
    "div",
    { class: `meter${over ? " warn" : ""}` },
    h("i", { style: { width: `${Math.min(ratio, 1) * 100}%` } }),
  );
}

/** Downscale before upload: a 12MP phone photo is ~4MB of pointless bytes over
    a canteen's wifi, and the model gets no benefit above ~1600px. */
export async function shrinkImage(file, maxEdge = 1600, quality = 0.85) {
  if (!file.type.startsWith("image/")) return file;
  try {
    const bitmap = await createImageBitmap(file);
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
    if (scale === 1 && file.size < 1_500_000) return file;

    const canvas = document.createElement("canvas");
    canvas.width = Math.round(bitmap.width * scale);
    canvas.height = Math.round(bitmap.height * scale);
    canvas.getContext("2d").drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((res) =>
      canvas.toBlob(res, "image/jpeg", quality),
    );
    bitmap.close?.();
    return blob ? new File([blob], "meal.jpg", { type: "image/jpeg" }) : file;
  } catch {
    return file; // EXIF-only formats etc. — let the server deal with it
  }
}

export function pickFile({ capture = "environment" } = {}) {
  return new Promise((resolve) => {
    const input = h("input", { type: "file", accept: "image/*", capture });
    input.style.display = "none";
    input.addEventListener("change", () => {
      resolve(input.files?.[0] || null);
      input.remove();
    });
    document.body.append(input);
    input.click();
  });
}
