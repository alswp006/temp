/* 식판 PWA — hash router + views. */

import { ApiError, api, clearSession, getToken, getUser, setSession } from "./api.mjs";
import * as outbox from "./outbox.mjs";
import {
  CATEGORY_LABEL,
  MEAL_ICON,
  MEAL_LABEL,
  SCOPE_LABEL,
  clear,
  fmt,
  h,
  meter,
  pickFile,
  shrinkImage,
  toast,
} from "./ui.mjs";

const root = document.getElementById("root");
const state = { user: getUser(), canteens: [], pendingUploads: 0 };

const TABS = [
  ["/today", "오늘", "🍚"],
  ["/log", "기록", "✍️"],
  ["/week", "주간", "📊"],
  ["/battle", "배틀", "🏅"],
  ["/more", "더보기", "⚙️"],
];

// --------------------------------------------------------------------------
// Shell
// --------------------------------------------------------------------------

function shell(title, sub, body, { actions } = {}) {
  const route = location.hash.slice(1) || "/today";
  return [
    h(
      "header",
      { class: "topbar" },
      h("div", {}, h("h1", {}, title), sub ? h("div", { class: "sub" }, sub) : null),
      h("div", { class: "row" }, actions || []),
    ),
    h("main", {}, body),
    h("div", { class: "capture" }, h("button", { onclick: captureMeal, title: "식사 촬영" }, "📷")),
    h(
      "nav",
      { class: "tabbar" },
      TABS.map(([path, label, icon]) =>
        h(
          "a",
          {
            href: `#${path}`,
            "aria-current": route.startsWith(path) ? "page" : null,
          },
          h("span", { class: "ico" }, icon),
          label,
        ),
      ),
    ),
  ];
}

function render(nodes) {
  clear(root);
  root.append(...[nodes].flat().filter(Boolean));
}

function loading(label = "불러오는 중") {
  return h("div", { class: "empty" }, h("span", { class: "spinner" }), " ", label);
}

async function guard(fn) {
  try {
    return await fn();
  } catch (err) {
    if (err instanceof ApiError && err.status === 401) {
      state.user = null;
      location.hash = "#/login";
      return null;
    }
    toast(err.message || "오류가 발생했습니다");
    console.error(err);
    return null;
  }
}

// --------------------------------------------------------------------------
// Login
// --------------------------------------------------------------------------

function loginView() {
  const email = h("input", { class: "input", type: "email", placeholder: "you@example.com", autocomplete: "email" });
  const nickname = h("input", { class: "input", placeholder: "닉네임 (처음 로그인 시)" });
  const code = h("input", { class: "input", inputmode: "numeric", placeholder: "6자리 코드" });
  const codeBox = h("div", { class: "col", style: { display: "none" } },
    h("div", { class: "field" }, h("label", {}, "인증 코드"), code),
    h("button", { class: "btn primary block", onclick: verify }, "로그인"),
  );

  async function sendCode() {
    if (!email.value.trim()) return toast("이메일을 입력해 주세요");
    await guard(async () => {
      const res = await api.post("/auth/request-code", {
        email: email.value.trim(),
        nickname: nickname.value.trim() || null,
      }, { auth: false });
      codeBox.style.display = "flex";
      if (res.dev_code) {
        code.value = res.dev_code;
        toast(`개발 모드 코드: ${res.dev_code}`);
      } else {
        toast("메일로 코드를 보냈습니다");
      }
      code.focus();
    });
  }

  async function verify() {
    await guard(async () => {
      const res = await api.post("/auth/verify", {
        email: email.value.trim(),
        code: code.value.trim(),
      }, { auth: false });
      setSession(res.access_token, res.user);
      state.user = res.user;
      location.hash = "#/today";
    });
  }

  return h(
    "div",
    { class: "login" },
    h("div", { class: "brand" }, "식판"),
    h("div", { class: "tag" }, "기록을 나 혼자 하지 않아도 되는 앱"),
    h(
      "div",
      { class: "card col" },
      h("div", { class: "field" }, h("label", {}, "이메일"), email),
      h("div", { class: "field" }, h("label", {}, "닉네임"), nickname),
      h("button", { class: "btn primary block", onclick: sendCode }, "인증 코드 받기"),
      codeBox,
    ),
    h("p", { class: "small dim center" }, "비밀번호가 없습니다. 메일로 온 코드로 로그인합니다."),
  );
}

// --------------------------------------------------------------------------
// Capture
// --------------------------------------------------------------------------

async function captureMeal() {
  const file = await pickFile();
  if (!file) return;
  const shrunk = await shrinkImage(file);

  const canteenId = localStorage.getItem("sikpan.canteen") || "";
  const entry = { kind: "meal", blob: shrunk, canteenId, at: new Date().toISOString() };

  if (!navigator.onLine) {
    await outbox.enqueue(entry);
    toast("오프라인 — 사진을 저장했습니다. 연결되면 자동 전송합니다.");
    return renderRoute();
  }

  toast("업로드 중…");
  const ok = await guard(async () => {
    await sendMealPhoto(entry);
    return true;
  });
  if (ok) {
    toast("접수했습니다. 분석 중…");
    // The analysis job usually lands within a couple of seconds.
    setTimeout(renderRoute, 1500);
    setTimeout(renderRoute, 4000);
  } else {
    await outbox.enqueue(entry);
  }
  renderRoute();
}

async function sendMealPhoto(entry) {
  const form = new FormData();
  form.append("file", entry.blob, "meal.jpg");
  if (entry.canteenId) form.append("canteen_id", entry.canteenId);
  if (entry.at) form.append("shot_at", entry.at);
  return api.upload("/meals/photo", form);
}

async function drainOutbox() {
  if (!navigator.onLine || !getToken()) return;
  const sent = await outbox.drain(sendMealPhoto);
  state.pendingUploads = await outbox.count();
  if (sent) {
    toast(`대기 중이던 사진 ${sent}장을 보냈습니다`);
    renderRoute();
  }
}

