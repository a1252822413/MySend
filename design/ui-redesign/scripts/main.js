/* ============================================================
   交互层：
   1) 主题切换（dark / light，写入 localStorage，刷新不丢）
   2) 一次编排好的入场序列（IntersectionObserver + 错峰）
   3) 开关与设备卡的可点反馈（避免"看着像图"）
   全部动效在 prefers-reduced-motion 下由 CSS 直接关闭。
   ============================================================ */

(function () {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const root = document.documentElement;

  /* ---------- 1. 主题 ---------- */

  const buttons = Array.from(document.querySelectorAll('[data-theme-btn]'));

  function applyTheme(theme, persist) {
    root.dataset.theme = theme;
    buttons.forEach((b) => {
      b.setAttribute('aria-pressed', String(b.dataset.themeBtn === theme));
    });
    if (persist) {
      try {
        localStorage.setItem('kuai-theme', theme);
      } catch (e) {
        /* 隐私模式下忽略 */
      }
    }
  }

  // 首屏已由内联脚本设置，这里只同步按钮状态
  applyTheme(root.dataset.theme === 'light' ? 'light' : 'dark', false);

  buttons.forEach((b) => {
    b.addEventListener('click', () => applyTheme(b.dataset.themeBtn, true));
  });

  /* ---------- 2. 入场序列 ---------- */

  const reveals = Array.from(document.querySelectorAll('.reveal'));

  if (reduceMotion || !('IntersectionObserver' in window)) {
    reveals.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          const el = entry.target;
          const order = Number(el.dataset.order || 0);
          el.style.transitionDelay = order * 80 + 'ms';
          el.classList.add('in');
          io.unobserve(el);
        });
      },
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
    );

    const masthead = document.querySelectorAll('.masthead .reveal');
    masthead.forEach((el, i) => (el.dataset.order = String(i)));
    document.querySelectorAll('.screen-grid .reveal').forEach((el, i) => {
      el.dataset.order = String(i % 3);
    });

    reveals.forEach((el) => io.observe(el));
  }

  /* ---------- 3. 开关 ---------- */

  document.querySelectorAll('.toggle').forEach((toggle) => {
    const flip = () => {
      const next = toggle.getAttribute('aria-checked') === 'true' ? 'false' : 'true';
      toggle.setAttribute('aria-checked', next);
    };
    toggle.addEventListener('click', flip);
    toggle.addEventListener('keydown', (e) => {
      if (e.key === ' ' || e.key === 'Enter') {
        e.preventDefault();
        flip();
      }
    });
  });

  /* ---------- 4. 设备卡：键盘可达的按压反馈 ---------- */

  document.querySelectorAll('.device-card[role="button"]').forEach((card) => {
    const press = () => {
      card.style.borderColor = 'var(--accent)';
      window.setTimeout(() => {
        card.style.borderColor = '';
      }, 240);
    };
    card.addEventListener('click', press);
    card.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        press();
      }
    });
  });
})();
