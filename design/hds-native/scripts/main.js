/* ============================================================
   交互层：主题切换 + 入场序列 + 开关
   ============================================================ */

(function () {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;
  const buttons = Array.from(document.querySelectorAll('[data-theme-btn]'));

  function applyTheme(theme, persist) {
    root.dataset.theme = theme;
    buttons.forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.themeBtn === theme));
    });
    if (persist) {
      try {
        localStorage.setItem('kuai-hds-theme', theme);
      } catch (e) {
        /* 隐私模式忽略 */
      }
    }
  }

  applyTheme(root.dataset.theme === 'dark' ? 'dark' : 'light', false);

  buttons.forEach((b) => {
    b.addEventListener('click', () => applyTheme(b.dataset.themeBtn, true));
  });

  /* ---------- 入场：80ms 错峰 ---------- */

  const reveals = Array.from(document.querySelectorAll('.reveal'));

  if (reduceMotion || !('IntersectionObserver' in window)) {
    reveals.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          const el = entry.target;
          el.style.transitionDelay = Number(el.dataset.order || 0) * 80 + 'ms';
          el.classList.add('in');
          io.unobserve(el);
        });
      },
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
    );

    document.querySelectorAll('.masthead .reveal').forEach((el, i) => (el.dataset.order = String(i)));
    document.querySelectorAll('.screen-grid .reveal').forEach((el, i) => {
      el.dataset.order = String(i % 3);
    });

    reveals.forEach((el) => io.observe(el));
  }

  /* ---------- 开关 ---------- */

  document.querySelectorAll('.switch').forEach((sw) => {
    const flip = () => {
      sw.setAttribute('aria-checked', sw.getAttribute('aria-checked') === 'true' ? 'false' : 'true');
    };
    sw.addEventListener('click', flip);
    sw.addEventListener('keydown', (e) => {
      if (e.key === ' ' || e.key === 'Enter') {
        e.preventDefault();
        flip();
      }
    });
  });
})();