// --------------------------------------------------------------------------
// Today
// --------------------------------------------------------------------------

async function todayView() {
  render(shell("오늘", null, loading()));
  const data = await guard(() => api.get("/today"));
  if (!data) return;

  const s = data.summary;
  const remaining = s.remaining_kcal;
  const over = remaining !== null && remaining < 0;

  const hero = h(
    "section",
    { class: "card hero" },
    h(
      "div",
      { class: `big${over ? " over" : ""}` },
      remaining === null ? fmt.kcal(s.kcal) : fmt.kcal(Math.abs(remaining)),
    ),
    h(
      "div",
      { class: "label" },
      remaining === null
        ? "오늘 섭취 kcal · 목표 미설정"
        : over
          ? `목표보다 ${fmt.kcal(Math.abs(remaining))}kcal 초과`
          : `남은 kcal · 목표 ${fmt.kcal(s.target_kcal)}`,
    ),
    h("div", { style: { marginTop: "14px" } }, meter(s.kcal, s.target_kcal)),
    h(
      "div",
      { class: "macros" },
      h("div", { class: "macro" }, h("b", {}, fmt.g(s.protein_g)), h("span", {}, "단백질")),
      h("div", { class: "macro" }, h("b", {}, fmt.g(s.carb_g)), h("span", {}, "탄수화물")),
      h("div", { class: "macro" }, h("b", {}, fmt.g(s.fat_g)), h("span", {}, "지방")),
    ),
    s.target_protein_g
      ? h(
          "div",
          { style: { marginTop: "12px" } },
          h(
            "div",
            { class: "row between tiny muted", style: { marginBottom: "5px" } },
            h("span", {}, "단백질 목표"),
            h("span", { class: "mono" }, `${fmt.g(s.protein_g)} / ${fmt.g(s.target_protein_g)}`),
          ),
          meter(s.protein_g, s.target_protein_g, { warnOver: false }),
        )
      : null,
  );

  const quick = data.quick_sets.length
    ? h(
        "section",
        { class: "card" },
        h("h2", {}, "내 식사 세트"),
        h(
          "div",
          { class: "chips" },
          data.quick_sets.map((set) =>
            h(
              "button",
              {
                class: "chip",
                onclick: async () => {
                  await guard(() => api.post(`/meal-sets/${set.id}/apply`, {}));
                  toast(`${set.name} 기록했습니다`);
                  renderRoute();
                },
              },
              `${set.name} · ${set.use_count}회`,
            ),
          ),
        ),
        h("p", { class: "tiny dim", style: { margin: "9px 0 0" } },
          "두 번째부터는 한 번만 누르면 됩니다."),
      )
    : null;

  const meals = h(
    "section",
    { class: "card" },
    h("h2", {}, `오늘의 기록 · ${data.meals.length}끼`),
    data.meals.length
      ? data.meals.map(mealRow)
      : h("div", { class: "empty" }, "아직 기록이 없습니다. 아래 📷 를 눌러 시작하세요."),
  );

  const banners = [];
  if (state.pendingUploads) {
    banners.push(h("div", { class: "banner" },
      `전송 대기 중인 사진 ${state.pendingUploads}장 (연결되면 자동 전송)`));
  }
  if (data.pending) {
    banners.push(h("div", { class: "banner info" },
      h("span", { class: "spinner" }), ` 분석 중인 식사 ${data.pending}건`));
  }

  render(shell("오늘", fmt.date(s.date), [banners, hero, quick, meals]));
}

function mealRow(meal) {
  const status =
    meal.status === "ready"
      ? null
      : meal.status === "failed"
        ? h("span", { class: "badge danger" }, "실패")
        : h("span", { class: "badge" }, h("span", { class: "spinner" }), " 분석 중");

  const flags = [];
  if (meal.open_mode) flags.push(h("span", { class: "badge warn" }, "식단표 없음 · 오차 큼"));
  if (meal.logged_by_name) flags.push(h("span", { class: "badge accent" }, `${meal.logged_by_name}가 기록`));
  if (meal.cache_hit) flags.push(h("span", { class: "badge" }, "캐시"));

  return h(
    "div",
    { class: "item", onclick: () => (location.hash = `#/meal/${meal.id}`) },
    h("div", { class: "thumb" }, MEAL_ICON[meal.meal_type] || "🍽"),
    h(
      "div",
      { class: "grow" },
      h(
        "div",
        { class: "row between" },
        h("strong", {}, MEAL_LABEL[meal.meal_type] || meal.meal_type),
        h("span", { class: "mono small" }, meal.status === "ready" ? `${fmt.kcal(meal.kcal)}kcal` : ""),
      ),
      h(
        "div",
        { class: "small muted truncate" },
        meal.items.length
          ? meal.items.map((i) => i.name).join(", ")
          : meal.error || "—",
      ),
      flags.length || status
        ? h("div", { class: "row wrap", style: { marginTop: "5px", gap: "5px" } }, status, flags)
        : null,
    ),
  );
}

// --------------------------------------------------------------------------
// Meal detail
// --------------------------------------------------------------------------

