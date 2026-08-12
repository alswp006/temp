/* Thin API client: token storage + typed errors. */

const TOKEN_KEY = "sikpan.token";
const USER_KEY = "sikpan.user";

export const API = "/api";

export function getToken() {
  return localStorage.getItem(TOKEN_KEY);
}

export function setSession(token, user) {
  localStorage.setItem(TOKEN_KEY, token);
  localStorage.setItem(USER_KEY, JSON.stringify(user));
}

export function getUser() {
  try {
    return JSON.parse(localStorage.getItem(USER_KEY) || "null");
  } catch {
    return null;
  }
}

export function clearSession() {
  localStorage.removeItem(TOKEN_KEY);
  localStorage.removeItem(USER_KEY);
}

export class ApiError extends Error {
  constructor(status, payload) {
    super(payload?.message || `요청 실패 (${status})`);
    this.status = status;
    this.code = payload?.error || "error";
    this.detail = payload?.detail;
  }
}

async function request(method, path, { body, form, auth = true, query } = {}) {
  const url = new URL(API + path, location.origin);
  if (query) {
    for (const [k, v] of Object.entries(query)) {
      if (v !== undefined && v !== null && v !== "") url.searchParams.set(k, v);
    }
  }

  const headers = {};
  if (auth) {
    const token = getToken();
    if (token) headers.Authorization = `Bearer ${token}`;
  }
  let payload;
  if (form) {
    payload = form; // browser sets the multipart boundary
  } else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }

  const res = await fetch(url, { method, headers, body: payload });
  if (res.status === 204) return null;

  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) {
    if (res.status === 401) clearSession();
    throw new ApiError(res.status, data);
  }
  return data;
}

export const api = {
  get: (p, opts) => request("GET", p, opts),
  post: (p, body, opts) => request("POST", p, { body, ...opts }),
  put: (p, body, opts) => request("PUT", p, { body, ...opts }),
  patch: (p, body, opts) => request("PATCH", p, { body, ...opts }),
  del: (p, opts) => request("DELETE", p, opts),
  upload: (p, form) => request("POST", p, { form }),
};
