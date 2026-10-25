'use strict';
// Gradal's PC window: three tabs (quizzes, students, settings) over the local API (pc/server.py).

const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const LETTERS = { ar: ['أ', 'ب', 'ج', 'د'], en: ['A', 'B', 'C', 'D'] };
const TF = { ar: ['صح', 'خطأ'], en: ['True', 'False'] };
const S = { state: null, paper: null, quiz: null, view: 'home' };
// Arabic counted nouns: 1, 2, 3-10, 11+
const count = (n, [one, two, few, many]) => (n === 1 ? one : n === 2 ? two : n >= 3 && n <= 10 ? `${n} ${few}` : `${n} ${many}`);
const QS = ['سؤال واحد', 'سؤالان', 'أسئلة', 'سؤالًا'], PAGES = ['صفحة واحدة', 'صفحتان', 'صفحات', 'صفحة'];
const STUDENTS = ['طالب واحد', 'طالبان', 'طلاب', 'طالبًا'], SHEETS = ['ورقة واحدة', 'ورقتان', 'أوراق', 'ورقة'];

async function api(method, path, body, raw) {
  const opts = { method, headers: { 'X-Gradal': '1' } };
  if (raw) { opts.body = raw.data; Object.assign(opts.headers, raw.headers); }
  else if (body !== undefined) { opts.body = JSON.stringify(body); opts.headers['Content-Type'] = 'application/json'; }
  const r = await fetch(path, opts);
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data.error || `خطأ ${r.status}`);
  return data;
}

function toast(msg, err) {
  const t = $('#toast');
  t.textContent = msg; t.className = 'toast' + (err ? ' err' : ''); t.hidden = false;
  clearTimeout(toast.timer); toast.timer = setTimeout(() => { t.hidden = true; }, err ? 6000 : 3000);
}
const guard = (fn) => async (...a) => { try { await fn(...a); } catch (e) { toast(e.message, true); } };

// ---------- state and tabs ----------

async function load() {
  S.state = await api('GET', '/api/state');
  renderHome(); renderStudents(); renderSettings();
}

$('#tabs').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-tab]'); if (b) showTab(b.dataset.tab);
});
function showTab(name) {
  $$('#tabs button').forEach((b) => b.classList.toggle('active', b.dataset.tab === name));
  $$('.tab').forEach((t) => t.classList.toggle('active', t.id === 'tab-' + name));
}
document.addEventListener('click', (e) => {
  const g = e.target.closest('[data-goto]'); if (g) { e.preventDefault(); showTab(g.dataset.goto); }
  if (e.target.closest('[data-back]')) showView('home');
});
function showView(v) {
  S.view = v;
  $('#quizHome').hidden = v !== 'home';
  for (const [id, name] of [['bookForm', 'book'], ['review', 'review'], ['manual', 'manual'], ['quizPage', 'quiz']]) $('#' + id).hidden = v !== name;
  window.scrollTo(0, 0);
  if (v === 'home') load().catch(() => {});
}

const classChips = (box, selected = []) => {
  const cls = S.state.classes;
  box.innerHTML = cls.length ? cls.map((c) => `<label><input type="checkbox" value="${c.id}" ${selected.includes(c.id) ? 'checked' : ''}> ${esc(c.name)}</label>`).join('')
    : '<span class="hint">لا فصول بعد: أضفها من تبويب «الطلاب».</span>';
};
const chosen = (box) => $$('input:checked', box).map((i) => i.value);
const className = (id) => (S.state.classes.find((c) => c.id === id) || {}).name || '';

// ---------- quizzes home ----------

function renderHome() {
  const st = S.state;
  $('#aiHint').hidden = st.ai.some((p) => p.linked);
  $('#draftsBox').hidden = !st.drafts.length;
  $('#drafts').innerHTML = st.drafts.map((d) => `<div class="card" data-draft="${d.id}"><span class="pill warn">مسودة</span><b>${esc(d.name)}</b><small>${count(d.count, QS)} — راجعها واعتمدها</small></div>`).join('');
  $('#quizList').innerHTML = st.quizzes.length ? st.quizzes.map((q) => `<div class="card" data-quiz="${q.id}">
      <span class="pill">${q.scans ? count(q.scans, SHEETS) : 'لم يُمسح بعد'}</span><b>${esc(q.name)}</b>
      <small>${esc(q.date)} · ${count(q.questionCount, QS)} · ${q.classIds.map(className).filter(Boolean).map(esc).join('، ') || 'بلا فصل'}</small></div>`).join('')
    : '<p class="empty">لا اختبارات بعد. ابدأ بـ«اختبار جديد من كتاب».</p>';
}
$('#drafts').addEventListener('click', guard(async (e) => { const c = e.target.closest('[data-draft]'); if (c) await openPaper(c.dataset.draft); }));
$('#quizList').addEventListener('click', guard(async (e) => { const c = e.target.closest('[data-quiz]'); if (c) await openQuiz(c.dataset.quiz); }));