async function mealView(id) {
  render(shell("식사", null, loading()));
  const meal = await guard(() => api.get(`/meals/${id}`));
  if (!meal) return;

  const editInput = h("input", {
    class: "input",
    placeholder: "예: 밥 150으로 / 국 안 먹음 / 고기 두 배",
  });

  async function applyEdit() {
    const text = editInput.value.trim();
    if (!text) return;
    const res = await guard(() => api.post(`/meals/${id}/edit`, { text }));
    if (res) {
      toast(res.message);
      if (res.action !== "none") mealView(id);
    }
  }

  const rows = meal.items.map((item) =>
    h(
      "div",
      { class: "item" },
      h("div", { class: "grow" },
        h("div", { class: "row between" },
          h("strong", {}, item.name),
          h("span", { class: "mono small" }, `${fmt.kcal(item.kcal)}kcal`)),
        h("div", { class: "row wrap tiny muted", style: { gap: "6px" } },
          h("span", {}, CATEGORY_LABEL[item.category] || item.category),
          h("span", {}, `${fmt.g(item.final_g)}`),
          h("span", {}, `×${item.portion_ratio}`),
          item.edited_by_user
            ? h("span", { class: "badge accent" }, "수정함")
            : item.confidence < 0.6
              ? h("span", { class: "badge warn" }, `확인 필요 ${fmt.pct(item.confidence)}`)
              : null),
      ),
      h("div", { class: "row", style: { gap: "6px" } },
        h("button", {
          class: "btn sm ghost",
          onclick: async () => {
            const grams = prompt(`${item.name} 중량(g)`, Math.round(item.final_g));
            if (!grams) return;
            await guard(() => api.patch(`/meals/${id}/items/${item.id}`, { final_g: Number(grams) }));
            mealView(id);
          },
        }, "수정"),
        h("button", {
          class: "btn sm danger",
          onclick: async () => {
            await guard(() => api.del(`/meals/${id}/items/${item.id}`));
            mealView(id);
          },
        }, "삭제"),
      ),
    ),
  );

  const slotPicker = h(
    "div",
    { class: "chips" },
    ["breakfast", "lunch", "dinner", "snack"].map((type) =>
      h("button", {
        class: "chip",
        "aria-pressed": meal.meal_type === type ? "true" : "false",
        onclick: async () => {
          if (meal.meal_type === type) return;
          await guard(() => api.patch(`/meals/${id}`, { meal_type: type }));
          toast("끼니를 바꾸고 다시 분석합니다");
          setTimeout(() => mealView(id), 1800);
        },
      }, MEAL_LABEL[type]),
    ),
  );

  const body = [
    meal.open_mode
      ? h("div", { class: "banner" },
          "이 끼니의 식단표가 없어 열린 인식 모드로 분석했습니다. " +
          "끼니를 잘못 잡았다면 아래에서 바꿔 주세요 — 식단표가 붙으면 정확해집니다.")
      : null,
    h("section", { class: "card" },
      h("div", { class: "row between" },
        h("h2", { style: { margin: 0 } },
          `${MEAL_LABEL[meal.meal_type]} · ${fmt.time(meal.shot_at)}`),
        h("span", { class: "mono" }, `${fmt.kcal(meal.kcal)}kcal`)),
      h("div", { class: "row wrap small muted", style: { gap: "10px", marginTop: "6px" } },
        h("span", {}, `단백질 ${fmt.g(meal.protein_g)}`),
        h("span", {}, `탄수 ${fmt.g(meal.carb_g)}`),
        h("span", {}, `지방 ${fmt.g(meal.fat_g)}`),
        meal.calls_used ? h("span", { class: "dim" }, `AI 호출 ${meal.calls_used}회`) : null),
      meal.logged_by_name
        ? h("div", { style: { marginTop: "8px" } },
            h("span", { class: "badge accent" }, `${meal.logged_by_name}가 기록함`))
        : null),
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "끼니"), slotPicker),
    h("section", { class: "card" }, h("h2", {}, "항목"),
      rows.length ? rows : h("div", { class: "empty" }, "항목이 없습니다")),
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "한 줄로 고치기"),
      h("div", { class: "row" }, editInput,
        h("button", { class: "btn primary", onclick: applyEdit }, "적용"))),
    h("section", { class: "card col" },
      h("button", {
        class: "btn block",
        onclick: async () => {
          const name = prompt("세트 이름", `${MEAL_LABEL[meal.meal_type]} 기본`);
          if (!name) return;
          await guard(() => api.post("/meal-sets/from-meal", { meal_id: meal.id, name }));
          toast("세트로 저장했습니다");
        },
      }, "내 식사 세트로 저장"),
      meal.status === "failed"
        ? h("button", {
            class: "btn block",
            onclick: async () => {
              await guard(() => api.post(`/meals/${id}/retry`));
              toast("다시 분석합니다");
              setTimeout(() => mealView(id), 2000);
            },
          }, "다시 분석")
        : null,
      h("button", {
        class: "btn block danger",
        onclick: async () => {
          if (!confirm("이 식사를 삭제할까요?")) return;
          await guard(() => api.del(`/meals/${id}`));
          location.hash = "#/today";
        },
      }, "식사 삭제")),
  ];

  render(shell("식사 상세", fmt.date(meal.local_date), body));
}

// --------------------------------------------------------------------------
// Log (record anything)
// --------------------------------------------------------------------------

async function logView() {
  const weightInput = h("input", { class: "input", type: "number", step: "0.1", placeholder: "예: 72.4" });
  const workoutInput = h("input", { class: "input", placeholder: "스쿼트 60에 10개 3세트, 랫풀 50에 12개 3세트" });
  const foodName = h("input", { class: "input", placeholder: "음식 이름" });
  const foodGrams = h("input", { class: "input", type: "number", placeholder: "중량 (g)", value: "200" });

  const body = [
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "📷 사진으로"),
      h("div", { class: "row", style: { gap: "8px" } },
        h("button", { class: "btn primary grow", onclick: captureMeal }, "식판 촬영"),
        h("button", { class: "btn grow", onclick: captureWorkoutPhoto }, "운동 수첩 촬영")),
      h("p", { class: "tiny dim", style: { margin: 0 } },
        "수첩·화이트보드·다른 앱 화면을 찍으면 세트 단위로 읽어옵니다.")),

    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "🎤 한 문장으로 운동"),
      h("div", { class: "row" }, workoutInput,
        h("button", {
          class: "btn primary",
          onclick: async () => {
            const text = workoutInput.value.trim();
            if (!text) return;
            const res = await guard(() => api.post("/workouts/text", { text }));
            if (res) {
              toast(`${res.sets.length}세트 기록했습니다`);
              workoutInput.value = "";
            }
          },
        }, "기록"))),

    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "⚖️ 체중"),
      h("div", { class: "row" }, weightInput,
        h("button", {
          class: "btn primary",
          onclick: async () => {
            const kg = Number(weightInput.value);
            if (!kg) return toast("체중을 입력해 주세요");
            await guard(() => api.post("/weights", { raw_kg: kg }));
            toast("체중을 기록했습니다");
            weightInput.value = "";
          },
        }, "기록")),
      h("p", { class: "tiny dim", style: { margin: 0 } },
        "체중은 본인만 입력할 수 있습니다. 코치도 대신 넣을 수 없습니다.")),

    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "⌨️ 직접 입력"),
      h("div", { class: "row" }, foodName, foodGrams),
      h("button", {
        class: "btn block",
        onclick: async () => {
          const name = foodName.value.trim();
          if (!name) return;
          await guard(() =>
            api.post("/meals/manual", {
              items: [{ name, final_g: Number(foodGrams.value) || 100 }],
            }));
          toast("기록했습니다");
          foodName.value = "";
        },
      }, "식사에 추가")),
  ];

  render(shell("기록", "AI 호출 없이도 다 됩니다", body));
}

