/* ============================================================
   交互层：
   1) 一次编排好的入场序列（IntersectionObserver + 错峰）
   2) 原型里的开关可点（真实反馈，避免"看着像图"）
   3) 键盘可达（空格切换开关 / 回车跳到元素）
   全部动效在 prefers-reduced-motion 下由 CSS 直接关闭。
   ============================================================ */

(function () {
  'use strict';

  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------- 1. 入场序列 ---------- */

  const reveals = Array.from(document.querySelectorAll('.reveal'));

  if (reduceMotion || !('IntersectionObserver' in window)) {
    reveals.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          const el = entry.target;
          // 同一批出现的元素错峰 80ms，最多 6 段
          const order = Number(el.dataset.order || 0);
          el.style.transitionDelay = order * 80 + 'ms';
          el.classList.add('in');
          io.unobserve(el);
        });
      },
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' }
    );

    // 页头三个元素固定 0 / 80 / 160ms；屏幕区按列顺序 0–5
    const masthead = document.querySelectorAll('.masthead .reveal');
    masthead.forEach((el, i) => (el.dataset.order = String(i)));
    document.querySelectorAll('.screen-grid .reveal').forEach((el, i) => {
      el.dataset.order = String(i % 3);
    });

    reveals.forEach((el) => io.observe(el));
  }

  /* ---------- 2. 开关 ---------- */

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

  /* ---------- 3. 设备行：键盘可达的选中反馈 ---------- */

  document.querySelectorAll('.device-row[role="button"]').forEach((row) => {
    const press = () => {
      row.style.background = 'rgba(59, 228, 154, 0.09)';
      window.setTimeout(() => {
        row.style.background = '';
      }, 220);
    };
    row.addEventListener('click', press);
    row.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        press();
      }
    });
  });
})();
