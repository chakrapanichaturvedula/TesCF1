/* cf.js: course platform client, loaded on every course page.

   Add three script tags to a page's head, in this order:
     assets/js/config.js, assets/js/vendor/supabase-2.117.3.js, assets/js/cf.js

   What it does
   - asks a student for their ID once, then remembers this browser
   - hides a page that has not been released to the student's section
   - records the step reached and the active time on the page
   - lets a page record an activity result: CF.submitAttempt('key', score, max)
   - never blocks learning if the service is unreachable: the page opens and
     a small notice says progress is not being saved
   The page slug is the file name without .html (or set data-page on the tag). */
(function () {
  'use strict';

  var CFG = window.CF_CONFIG || {};
  var SCRIPT = document.currentScript;
  var PAGE = (SCRIPT && SCRIPT.getAttribute('data-page')) ||
    (location.pathname.split('/').pop() || 'index').replace(/\.html?$/i, '');

  var FLUSH_MS = 30000;     // send progress this often
  var IDLE_MS = 60000;      // stop counting time after this long without input
  var BOOT_TIMEOUT_MS = 10000;

  var state = {
    client: null, token: null, profile: null, staff: false,
    tracking: false, step: 1, furthest: 1, sentStep: 0,
    pending: 0, lastInput: Date.now(), booted: false
  };

  /* ---- hide the page until we know it may be shown ---- */
  var hold = document.createElement('style');
  hold.id = 'cf-hold';
  hold.textContent = 'body>*:not(.cf-ui){visibility:hidden!important}';
  (document.head || document.documentElement).appendChild(hold);
  function reveal() { if (hold.parentNode) hold.parentNode.removeChild(hold); }

  /* ---- small helpers ---- */
  function el(tag, attrs, text) {
    var e = document.createElement(tag);
    if (attrs) for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;
    return e;
  }
  function onReady(fn) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fn);
    else fn();
  }

  var CSS = [
    '.cf-ui{font-family:var(--body,"IBM Plex Sans","Segoe UI",Arial,sans-serif);color:var(--ink,#16223A)}',
    '.cf-overlay{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;padding:20px;background:var(--bg,#F4F4F1);overflow:auto}',
    '.cf-card{width:100%;max-width:420px;background:var(--surface,#fff);border:1px solid var(--line,#DADDD8);border-radius:16px;padding:28px 26px;box-shadow:0 1px 2px rgba(0,0,0,.04)}',
    '.cf-eyebrow{font-size:12px;letter-spacing:.14em;text-transform:uppercase;color:var(--accent,#6B3FA0);font-weight:600;margin:0 0 6px}',
    '.cf-card h2{font-family:var(--display,Georgia,serif);font-size:26px;line-height:1.15;margin:0 0 10px;color:var(--ink,#16223A)}',
    '.cf-card p{margin:0 0 14px;font-size:15px;line-height:1.5;color:var(--muted,#5B6578)}',
    '.cf-card label{display:block;font-size:13px;font-weight:600;margin:0 0 6px;color:var(--ink,#16223A)}',
    '.cf-card input{box-sizing:border-box;width:100%;font:inherit;font-size:17px;padding:11px 12px;border:1.5px solid var(--line,#DADDD8);border-radius:10px;background:var(--bg,#F4F4F1);color:var(--ink,#16223A);text-transform:uppercase}',
    '.cf-card input:focus{outline:2px solid var(--accent,#6B3FA0);outline-offset:1px;border-color:var(--accent,#6B3FA0)}',
    '.cf-btn{font:inherit;font-weight:600;font-size:16px;margin-top:14px;width:100%;padding:11px 14px;border:0;border-radius:10px;background:var(--accent,#6B3FA0);color:var(--surface,#fff);cursor:pointer}',
    '.cf-btn:disabled{opacity:.6;cursor:default}',
    '.cf-err{min-height:20px;margin:8px 0 0!important;font-size:14px!important;color:#B3261E!important}',
    '.cf-small{font-size:12.5px!important;margin:14px 0 0!important}',
    '.cf-link{display:inline-block;margin-top:6px;font-weight:600;color:var(--accent,#6B3FA0);text-decoration:none}',
    '.cf-link:hover{text-decoration:underline}',
    '.cf-chip{position:fixed;right:12px;bottom:12px;z-index:2147482000;display:flex;gap:8px;align-items:center;font-size:12.5px;padding:6px 6px 6px 12px;border-radius:999px;background:var(--surface,#fff);border:1px solid var(--line,#DADDD8);color:var(--muted,#5B6578);box-shadow:0 1px 2px rgba(0,0,0,.05)}',
    '.cf-chip button{font:inherit;font-size:12.5px;border:0;background:var(--accent-soft,#EEE6F7);color:var(--accent,#6B3FA0);border-radius:999px;padding:4px 10px;cursor:pointer;font-weight:600}',
    '.cf-banner{position:fixed;left:50%;transform:translateX(-50%);bottom:12px;z-index:2147482000;max-width:calc(100% - 24px);display:flex;gap:10px;align-items:center;font-size:13.5px;padding:8px 8px 8px 14px;border-radius:12px;background:var(--surface,#fff);border:1px solid var(--line,#DADDD8);color:var(--ink,#16223A);box-shadow:0 2px 8px rgba(0,0,0,.08)}',
    '.cf-banner button{font:inherit;font-size:13px;border:0;background:transparent;color:var(--accent,#6B3FA0);cursor:pointer;font-weight:600}'
  ].join('\n');

  function injectCss() {
    if (document.getElementById('cf-style')) return;
    var s = el('style', { id: 'cf-style' });
    s.textContent = CSS;
    document.head.appendChild(s);
  }

  function setInert(on, except) {
    var kids = document.body.children;
    for (var i = 0; i < kids.length; i++) {
      if (kids[i] === except) continue;
      if (on) kids[i].setAttribute('inert', ''); else kids[i].removeAttribute('inert');
    }
  }

  function banner(message) {
    onReady(function () {
      injectCss();
      if (document.querySelector('.cf-banner')) return;
      var b = el('div', { 'class': 'cf-ui cf-banner', role: 'status' });
      b.appendChild(el('span', null, message));
      var x = el('button', { type: 'button' }, 'Dismiss');
      x.addEventListener('click', function () { b.remove(); });
      b.appendChild(x);
      document.body.appendChild(b);
    });
  }

  /* ---- the ID box ---- */
  function askForId() {
    clearTimeout(bootTimer);   // waiting for the student is not a failure
    return new Promise(function (resolve) {
      onReady(function () {
        injectCss();
        var ov = el('div', { 'class': 'cf-ui cf-overlay' });
        var card = el('div', { 'class': 'cf-card', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'cf-title' });
        card.appendChild(el('p', { 'class': 'cf-eyebrow' }, 'FIA 203 Corporate Finance'));
        card.appendChild(el('h2', { id: 'cf-title' }, 'Enter your student ID'));
        card.appendChild(el('p', null, 'You only need to do this once on this device. Your instructor can then see which topics you have covered.'));
        var form = el('form', { autocomplete: 'off' });
        form.appendChild(el('label', { 'for': 'cf-id' }, 'Student ID'));
        var input = el('input', { id: 'cf-id', type: 'text', autocomplete: 'off', autocapitalize: 'characters', spellcheck: 'false', required: 'required' });
        form.appendChild(input);
        var err = el('p', { 'class': 'cf-err', role: 'alert' });
        form.appendChild(err);
        var btn = el('button', { type: 'submit', 'class': 'cf-btn' }, 'Continue');
        form.appendChild(btn);
        card.appendChild(form);
        card.appendChild(el('p', { 'class': 'cf-small' }, 'Your ID, name and section are used only to record which pages and activities you complete. The records are deleted after the term. Cannot find your ID? Ask your instructor.'));
        ov.appendChild(card);
        document.body.appendChild(ov);
        setInert(true, ov);
        input.focus();

        form.addEventListener('submit', function (ev) {
          ev.preventDefault();
          var code = input.value.trim();
          if (!code) { err.textContent = 'Enter your ID first.'; return; }
          btn.disabled = true; err.textContent = '';
          state.client.rpc('claim_student', {
            p_offering_slug: CFG.offering, p_student_code: code, p_class_key: null
          }).then(function (r) {
            btn.disabled = false;
            if (r.error) {
              err.textContent = /too many/i.test(r.error.message || '')
                ? r.error.message : 'Something went wrong. Check your connection and try again.';
              return;
            }
            if (!r.data) { err.textContent = 'We could not find that ID. Check it and try again.'; return; }
            setInert(false, ov);
            ov.remove();
            armTimer();
            resolve(r.data);
          }, function () {
            btn.disabled = false;
            err.textContent = 'Something went wrong. Check your connection and try again.';
          });
        });
      });
    });
  }

  /* ---- message shown instead of a page that is not released ---- */
  function showNotReleased() {
    onReady(function () {
      injectCss();
      var ov = el('div', { 'class': 'cf-ui cf-overlay' });
      var card = el('div', { 'class': 'cf-card', role: 'dialog', 'aria-modal': 'true', 'aria-labelledby': 'cf-title' });
      card.appendChild(el('p', { 'class': 'cf-eyebrow' }, 'FIA 203 Corporate Finance'));
      card.appendChild(el('h2', { id: 'cf-title' }, 'Not open yet'));
      card.appendChild(el('p', null, 'This page has not been released to your section yet. Your instructor will open it when it is time.'));
      var a = el('a', { 'class': 'cf-link', href: 'index.html' }, '← All FIA 203 topics');
      card.appendChild(a);
      ov.appendChild(card);
      document.body.appendChild(ov);
      setInert(true, ov);
    });
  }

  /* ---- who is signed in ---- */
  function showChip() {
    onReady(function () {
      injectCss();
      var chip = el('div', { 'class': 'cf-ui cf-chip' });
      var label;
      if (state.staff) label = 'Preview as staff · not recorded';
      else label = state.profile.name + ' · Section ' + state.profile.section;
      chip.appendChild(el('span', null, label));
      var b = el('button', { type: 'button' }, state.staff ? 'Sign out' : 'Not you?');
      b.addEventListener('click', function () {
        flush(false);
        state.client.auth.signOut().then(function () { location.reload(); },
                                         function () { location.reload(); });
      });
      chip.appendChild(b);
      document.body.appendChild(chip);
    });
  }

  /* ---- progress and active time ---- */
  function rpcBody(secs, step, completed) {
    return { p_item_slug: PAGE, p_step: step, p_seconds: secs, p_completed: !!completed };
  }

  function flush(keepalive, completed) {
    if (!state.tracking) return;
    var secs = state.pending;
    var step = state.furthest;
    if (!secs && step === state.sentStep && !completed) return;
    state.pending = 0;
    state.sentStep = step;
    var body = rpcBody(secs, step, completed);
    if (keepalive && state.token) {
      try {
        fetch(CFG.supabaseUrl + '/rest/v1/rpc/track_progress', {
          method: 'POST', keepalive: true,
          headers: { 'Content-Type': 'application/json', apikey: CFG.supabaseKey, Authorization: 'Bearer ' + state.token },
          body: JSON.stringify(body)
        });
      } catch (e) { /* page is closing; nothing more to do */ }
      return;
    }
    return state.client.rpc('track_progress', body).then(function (r) {
      if (r.error) { state.pending += secs; state.sentStep = 0; }
    }, function () { state.pending += secs; state.sentStep = 0; });
  }

  function startTracking() {
    state.tracking = true;
    ['pointerdown', 'keydown', 'wheel', 'touchstart', 'scroll', 'input'].forEach(function (t) {
      window.addEventListener(t, function () { state.lastInput = Date.now(); }, { passive: true, capture: true });
    });
    setInterval(function () {
      if (document.visibilityState === 'visible' && Date.now() - state.lastInput < IDLE_MS) state.pending += 1;
    }, 1000);
    setInterval(function () { flush(false); }, FLUSH_MS);
    document.addEventListener('visibilitychange', function () {
      if (document.visibilityState === 'hidden') flush(true);
    });
    window.addEventListener('pagehide', function () { flush(true); });
    watchSteps();
    flush(false);   // records that the page was opened
  }

  /* A step is a button in .stepper that becomes aria-selected="true". */
  function watchSteps() {
    var mo = new MutationObserver(function (list) {
      for (var i = 0; i < list.length; i++) {
        var t = list[i].target;
        if (t.getAttribute && t.getAttribute('aria-selected') === 'true' && t.closest && t.closest('.stepper')) {
          var buttons = t.closest('.stepper').querySelectorAll('button');
          var n = Array.prototype.indexOf.call(buttons, t) + 1;
          if (n > 0) setStep(n);
        }
      }
    });
    mo.observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ['aria-selected'] });
  }

  function setStep(n) {
    state.step = n;
    if (n > state.furthest) { state.furthest = n; flush(false); }
  }

  /* ---- start ---- */
  var bootTimer = null;
  function armTimer() {
    clearTimeout(bootTimer);
    bootTimer = setTimeout(function () { failOpen('timeout'); }, BOOT_TIMEOUT_MS);
  }

  function failOpen(why) {
    if (state.booted) return;
    state.booted = true;
    reveal();
    if (window.console) console.warn('cf.js: not tracking (' + why + ')');
    banner('Your progress is not being saved right now. You can keep working.');
  }

  async function boot() {
    if (!window.supabase || !CFG.supabaseUrl || !CFG.supabaseKey) throw new Error('not configured');
    state.client = window.supabase.createClient(CFG.supabaseUrl, CFG.supabaseKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false, storageKey: 'cf-fia203-auth' }
    });
    state.client.auth.onAuthStateChange(function (ev, s) { state.token = s ? s.access_token : null; });

    var got = await state.client.auth.getSession();
    var session = got.data && got.data.session;
    if (!session) {
      var anon = await state.client.auth.signInAnonymously();
      if (anon.error) throw anon.error;
      session = anon.data.session;
    }
    state.token = session.access_token;
    state.staff = session.user && session.user.is_anonymous === false;

    if (state.staff) {
      if (state.booted) return;
      state.booted = true; reveal(); showChip();
      return;
    }

    var prof = await state.client.rpc('my_profile');
    if (prof.error) throw prof.error;
    state.profile = prof.data;
    if (!state.profile) {
      await askForId();
      prof = await state.client.rpc('my_profile');
      if (prof.error) throw prof.error;
      state.profile = prof.data;
      if (!state.profile) throw new Error('claim did not stick');
    }

    var content = await state.client.rpc('my_content');
    if (content.error) throw content.error;
    var item = null;
    (content.data || []).forEach(function (c) { if (c.slug === PAGE && c.kind === 'page') item = c; });

    if (state.booted) return;
    state.booted = true;
    if (PAGE === 'index') {
      // The topic list: show closed topics as "Coming soon"; nothing is tracked here.
      var open = {};
      (content.data || []).forEach(function (c) { if (c.kind === 'page') open[c.file || (c.slug + '.html')] = c.released; });
      var cards = document.querySelectorAll('a.card[href]');
      for (var i = 0; i < cards.length; i++) {
        var a = cards[i], f = (a.getAttribute('href') || '').split('/').pop();
        if (open[f] === false) {
          var d = document.createElement('div');
          d.className = 'card soon'; d.innerHTML = a.innerHTML;
          var para = d.querySelector('p'); if (para) para.textContent = 'Coming soon.';
          a.parentNode.replaceChild(d, a);
        }
      }
      reveal(); showChip();
      return;
    }
    if (!item) {
      // This page is not in the course map: show it, but do not track it.
      reveal(); showChip();
      if (window.console) console.warn('cf.js: page "' + PAGE + '" is not registered; not tracking');
      return;
    }
    if (!item.released) { showNotReleased(); reveal(); showChip(); return; }
    reveal(); showChip();
    startTracking();
  }

  armTimer();
  boot().catch(function (e) { failOpen(e && e.message ? e.message : 'error'); });

  /* ---- for pages ---- */
  window.CF = {
    page: PAGE,
    profile: function () { return state.profile; },
    setStep: setStep,
    complete: function () { return flush(false, true); },
    submitAttempt: function (key, score, max, seconds, detail) {
      if (!state.tracking) return Promise.resolve(null);
      return state.client.rpc('submit_attempt', {
        p_item_slug: PAGE, p_activity_key: key,
        p_score: score == null ? null : score, p_max_score: max == null ? null : max,
        p_seconds: seconds == null ? null : Math.round(seconds), p_detail: detail || {}
      }).then(function (r) { return r.error ? null : r.data; }, function () { return null; });
    }
  };
})();