// ---------- new test from a book ----------

$('#newFromBook').addEventListener('click', () => {
  if (!S.state.ai.some((p) => p.linked)) { toast('اربط مزوّد ذكاء اصطناعي أولًا من «الإعدادات»', true); showTab('settings'); return; }
  renderBooks(); classChips($('#bClasses')); $('#bProgress').hidden = true; $('#bStart').disabled = false; showView('book');
});
function renderBooks(selectId) {
  const b = S.state.books;
  $('#bBook').innerHTML = b.length ? b.map((x) => `<option value="${x.id}">${esc(x.name)} (${count(x.pages, PAGES)})</option>`).join('') : '<option value="">أضف كتابًا أولًا</option>';
  if (selectId) $('#bBook').value = selectId;
  bookInfo();
}
function bookInfo() {
  const b = S.state.books.find((x) => x.id === $('#bBook').value);
  $('#bBookInfo').textContent = b ? count(b.pages, PAGES) : '';
  if (b) { $('#bFrom').max = b.pages; $('#bTo').max = b.pages; }
}
$('#bBook').addEventListener('change', bookInfo);
$('#bUpload').addEventListener('change', guard(async (e) => {
  const f = e.target.files[0]; if (!f) return;
  toast('أرفع الكتاب…');
  const r = await api('POST', '/api/books', undefined, { data: f, headers: { 'X-Filename': encodeURIComponent(f.name), 'Content-Type': 'application/pdf' } });
  S.state = await api('GET', '/api/state'); renderBooks(r.book.id); e.target.value = ''; toast('أُضيف الكتاب');
}));
$('#bStart').addEventListener('click', guard(async () => {
  const req = { name: $('#bName').value, subject: $('#bSubject').value, grade: $('#bGrade').value, language: $('#bLang').value,
    bookId: $('#bBook').value, pageFrom: $('#bFrom').value, pageTo: $('#bTo').value, mcq: $('#bMcq').value, tf: $('#bTf').value,
    notes: $('#bNotes').value, classIds: chosen($('#bClasses')) };
  const { id } = await api('POST', '/api/exams', req);
  $('#bStart').disabled = true;
  const box = $('#bProgress'); box.hidden = false; box.className = 'progress';
  for (;;) {
    await new Promise((r) => setTimeout(r, 1500));
    const st = await api('GET', '/api/exams/' + id);
    box.textContent = st.messages.join('\n');
    if (st.state === 'error') { box.className = 'progress err'; box.textContent += '\n' + st.error; $('#bStart').disabled = false; return; }
    if (st.state === 'done') { await openPaper(st.result.paperId); return; }
  }
}));

// ---------- reviewing the questions ----------