async function captureWorkoutPhoto() {
  const file = await pickFile();
  if (!file) return;
  const form = new FormData();
  form.append("file", await shrinkImage(file), "note.jpg");
  toast("읽는 중…");
  const res = await guard(() => api.upload("/workouts/photo", form));
  if (res) {
    toast(`${res.sets.length}세트를 읽었습니다`);
    if (res.unmatched?.length) {
      toast(`확인 필요: ${res.unmatched.join(", ")}`, 4000);
    }
  }
}

// --------------------------------------------------------------------------
// Week
// --------------------------------------------------------------------------

async function weekView() {
  render(shell("주간", null, loading()));
  const r = await guard(() => api.get("/reports/weekly"));
  if (!r) return;

  const stat = (label, value, hint) =>
    h("div", { class: "macro" },
      h("b", {}, value),
      h("span", {}, label),
      hint ? h("span", { class: "tiny dim" }, hint) : null);

  const body = [
    h("section", { class: "card" },
      h("h2", {}, "북극성 지표"),
      h("div", { class: "hero", style: { padding: "6px 0 0" } },
        h("div", { class: "big" }, r.total_entries),
        h("div", { class: "label" }, "이번 주 기록 항목 수 (식단 + 운동)")),
      h("div", { class: "macros" },
        stat("기록 일수", `${r.logged_days}일`),
        stat("식단 항목", r.meal_entries),
        stat("운동 세트", r.workout_entries))),

    h("section", { class: "card" },
      h("h2", {}, "섭취"),
      h("div", { class: "macros" },
        stat("평균 kcal", fmt.kcal(r.avg_kcal)),
        stat("평균 단백질", fmt.g(r.avg_protein_g)),
        stat("목표 달성일", `${r.on_target_days}일`)),
      h("div", { class: "macros" },
        stat("추정 TDEE", r.est_tdee ? fmt.kcal(r.est_tdee) : "–"),
        stat("목표 kcal", r.target_kcal ? fmt.kcal(r.target_kcal) : "–"),
        stat("추세 체중", r.weight_change_kg === null ? "–" : `${r.weight_change_kg > 0 ? "+" : ""}${r.weight_change_kg}kg`))),

    h("section", { class: "card" },
      h("h2", {}, "품질 지표"),
      h("table", { class: "grid" },
        h("tbody", {},
          tr("수정 발생률", fmt.pct(r.edit_rate), "AI 결과를 손으로 고친 비율"),
          tr("메뉴 커버리지", fmt.pct(r.menu_coverage), "식단표가 있던 끼니 비율"),
          tr("대리 기록 비율", fmt.pct(r.delegated_ratio), "멘토가 대신 쓴 비율"),
          tr("끼니당 AI 호출", r.avg_calls_per_meal || "–", "낮을수록 저렴"),
          tr("캐시 적중률", fmt.pct(r.cache_hit_rate), "같은 식당 유저가 많을수록 상승")))),

    h("section", { class: "card" },
      h("h2", {}, "요일별"),
      h("table", { class: "grid" },
        h("thead", {}, h("tr", {},
          h("th", {}, "날짜"),
          h("th", { class: "num" }, "kcal"),
          h("th", { class: "num" }, "단백질"),
          h("th", { class: "num" }, "끼니"),
          h("th", { class: "num" }, "운동"))),
        h("tbody", {}, r.days.map((d) =>
          h("tr", {},
            h("td", {}, `${fmt.date(d.date)} (${fmt.weekday(d.date)})`),
            h("td", { class: "num mono" }, d.meals ? fmt.kcal(d.kcal) : "–"),
            h("td", { class: "num mono" }, d.meals ? fmt.g(d.protein_g) : "–"),
            h("td", { class: "num mono" }, d.meals || "–"),
            h("td", { class: "num mono" }, d.workouts || "–"))))),
    ),
  ];

  render(shell("주간 리포트", `${fmt.date(r.start)} – ${fmt.date(r.end)}`, body));
}

function tr(label, value, hint) {
  return h("tr", {},
    h("td", {}, label, hint ? h("div", { class: "tiny dim" }, hint) : null),
    h("td", { class: "num mono" }, value));
}

// --------------------------------------------------------------------------
// Battle
// --------------------------------------------------------------------------

async function battleView() {
  render(shell("배틀", null, loading()));
  const battles = await guard(() => api.get("/battles"));
  if (!battles) return;

  const body = [];

  if (!battles.length) {
    body.push(h("div", { class: "empty" }, "참여 중인 배틀이 없습니다."));
  }

  for (const battle of battles) {
    const board = await guard(() => api.get(`/battles/${battle.id}/leaderboard`)) || [];
    body.push(
      h("section", { class: "card" },
        h("div", { class: "row between" },
          h("h2", { style: { margin: 0 } }, battle.name),
          h("span", { class: "badge" }, `코드 ${battle.join_code}`)),
        h("div", { class: "small dim", style: { marginBottom: "8px" } },
          `${fmt.date(battle.start_date)} – ${fmt.date(battle.end_date)}`),
        h("table", { class: "grid" },
          h("thead", {}, h("tr", {},
            h("th", {}, "#"), h("th", {}, "이름"),
            h("th", { class: "num" }, "점수"),
            h("th", { class: "num" }, "기록"),
            h("th", { class: "num" }, "연속"))),
          h("tbody", {}, board.map((row, i) =>
            h("tr", {},
              h("td", {}, i + 1),
              h("td", {}, row.nickname, row.team ? h("span", { class: "badge" }, row.team) : null),
              h("td", { class: "num mono" }, row.points),
              h("td", { class: "num mono" }, `${row.logged_days}일`),
              h("td", { class: "num mono" }, row.streak ? `🔥${row.streak}` : "–"))))),
        h("p", { class: "tiny dim", style: { marginBottom: 0 } },
          "점수는 기록한 만큼 쌓입니다. 체중 수치는 점수에 들어가지 않습니다.")),
    );
  }

  const nameInput = h("input", { class: "input", placeholder: "배틀 이름" });
  const codeInput = h("input", { class: "input", placeholder: "초대 코드" });
  body.push(
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "새로 만들기 / 참가"),
      h("div", { class: "row" }, nameInput,
        h("button", {
          class: "btn primary",
          onclick: async () => {
            if (!nameInput.value.trim()) return;
            await guard(() => api.post("/battles", { name: nameInput.value.trim(), weeks: 1 }));
            battleView();
          },
        }, "생성")),
      h("div", { class: "row" }, codeInput,
        h("button", {
          class: "btn",
          onclick: async () => {
            if (!codeInput.value.trim()) return;
            await guard(() => api.post("/battles/join", { join_code: codeInput.value.trim() }));
            battleView();
          },
        }, "참가"))),
  );

  render(shell("배틀", "기록으로 겨룹니다", body));
}

// --------------------------------------------------------------------------
// More: coach dashboard, mentorships, canteens, settings
// --------------------------------------------------------------------------