async function openPaper(id) {
  S.state = await api('GET', '/api/state');
  S.paper = await api('GET', '/api/papers/' + id);
  const r = S.paper.request;
  $('#rTitle').textContent = S.paper.quizId ? 'تعديل الأسئلة' : 'راجع الأسئلة';
  $('#rName').value = r.name; $('#rSubject').value = r.subject || ''; $('#rGrade').value = r.grade || '';
  classChips($('#rClasses'), r.classIds || []);
  $('#rDelete').hidden = !!S.paper.quizId;
  $('#rApprove').textContent = S.paper.quizId ? 'احفظ التعديل' : 'اعتمد الاختبار';
  renderQuestions(); showView('review');
}
function renderQuestions() {
  const lang = S.paper.request.language, L = LETTERS[lang];
  $('#rQuestions').innerHTML = S.paper.questions.map((q, i) => {
    const opts = q.type === 'mcq'
      ? q.options.map((o, k) => `<label class="q-opt${q.answer === k ? ' right' : ''}"><input type="radio" name="a${i}" value="${k}" ${q.answer === k ? 'checked' : ''}> ${L[k]}) <input type="text" data-opt="${k}" value="${esc(o)}"></label>`).join('')
      : TF[lang].map((w, k) => `<label class="q-opt${(q.answer ? 0 : 1) === k ? ' right' : ''}"><input type="radio" name="a${i}" value="${k}" ${(q.answer ? 0 : 1) === k ? 'checked' : ''}> ${L[k]}) ${w}</label>`).join('');
    return `<div class="q" data-i="${i}"><div class="q-head"><b>${i + 1}.</b><span class="pill">${q.type === 'mcq' ? 'اختيار' : 'صح أو خطأ'}</span>
      <span class="spacer"></span><button class="btn danger ghost small" type="button" data-del>احذف</button></div>
      <textarea rows="2" data-text>${esc(q.text)}</textarea><div class="q-opts">${opts}</div></div>`;
  }).join('');
  const n = S.paper.questions.length;
  $('#rCount').textContent = `${count(n, QS)} (من ${S.state.minQuestions} إلى ${S.state.maxQuestions})`;
}
function readQuestions() {
  return $$('#rQuestions .q').map((box) => {
    const q = S.paper.questions[+box.dataset.i];
    const text = $('[data-text]', box).value.trim();
    const pick = $('input[type=radio]:checked', box);
    if (q.type === 'mcq') return { type: 'mcq', text, options: $$('[data-opt]', box).map((i) => i.value.trim()), answer: pick ? +pick.value : 0 };
    return { type: 'tf', text, answer: pick ? pick.value === '0' : true };
  });
}
$('#rQuestions').addEventListener('click', (e) => {
  if (!e.target.closest('[data-del]')) return;
  S.paper.questions = readQuestions(); S.paper.questions.splice(+e.target.closest('.q').dataset.i, 1); renderQuestions();
});
$('#rQuestions').addEventListener('change', (e) => {
  if (e.target.type === 'radio') { S.paper.questions = readQuestions(); renderQuestions(); }
});
$('#rAddMcq').addEventListener('click', () => { S.paper.questions = readQuestions(); S.paper.questions.push({ type: 'mcq', text: '', options: ['', '', '', ''], answer: 0 }); renderQuestions(); });
$('#rAddTf').addEventListener('click', () => { S.paper.questions = readQuestions(); S.paper.questions.push({ type: 'tf', text: '', answer: true }); renderQuestions(); });
const paperBody = () => ({ questions: readQuestions(), name: $('#rName').value, subject: $('#rSubject').value, grade: $('#rGrade').value, classIds: chosen($('#rClasses')) });
$('#rSave').addEventListener('click', guard(async () => { S.paper = await api('POST', '/api/papers/' + S.paper.id, paperBody()); toast('حُفظت المسودة'); }));
$('#rDelete').addEventListener('click', guard(async () => {
  if (!confirm('تُحذف المسودة نهائيًا؟')) return;
  await api('DELETE', '/api/papers/' + S.paper.id); showView('home');
}));
$('#rApprove').addEventListener('click', guard(async () => {
  const body = paperBody();
  if (!body.classIds.length && !confirm('لم تختر فصلًا: لن تُطبع أوراق بأسماء الطلاب، بل ورقة فارغة فقط. أتابع؟')) return;
  $('#rApprove').disabled = true;
  try {
    const { quiz } = await api('POST', `/api/papers/${S.paper.id}/approve`, body);
    toast('اعتُمد الاختبار، وتُجهَّز أوراقه…'); await openQuiz(quiz.id);
  } finally { $('#rApprove').disabled = false; }
}));

// ---------- a test with a ready key ----------