async function moreView() {
  render(shell("더보기", null, loading()));
  const [me, canteens, mentorships, dashboard, notifications] = await Promise.all([
    guard(() => api.get("/auth/me")),
    guard(() => api.get("/canteens")),
    guard(() => api.get("/mentorships")),
    guard(() => api.get("/mentorships/dashboard")),
    guard(() => api.get("/notifications", { query: { limit: 8 } })),
  ]);
  if (!me) return;
  state.user = me;
  state.canteens = canteens || [];

  const body = [];

  // --- coach dashboard --------------------------------------------------
  if (dashboard?.length) {
    body.push(
      h("section", { class: "card" },
        h("h2", {}, `멘티 ${dashboard.length}명`),
        dashboard.map((card) =>
          h("div", { class: "item" },
            h("div", { class: "thumb" }, card.stale_days >= 3 ? "🟠" : "🟢"),
            h("div", { class: "grow" },
              h("div", { class: "row between" },
                h("strong", {}, card.nickname),
                h("span", { class: "small mono" }, `주 ${fmt.pct(card.week_completion)}`)),
              h("div", { class: "small muted" },
                [
                  card.meals_today === null ? null : `끼니 ${card.meals_today}`,
                  card.workouts_today === null ? null : `운동 ${card.workouts_today}`,
                  card.weight_today === null ? null : card.weight_today ? "체중 ✓" : "체중 –",
                ].filter(Boolean).join(" · ") || "공유된 항목 없음"),
              card.stale_days >= 3
                ? h("div", { class: "tiny dim" }, `${card.stale_days}일째 기록 없음`)
                : null),
            h("button", {
              class: "btn sm",
              onclick: () => (location.hash = `#/mentee/${card.user_id}`),
            }, "열기"))),
        h("p", { class: "tiny dim", style: { marginBottom: 0 } },
          "미기록이 길어져도 자동 독촉 알림은 보내지 않습니다.")),
    );
  }

  // --- mentorships ------------------------------------------------------
  body.push(mentorshipCard(mentorships || []));

  // --- canteens ---------------------------------------------------------
  const selected = localStorage.getItem("sikpan.canteen") || "";
  const canteenName = h("input", { class: "input", placeholder: "식당 이름" });
  const canteenCode = h("input", { class: "input", placeholder: "초대 코드" });
  body.push(
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "내 식당"),
      state.canteens.length
        ? h("div", { class: "chips" },
            [h("button", {
              class: "chip",
              "aria-pressed": selected === "" ? "true" : "false",
              onclick: () => { localStorage.removeItem("sikpan.canteen"); moreView(); },
            }, "선택 안 함"),
            ...state.canteens.map((c) =>
              h("button", {
                class: "chip",
                "aria-pressed": String(c.id) === selected ? "true" : "false",
                onclick: () => { localStorage.setItem("sikpan.canteen", c.id); moreView(); },
              }, c.name))])
        : h("p", { class: "small dim", style: { margin: 0 } }, "아직 식당이 없습니다."),
      selected
        ? h("button", {
            class: "btn block",
            onclick: () => (location.hash = `#/menu/${selected}`),
          }, "이번 주 식단표 보기 / 올리기")
        : null,
      h("div", { class: "row" }, canteenName,
        h("button", {
          class: "btn primary",
          onclick: async () => {
            if (!canteenName.value.trim()) return;
            const c = await guard(() => api.post("/canteens", { name: canteenName.value.trim() }));
            if (c) { localStorage.setItem("sikpan.canteen", c.id); moreView(); }
          },
        }, "만들기")),
      h("div", { class: "row" }, canteenCode,
        h("button", {
          class: "btn",
          onclick: async () => {
            if (!canteenCode.value.trim()) return;
            const c = await guard(() => api.post("/canteens/join", { join_code: canteenCode.value.trim() }));
            if (c) { localStorage.setItem("sikpan.canteen", c.id); moreView(); }
          },
        }, "참가"))),
  );

  // --- profile ----------------------------------------------------------
  const height = h("input", { class: "input", type: "number", value: me.height_cm || "", placeholder: "cm" });
  const birth = h("input", { class: "input", type: "number", value: me.birth_year || "", placeholder: "연도" });
  const goal = h("select", { class: "input" },
    ...[["lose", "감량"], ["maintain", "유지"], ["gain", "증량"]].map(([v, l]) =>
      h("option", { value: v, selected: me.goal_type === v }, l)));
  const sex = h("select", { class: "input" },
    ...[["unspecified", "선택 안 함"], ["male", "남성"], ["female", "여성"]].map(([v, l]) =>
      h("option", { value: v, selected: me.sex === v }, l)));

  body.push(
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "프로필"),
      h("div", { class: "row" },
        h("div", { class: "field grow" }, h("label", {}, "키"), height),
        h("div", { class: "field grow" }, h("label", {}, "출생연도"), birth)),
      h("div", { class: "row" },
        h("div", { class: "field grow" }, h("label", {}, "목표"), goal),
        h("div", { class: "field grow" }, h("label", {}, "성별"), sex)),
      h("button", {
        class: "btn primary block",
        onclick: async () => {
          await guard(() => api.patch("/auth/me", {
            height_cm: Number(height.value) || null,
            birth_year: Number(birth.value) || null,
            goal_type: goal.value,
            sex: sex.value,
          }));
          toast("저장했습니다");
        },
      }, "저장"),
      h("p", { class: "tiny dim", style: { margin: 0 } },
        "키·나이는 기초대사량 하한 계산에 쓰입니다.")),
  );

  // --- targets ----------------------------------------------------------
  const target = await guard(() => api.get("/targets/current"));
  body.push(
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "이번 주 목표"),
      target
        ? h("div", { class: "macros" },
            h("div", { class: "macro" }, h("b", {}, fmt.kcal(target.target_kcal)), h("span", {}, "kcal")),
            h("div", { class: "macro" }, h("b", {}, fmt.g(target.target_protein_g)), h("span", {}, "단백질")),
            h("div", { class: "macro" }, h("b", {}, target.est_tdee ? fmt.kcal(target.est_tdee) : "–"), h("span", {}, "추정 TDEE")))
        : h("p", { class: "small dim", style: { margin: 0 } }, "아직 목표가 없습니다."),
      h("div", { class: "row" },
        h("button", {
          class: "btn grow",
          onclick: async () => {
            await guard(() => api.post("/targets/refresh"));
            toast("목표를 다시 계산했습니다");
            moreView();
          },
        }, "다시 계산"),
        h("button", {
          class: "btn grow",
          onclick: async () => {
            const kcal = prompt("목표 kcal", target?.target_kcal || 2000);
            if (!kcal) return;
            try {
              await api.put("/targets/current", { target_kcal: Number(kcal), pinned: true });
              toast("목표를 고정했습니다");
              moreView();
            } catch (err) {
              if (err.detail?.requires_confirmation) {
                if (confirm(`${err.message}\n그래도 진행할까요?`)) {
                  await guard(() => api.put("/targets/current", {
                    target_kcal: Number(kcal), pinned: true, confirm_aggressive: true,
                  }));
                  moreView();
                }
              } else toast(err.message);
            }
          },
        }, "직접 정하기")),
      h("p", { class: "tiny dim", style: { margin: 0 } },
        "공식이 뱉은 값은 초기값일 뿐입니다. 다만 기초대사량 아래로는 내려가지 않습니다.")),
  );

  // --- notifications & audit -------------------------------------------
  if (notifications?.length) {
    body.push(
      h("section", { class: "card" },
        h("h2", {}, "알림"),
        notifications.map((n) =>
          h("div", { class: "item" },
            h("div", { class: "grow" },
              h("strong", { class: "small" }, n.title),
              h("div", { class: "small muted" }, n.body || ""))))),
    );
  }

  body.push(
    h("section", { class: "card col" },
      h("button", { class: "btn block", onclick: () => (location.hash = "#/audit") },
        "내 기록 변경 이력 보기"),
      h("button", {
        class: "btn block danger",
        onclick: () => { clearSession(); state.user = null; location.hash = "#/login"; },
      }, "로그아웃"),
      h("p", { class: "tiny dim center", style: { margin: 0 } },
        `${me.email} · 식판 v0.1`)),
  );

  render(shell("더보기", state.user?.nickname, body));
}

function mentorshipCard(mentorships) {
  const asMentor = mentorships.filter((m) => m.mentor_id === state.user?.id);
  const asMentee = mentorships.filter((m) => m.mentee_id === state.user?.id);
  const codeInput = h("input", { class: "input", placeholder: "초대 코드" });

  return h(
    "section",
    { class: "card col" },
    h("h2", { style: { margin: 0 } }, "함께 하는 사람"),

    asMentee.length
      ? h("div", { class: "col" },
          h("div", { class: "tiny dim" }, "나를 봐주는 사람"),
          asMentee.map((m) =>
            h("div", { class: "item" },
              h("div", { class: "grow" },
                h("strong", {}, m.mentor_name),
                h("div", { class: "small muted" },
                  Object.entries(m.permissions).filter(([, v]) => v)
                    .map(([k]) => SCOPE_LABEL[k] || k).join(", ") || "허용된 항목 없음")),
              h("button", {
                class: "btn sm",
                onclick: () => (location.hash = `#/permissions/${m.id}`),
              }, "권한"),
              h("button", {
                class: "btn sm danger",
                onclick: async () => {
                  if (!confirm(`${m.mentor_name}과의 연결을 해제할까요?`)) return;
                  await guard(() => api.del(`/mentorships/${m.id}`));
                  moreView();
                },
              }, "해제"))))
      : null,

    asMentor.length
      ? h("div", { class: "col" },
          h("div", { class: "tiny dim" }, "내가 봐주는 사람"),
          asMentor.map((m) => h("div", { class: "item" }, h("strong", {}, m.mentee_name))))
      : null,

    h("div", { class: "row" },
      h("button", {
        class: "btn grow",
        onclick: async () => {
          const res = await guard(() => api.post("/mentorships/invite", { type: "peer" }));
          if (res) {
            await navigator.clipboard?.writeText(res.invite_url).catch(() => {});
            prompt("이 링크를 상대에게 보내세요", res.invite_url);
          }
        },
      }, "초대 만들기"),
      h("button", {
        class: "btn grow",
        onclick: async () => {
          const res = await guard(() => api.post("/mentorships/invite", { type: "coach" }));
          if (res) prompt("코치용 초대 링크", res.invite_url);
        },
      }, "코치로 초대")),

    h("div", { class: "row" }, codeInput,
      h("button", {
        class: "btn primary",
        onclick: () => {
          if (codeInput.value.trim()) location.hash = `#/invite/${codeInput.value.trim()}`;
        },
      }, "코드 입력")),
  );
}

// --------------------------------------------------------------------------
// Invite / permissions
// --------------------------------------------------------------------------

async function inviteView(code) {
  render(shell("연결", null, loading()));
  const preview = await guard(() => api.get(`/mentorships/invite/${code}`, { auth: false }));
  if (!preview) return;

  const toggles = new Map();
  const rows = preview.scopes.map((s) => {
    const input = h("input", { type: "checkbox", checked: s.recommended });
    toggles.set(s.scope, input);
    return h("label", { class: "switch" },
      h("div", {},
        h("div", {}, SCOPE_LABEL[s.scope] || s.scope),
        h("div", { class: "tiny dim" },
          s.is_write ? "대신 기록할 수 있습니다" : "조회만 가능합니다")),
      input);
  });

  const body = [
    h("section", { class: "card" },
      h("h2", {}, `${preview.mentor_name}님이 연결을 요청했습니다`),
      h("p", { class: "small muted" },
        "허용할 항목만 켜 주세요. 전부 꺼진 상태가 기본이고, 언제든 바꿀 수 있습니다."),
      rows,
      h("div", { class: "banner", style: { marginTop: "12px" } }, preview.notice),
      h("button", {
        class: "btn primary block",
        style: { marginTop: "12px" },
        onclick: async () => {
          const permissions = {};
          for (const [scope, input] of toggles) permissions[scope] = input.checked;
          await guard(() => api.post("/mentorships/accept", { invite_code: code, permissions }));
          toast("연결했습니다");
          location.hash = "#/more";
        },
      }, "이 조건으로 연결")),
  ];
  render(shell("연결 요청", preview.type === "coach" ? "코치" : "동료", body));
}

async function permissionsView(id) {
  render(shell("권한", null, loading()));
  const list = await guard(() => api.get("/mentorships"));
  const m = list?.find((x) => String(x.id) === String(id));
  if (!m) return render(shell("권한", null, h("div", { class: "empty" }, "연결을 찾을 수 없습니다")));

  const toggles = new Map();
  const rows = Object.keys(SCOPE_LABEL).map((scope) => {
    const input = h("input", { type: "checkbox", checked: !!m.permissions[scope] });
    toggles.set(scope, input);
    return h("label", { class: "switch" }, h("div", {}, SCOPE_LABEL[scope]), input);
  });

  render(shell(`${m.mentor_name} 권한`, null, [
    h("section", { class: "card" }, rows,
      h("button", {
        class: "btn primary block",
        style: { marginTop: "12px" },
        onclick: async () => {
          const permissions = {};
          for (const [scope, input] of toggles) permissions[scope] = input.checked;
          await guard(() => api.put(`/mentorships/${id}/permissions`, { permissions }));
          toast("변경했습니다");
          location.hash = "#/more";
        },
      }, "저장")),
    h("div", { class: "banner" }, "체중 대리 입력은 어떤 경우에도 열 수 없습니다."),
  ]));
}

// --------------------------------------------------------------------------
// Mentee detail (coach view), audit log, menu board
// --------------------------------------------------------------------------

async function menteeView(userId) {
  render(shell("멘티", null, loading()));
  const [meals, workouts] = await Promise.all([
    api.get("/meals", { query: { user_id: userId } }).catch(() => null),
    api.get("/workouts", { query: { user_id: userId } }).catch(() => null),
  ]);

  const noteInput = h("input", { class: "input", placeholder: "한 줄 남기기 (예: 오늘 단백질 좋았어요)" });
  const body = [
    h("section", { class: "card" }, h("h2", {}, "오늘 식단"),
      meals === null
        ? h("div", { class: "empty" }, "식단 조회 권한이 없습니다")
        : meals.length ? meals.map(mealRow) : h("div", { class: "empty" }, "기록 없음")),
    h("section", { class: "card" }, h("h2", {}, "오늘 운동"),
      workouts === null
        ? h("div", { class: "empty" }, "운동 조회 권한이 없습니다")
        : workouts.length
          ? workouts.map((w) => h("div", { class: "item" },
              h("div", { class: "grow" },
                h("strong", {}, `${w.sets.length}세트`),
                h("div", { class: "small muted truncate" },
                  w.sets.map((s) => `${s.exercise_name} ${s.weight_kg || ""}×${s.reps || ""}`).join(", ")))))
          : h("div", { class: "empty" }, "기록 없음")),
    h("section", { class: "card col" },
      h("h2", { style: { margin: 0 } }, "대신 기록하기"),
      h("button", {
        class: "btn primary block",
        onclick: async () => {
          const file = await pickFile();
          if (!file) return;
          const form = new FormData();
          form.append("file", await shrinkImage(file), "note.jpg");
          form.append("for_user_id", userId);
          const res = await guard(() => api.upload("/workouts/photo", form));
          if (res) { toast(`${res.sets.length}세트 기록했습니다`); menteeView(userId); }
        },
      }, "📷 수첩 찍어서 운동 기록"),
      h("div", { class: "row" }, noteInput,
        h("button", {
          class: "btn",
          onclick: async () => {
            if (!noteInput.value.trim()) return;
            await guard(() => api.post("/mentorships/comments", {
              target_user_id: Number(userId), entity: "day", body: noteInput.value.trim(),
            }));
            toast("코멘트를 남겼습니다");
            noteInput.value = "";
          },
        }, "남기기"))),
  ];
  render(shell("멘티", null, body));
}