$('#newManual').addEventListener('click', () => { S.quiz = null; classChips($('#mClasses')); $('#mName').value = ''; $('#mSubject').value = ''; manualKey([]); showView('manual'); });
function manualKey(key) {
  const n = Math.max(0, Math.min(+$('#mCount').value || 0, S.state.maxQuestions)), L = LETTERS[$('#mLang').value];
  const old = key.length ? key : $$('#mKey .keyrow').map((r) => r.dataset.k || '');
  $('#mKey').innerHTML = Array.from({ length: n }, (_, i) => `<div class="keyrow" data-k="${old[i] || ''}"><b>${i + 1}</b>${
    ['A', 'B', 'C', 'D'].map((c, k) => `<button type="button" data-c="${c}" class="${(old[i] || '').includes(c) ? 'on' : ''}">${L[k]}</button>`).join('')}</div>`).join('');
}
$('#mCount').addEventListener('input', () => manualKey([]));
$('#mLang').addEventListener('change', () => manualKey([]));
$('#mKey').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-c]'); if (!b) return;
  const row = b.closest('.keyrow'); row.dataset.k = b.classList.contains('on') ? '' : b.dataset.c;
  $$('button', row).forEach((x) => x.classList.toggle('on', x.dataset.c === row.dataset.k));
});
$('#mSave').addEventListener('click', guard(async () => {
  const key = $$('#mKey .keyrow').map((r) => r.dataset.k || '');
  if (key.some((k) => !k) && !confirm('بعض الأسئلة بلا إجابة، فلن تُحتسب. أتابع؟')) return;
  const body = { name: $('#mName').value, language: $('#mLang').value, classIds: chosen($('#mClasses')), questionCount: key.length,
    keys: [key], header: { subject: $('#mSubject').value, title: $('#mName').value } };
  if (S.quiz) Object.assign(body, { id: S.quiz.id, code: S.quiz.code, header: { ...S.quiz.header, subject: $('#mSubject').value, title: $('#mName').value } });
  const { quiz } = await api('POST', '/api/quizzes', body);
  await openQuiz(quiz.id);
}));

// ---------- a quiz ----------

async function openQuiz(id) {
  S.state = await api('GET', '/api/state');
  const q = S.state.quizzes.find((x) => x.id === id); if (!q) return showView('home');
  S.quiz = q;
  $('#qTitle').textContent = q.name;
  $('#qMeta').textContent = `رمز الاختبار ${q.code} · ${count(q.questionCount, QS)} · ${q.language === 'ar' ? 'العربية' : 'English'} · ${q.classIds.map(className).filter(Boolean).join('، ') || 'بلا فصل'}`;
  $('#qRecord').href = `/api/quizzes/${q.id}/record`;
  showView('quiz');
  $('#qFiles').innerHTML = '<p class="hint">تُجهَّز الأوراق…</p>';
  loadResults();
  try {
    const { files } = await api('GET', `/api/quizzes/${q.id}/files`);
    $('#qFiles').innerHTML = files.map((f) => `<a class="file-card" target="_blank" href="/api/quizzes/${q.id}/file/${f.id}"><b>${esc(f.title)}</b><small>${count(f.pages, PAGES)} · افتح واطبع</small></a>`).join('');
  } catch (e) { $('#qFiles').innerHTML = `<p class="hint">${esc(e.message)}</p>`; }
}
async function loadResults() {
  const q = S.quiz, r = await api('GET', `/api/quizzes/${q.id}/results`), L = LETTERS[q.language] || LETTERS.en;
  const s = r.stats || {};
  $('#qStats').innerHTML = r.rows.length ? [['الأوراق', s.count], ['المتوسط', s.mean != null ? Math.round(s.mean) + '٪' : '—'],
    ['الأعلى', s.high != null ? Math.round(s.high) + '٪' : '—'], ['الأدنى', s.low != null ? Math.round(s.low) + '٪' : '—']]
    .map(([k, v]) => `<div class="stat"><small>${k}</small><b>${v ?? '—'}</b></div>`).join('') : '<p class="hint">لم تصل أوراق ممسوحة بعد. امسحها بالجوال ثم زامن.</p>';
  $('#qRows').innerHTML = r.rows.filter((x) => x.counted).map((x) => `<tr><td>${esc(x.gradalId)}</td>
    <td>${x.studentName ? esc(x.studentName) : `<span class="pill warn">رقم غير معروف ${esc(x.readId)}</span>`}</td>
    <td>${x.earned} / ${x.possible}</td><td>${Math.round(x.percent)}٪</td>
    <td>${x.hasImage ? `<a target="_blank" href="/api/scans/${x.id}/image">الورقة</a>` : ''}</td></tr>`).join('');
  $('#qItemsBox').hidden = !r.rows.length;
  $('#qTable').hidden = !r.rows.length;
  $('#qItems').innerHTML = (r.items || []).map((it, i) => `<div class="item"><b>${i + 1}</b> · ${it.percentCorrect != null ? Math.round(it.percentCorrect) + '٪ صحيحة' : 'لا يُحتسب'}
    <br><small>${['A', 'B', 'C', 'D'].map((c, k) => `${L[k]}: ${(it.counts || {})[c] || 0}`).join(' · ')} · فارغ: ${(it.counts || {}).blank || 0}</small></div>`).join('');
}
$('#qRefresh').addEventListener('click', guard(loadResults));
$('#qEdit').addEventListener('click', guard(async () => {
  const q = S.quiz;
  if (q.paperId) return openPaper(q.paperId);
  classChips($('#mClasses'), q.classIds); $('#mName').value = q.name; $('#mSubject').value = (q.header || {}).subject || '';
  $('#mLang').value = q.language || 'en'; $('#mCount').value = q.questionCount; manualKey(q.keys[0]); showView('manual');
}));
$('#qDelete').addEventListener('click', guard(async () => {
  if (!confirm(`يُحذف «${S.quiz.name}» ونتائجه؟`)) return;
  await api('DELETE', '/api/quizzes/' + S.quiz.id); showView('home');
}));

// ---------- students ----------

function renderStudents() {
  const st = S.state;
  $('#classList').innerHTML = st.classes.map((c) => {
    const mine = st.students.filter((s) => s.classIds.includes(c.id) && s.active !== false);
    return `<details class="box class-box"><summary>${esc(c.name)} — ${count(mine.length, STUDENTS)} (أرقامهم تبدأ بـ ${c.prefix})</summary>
      <div class="scroll"><table class="grid-table"><thead><tr><th>الرقم</th><th>الاسم</th></tr></thead><tbody>
      ${mine.map((s) => `<tr><td>${esc(s.gradalId)}</td><td>${esc(s.name)}</td></tr>`).join('')}</tbody></table></div>
      <div class="row"><button class="btn danger ghost small" type="button" data-archive="${c.id}">انقل الفصل إلى الأرشيف</button></div></details>`;
  }).join('') || '<p class="empty">لا فصول بعد.</p>';
}
$('#iFile').addEventListener('change', guard(async (e) => {
  const f = e.target.files[0]; if (!f) return;
  try {
    const r = await api('POST', '/api/students/import', undefined, { data: f, headers: { 'X-Filename': encodeURIComponent(f.name), 'X-Class': encodeURIComponent($('#iClass').value) } });
    toast(r.classes.map((c) => `${c.name}: ${count(c.count, STUDENTS)} (الجدد ${c.added})`).join(' · ')); await load();
  } finally { e.target.value = ''; }
}));
$('#pAdd').addEventListener('click', guard(async () => {
  const r = await api('POST', '/api/students/paste', { text: $('#pNames').value, className: $('#pClass').value });
  toast(r.classes.map((c) => `${c.name}: ${count(c.count, STUDENTS)}`).join(' · ')); $('#pNames').value = ''; await load();
}));
$('#classList').addEventListener('click', guard(async (e) => {
  const b = e.target.closest('[data-archive]'); if (!b) return;
  if (!confirm('يُنقل الفصل وطلابه إلى الأرشيف، وتبقى نتائجه القديمة. أتابع؟')) return;
  await api('POST', `/api/classes/${b.dataset.archive}/archive`); await load();
}));
$('#newYear').addEventListener('click', guard(async () => {
  if (!confirm('تُنقل كل الفصول الحالية وطلابها إلى الأرشيف لتبدأ سنة جديدة. أتابع؟')) return;
  await api('POST', '/api/new-year', { label: S.state.yearLabel }); toast('بدأت سنة جديدة: استورد قوائم الفصول'); await load();
}));

// ---------- settings ----------