async function auditView() {
  render(shell("변경 이력", null, loading()));
  const rows = await guard(() => api.get("/audit-log"));
  render(shell("변경 이력", "누가 내 기록을 건드렸는지", [
    h("section", { class: "card" },
      rows?.length
        ? rows.map((r) => h("div", { class: "item" },
            h("div", { class: "grow" },
              h("strong", { class: "small" }, `${r.actor_name || "?"} · ${r.action} ${r.entity}`),
              h("div", { class: "tiny dim" }, new Date(r.created_at).toLocaleString("ko-KR")))))
        : h("div", { class: "empty" }, "대리 기록 이력이 없습니다")),
  ]));
}

async function menuView(canteenId) {
  render(shell("식단표", null, loading()));
  const plans = await guard(() => api.get(`/canteens/${canteenId}/menu-plans`));
  if (!plans) return;

  const body = [
    h("section", { class: "card col" },
      h("button", {
        class: "btn primary block",
        onclick: async () => {
          const file = await pickFile();
          if (!file) return;
          const form = new FormData();
          form.append("file", await shrinkImage(file, 2000), "board.jpg");
          toast("식단표를 읽는 중…");
          const draft = await guard(() => api.upload(`/canteens/${canteenId}/menu-board`, form));
          if (!draft) return;
          const summary = draft.slots
            .map((s) => `${s.date} ${MEAL_LABEL[s.meal_type]}: ${s.items.map((i) => i.name).join(", ")}`)
            .join("\n");
          if (confirm(`이렇게 읽었습니다. 저장할까요?\n\n${summary}`)) {
            await guard(() => api.post(`/canteens/${canteenId}/menu-plans`, {
              slots: draft.slots.map((s) => ({
                date: s.date,
                meal_type: s.meal_type,
                items: s.items.map((i) => ({
                  name: i.name, category: i.category,
                  standard_g: i.standard_g, kcal_per_serving: i.kcal_per_serving,
                  food_id: i.matched_food_id,
                })),
              })),
              source: "photo",
              photo_path: draft.photo_path,
            }));
            toast("식단표를 저장했습니다");
            menuView(canteenId);
          }
        },
      }, "📷 주간 식단표 찍어서 올리기"),
      h("p", { class: "tiny dim", style: { margin: 0 } },
        "한 주에 한 번, 한 명만 올리면 같은 식당 사람 전부가 씁니다.")),
  ];

  if (!plans.length) {
    body.push(h("div", { class: "empty" }, "이번 주 식단표가 없습니다."));
  } else {
    for (const plan of plans) {
      body.push(
        h("section", { class: "card tight" },
          h("div", { class: "row between" },
            h("strong", {}, `${fmt.date(plan.date)} (${fmt.weekday(plan.date)}) ${MEAL_LABEL[plan.meal_type]}`),
            plan.verified ? null : h("span", { class: "badge warn" }, "확인 필요")),
          h("div", { class: "small muted" },
            plan.items.map((i) => `${i.name}(${Math.round(i.standard_g)}g)`).join(" · ")),
          h("button", {
            class: "btn sm ghost",
            style: { marginTop: "8px" },
            onclick: async () => {
              const res = await guard(() =>
                api.post(`/canteens/${canteenId}/menu-plans/${plan.id}/report`, { note: null }));
              if (res) toast(res.threshold_reached ? "재확인 대상으로 표시했습니다" : `신고 ${res.reports}건`);
            },
          }, "메뉴 틀림 신고")),
      );
    }
  }

  render(shell("식단표", "이번 주", body));
}

// --------------------------------------------------------------------------
// Router
// --------------------------------------------------------------------------

const ROUTES = [
  [/^\/login$/, loginView],
  [/^\/today$/, todayView],
  [/^\/log$/, logView],
  [/^\/week$/, weekView],
  [/^\/battle$/, battleView],
  [/^\/more$/, moreView],
  [/^\/meal\/(\d+)$/, mealView],
  [/^\/mentee\/(\d+)$/, menteeView],
  [/^\/permissions\/(\d+)$/, permissionsView],
  [/^\/invite\/([\w-]+)$/, inviteView],
  [/^\/menu\/(\d+)$/, menuView],
  [/^\/audit$/, auditView],
];

async function renderRoute() {
  const path = location.hash.slice(1) || "/today";

  // The invite screen is reachable while logged out — it is the first thing a
  // mentee sees, and forcing a login before showing what is being asked of
  // them gets the consent order backwards.
  const isPublic = path.startsWith("/invite/") || path === "/login";
  if (!getToken() && !isPublic) {
    render(loginView());
    return;
  }

  for (const [pattern, view] of ROUTES) {
    const match = path.match(pattern);
    if (match) return view(...match.slice(1));
  }
  location.hash = "#/today";
}

window.addEventListener("hashchange", renderRoute);
window.addEventListener("online", drainOutbox);

(async function boot() {
  state.pendingUploads = await outbox.count().catch(() => 0);
  await renderRoute();
  drainOutbox();

  if ("serviceWorker" in navigator) {
    navigator.serviceWorker.register("/sw.js", { scope: "/" }).catch(() => {});
  }
})();