function renderSettings() {
  const st = S.state, s = st.settings;
  $('#aiList').innerHTML = st.ai.map((p) => `<div class="provider${p.linked ? ' on' : ''}" data-p="${p.id}">
    <div class="provider-head"><b>${esc(p.name)}</b><span class="pill${p.free ? '' : ' warn'}">${p.free ? 'مجاني' : 'رخيص'}</span>${p.linked ? '<span class="pill">مربوط ✓</span>' : ''}</div>
    <p>${esc(p.note)}</p>
    ${p.linked ? `<p>النموذج: <code>${esc(p.model)}</code> · المفتاح ينتهي بـ <code>${esc(p.keyEnd)}</code></p>${p.lastError ? `<p class="err">آخر خطأ: ${esc(p.lastError)}</p>` : ''}
      <div class="row"><button class="btn danger ghost small" type="button" data-unlink>ألغِ الربط</button></div>`
    : `<div class="row"><a class="btn ghost small" target="_blank" href="${esc(p.keyUrl)}">افتح صفحة المفتاح</a></div>
      <div class="row"><input type="password" placeholder="الصق المفتاح هنا" data-key autocomplete="off"><button class="btn small" type="button" data-link>اربط</button></div>`}
  </div>`).join('');
  const pin = st.pin;
  $('#pinBox').hidden = !pin;
  if (pin) $('#pinBox').textContent = pin.code;
  $('#lanInfo').textContent = st.lan.length ? `عنوان هذا الكمبيوتر على الشبكة: ${st.lan.join('، ')} — المنفذ 7797` : 'هذا الكمبيوتر غير متصل بشبكة.';
  $('#devices').innerHTML = st.devices.map((d) => `<div class="row"><b>${esc(d.name)}</b><small class="hint">آخر اتصال ${esc((d.lastSeen || '').replace('T', ' ').slice(0, 16))}</small>
    <button class="btn danger ghost small" type="button" data-dev="${d.id}">ألغِ الاقتران</button></div>`).join('');
  if (!document.activeElement || !document.activeElement.closest('#tab-settings')) {
    $$('.sLine').forEach((el, i) => { el.value = (s.schoolLines || [])[i] || ''; });
    $('#sTeacher').value = s.teacher || '';
    $('#sLogo').hidden = !s.logo; if (s.logo) $('#sLogo').src = s.logo;
  }
  $('#dataDir').textContent = st.dataDir;
}
$('#aiList').addEventListener('click', guard(async (e) => {
  const box = e.target.closest('[data-p]'); if (!box) return;
  if (e.target.closest('[data-link]')) {
    const key = $('[data-key]', box).value;
    toast('أتحقق من المفتاح…');
    const r = await api('POST', `/api/ai/${box.dataset.p}/link`, { key });
    toast(`رُبط بنجاح، والنموذج المختار ${r.model}`); await load();
  }
  if (e.target.closest('[data-unlink]')) { await api('POST', `/api/ai/${box.dataset.p}/unlink`); await load(); }
}));
$('#devices').addEventListener('click', guard(async (e) => {
  const b = e.target.closest('[data-dev]'); if (!b) return;
  await api('DELETE', '/api/devices/' + b.dataset.dev); await load();
}));
$('#sSave').addEventListener('click', guard(async () => {
  await api('POST', '/api/settings', { schoolLines: $$('.sLine').map((i) => i.value), teacher: $('#sTeacher').value });
  toast('حُفظ رأس الورقة'); await load();
}));
$('#sLogoFile').addEventListener('change', guard(async (e) => {
  const f = e.target.files[0]; if (!f) return;
  const data = await new Promise((res) => { const r = new FileReader(); r.onload = () => res(r.result); r.readAsDataURL(f); });
  await api('POST', '/api/settings', { logo: data }); e.target.value = ''; toast('حُفظ الشعار'); await load();
}));
$('#sLogoClear').addEventListener('click', guard(async () => { await api('POST', '/api/settings', { logo: '' }); await load(); }));
$('#openData').addEventListener('click', guard(() => api('POST', '/api/open-data')));

// the PIN appears when the phone asks to pair: poll lightly while the window is open
setInterval(async () => {
  try {
    const st = await api('GET', '/api/state');
    const pinChanged = JSON.stringify(st.pin) !== JSON.stringify(S.state && S.state.pin);
    const devChanged = JSON.stringify(st.devices) !== JSON.stringify(S.state && S.state.devices);
    S.state = st;
    if (pinChanged || devChanged) { renderSettings(); if (st.pin) showTab('settings'); }
  } catch { /* the server is restarting */ }
}, 3000);

load().then(() => { const m = location.hash.match(/^#quiz=([0-9a-f-]+)$/); if (m) return openQuiz(m[1]); })
  .catch((e) => toast(e.message, true));
