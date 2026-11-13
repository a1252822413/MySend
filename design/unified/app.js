/* 快传 · 双端统一设计评审板交互 v1.3
   只负责四件事：主题、系统材质预览、视图/页面、弹窗与顶部提醒切换；不注入任何视觉值。 */

(function () {
  'use strict';

  var root = document.documentElement;
  var stage = document.getElementById('stage');
  var themeSeg = document.getElementById('themeSeg');
  var materialSeg = document.getElementById('materialSeg');
  var viewSeg = document.getElementById('viewSeg');
  var pageSeg = document.getElementById('pageSeg');
  var dialogSeg = document.getElementById('dialogSeg');
  var dialogGroup = document.getElementById('dialogGroup');
  var toastSeg = document.getElementById('toastSeg');
  var toastGroup = document.getElementById('toastGroup');
  var pages = Array.prototype.slice.call(document.querySelectorAll('.page'));
  var navItems = Array.prototype.slice.call(document.querySelectorAll('[data-nav]'));
  var materials = ['mica', 'acrylic', 'solid'];
  var PAGE_TOAST = { receive: 'receive-ok', send: 'send-ok' };
  var basePage = 'receive';

  function markActive(container, attr, value) {
    var buttons = container.querySelectorAll('button[' + attr + ']');
    Array.prototype.forEach.call(buttons, function (b) {
      var on = b.getAttribute(attr) === value;
      b.classList.toggle('is-on', on);
      b.setAttribute('aria-pressed', on ? 'true' : 'false');
    });
  }

  function setTheme(value) {
    root.setAttribute('data-theme', value);
    markActive(themeSeg, 'data-theme-value', value);
    try { localStorage.setItem('kuaichuan-preview-theme', value); } catch (e) { /* 忽略隐私模式 */ }
  }

  function setMaterial(value) {
    root.setAttribute('data-material', value);
    markActive(materialSeg, 'data-material-value', value);
    try { localStorage.setItem('kuaichuan-preview-material', value); } catch (e) { /* ignore */ }
  }

  function setView(value) {
    stage.setAttribute('data-view', value);
    markActive(viewSeg, 'data-view-value', value);
  }

  function setDialog(value) {
    stage.setAttribute('data-dialog', value);
    Array.prototype.forEach.call(document.querySelectorAll('[data-dialog]'), function (el) {
      el.classList.toggle('is-shown', el.getAttribute('data-dialog') === value);
    });
    markActive(dialogSeg, 'data-dialog-value', value);
  }

  function showPage(value) {
    stage.setAttribute('data-page', value);
    pages.forEach(function (p) {
      p.classList.toggle('is-active', p.getAttribute('data-page') === value);
    });
    navItems.forEach(function (n) {
      var isPhone = !!n.closest('.device-phone');
      var want = (isPhone && value === 'devices') ? 'settings' : value;
      n.classList.toggle('is-on', n.getAttribute('data-nav') === want);
    });
  }

  function toastPage(value) {
    return value && value.indexOf('receive') === 0 ? 'receive' : 'send';
  }

  function setToast(value) {
    stage.setAttribute('data-toast', value || 'none');
    markActive(toastSeg, 'data-toast-value', value);
    // 在「提醒」场景里，提醒与页面必须对得上：接收类看接收页，发送类看发送页
    if (stage.getAttribute('data-scene') === 'toasts' && value) {
      showPage(toastPage(value));
      markActive(pageSeg, 'data-page-value', 'toasts');
    }
  }

  function setScene(value) {
    stage.setAttribute('data-scene', value);
    dialogGroup.classList.toggle('is-hidden', value !== 'dialogs');
    toastGroup.classList.toggle('is-hidden', value !== 'toasts');
  }

  function setPage(value) {
    if (value === 'dialogs') {
      setScene('dialogs');
      markActive(pageSeg, 'data-page-value', 'dialogs');
      return;
    }
    // 「提醒」不换页面骨架：叠在当前页上，便于看覆盖关系
    if (value === 'toasts') {
      setScene('toasts');
      markActive(pageSeg, 'data-page-value', 'toasts');
      var cur = stage.getAttribute('data-toast');
      if (cur && cur !== 'none') { showPage(toastPage(cur)); }
      return;
    }
    setScene('pages');
    basePage = value;
    showPage(value);
    markActive(pageSeg, 'data-page-value', value);
    setToast(PAGE_TOAST[value] || 'none');
  }

  function bindSeg(container, attr, handler) {
    container.addEventListener('click', function (e) {
      var btn = e.target.closest('button[' + attr + ']');
      if (btn) { handler(btn.getAttribute(attr)); }
    });
  }

  bindSeg(themeSeg, 'data-theme-value', setTheme);
  bindSeg(materialSeg, 'data-material-value', setMaterial);
  bindSeg(viewSeg, 'data-view-value', setView);
  bindSeg(pageSeg, 'data-page-value', setPage);
  bindSeg(dialogSeg, 'data-dialog-value', setDialog);
  bindSeg(toastSeg, 'data-toast-value', setToast);

  navItems.forEach(function (n) {
    n.addEventListener('click', function () { setPage(n.getAttribute('data-nav')); });
  });

  // 静态筛选分段（全部/接收/发送）只做视觉状态，不切换评审板页面
  Array.prototype.forEach.call(document.querySelectorAll('.seg.small:not(#pageSeg):not(#dialogSeg)'), function (seg) {
    Array.prototype.forEach.call(seg.querySelectorAll('button'), function (b) {
      b.addEventListener('click', function () {
        Array.prototype.forEach.call(seg.querySelectorAll('button'), function (o) { o.classList.remove('is-on'); });
        b.classList.add('is-on');
      });
    });
  });

  document.addEventListener('keydown', function (e) {
    if (e.altKey || e.ctrlKey || e.metaKey) { return; }
    var map = { '1': 'receive', '2': 'send', '3': 'history', '4': 'devices', '5': 'settings', '6': 'dialogs', '7': 'toasts' };
    if (map[e.key]) { setPage(map[e.key]); }
    if (e.key === 't' || e.key === 'T') {
      setTheme(root.getAttribute('data-theme') === 'dark' ? 'light' : 'dark');
    }
    if (e.key === 'm' || e.key === 'M') {
      var cur = root.getAttribute('data-material');
      setMaterial(materials[(materials.indexOf(cur) + 1) % materials.length]);
    }
  });

  // 支持 ?theme=dark&material=acrylic&view=pc&page=send&dialog=pin 直接打开指定状态（便于截图评审与分享）
  var params = new URLSearchParams(location.search);
  var savedTheme = 'light';
  var savedMaterial = 'mica';
  try {
    savedTheme = localStorage.getItem('kuaichuan-preview-theme') || 'light';
    savedMaterial = localStorage.getItem('kuaichuan-preview-material') || 'mica';
  } catch (e) { /* ignore */ }

  var theme = params.get('theme');
  setTheme(theme === 'dark' || theme === 'light' ? theme : (savedTheme === 'dark' ? 'dark' : 'light'));
  var material = params.get('material');
  setMaterial(materials.indexOf(material) >= 0 ? material : (materials.indexOf(savedMaterial) >= 0 ? savedMaterial : 'mica'));
  var view = params.get('view');
  setView(['both', 'pc', 'phone'].indexOf(view) >= 0 ? view : 'both');
  var page = params.get('page');
  setPage(['receive', 'send', 'history', 'devices', 'settings', 'dialogs', 'toasts'].indexOf(page) >= 0 ? page : 'receive');
  var toast = params.get('toast');
  if (['receive-ok', 'receive-fail', 'send-ok', 'send-fail'].indexOf(toast) >= 0) { setToast(toast); }
  var dialog = params.get('dialog');
  setDialog(dialog || 'receive-request');

  // 首帧主题已定，恢复交互过渡；长页面可用 ?scroll=bottom 直接看尾部（设置页 / 设备管理页）
  setTimeout(function () {
    root.classList.remove('booting');
    if (params.get('scroll') === 'bottom') {
      Array.prototype.forEach.call(document.querySelectorAll('.pc-content, .phone-content'), function (el) {
        el.scrollTop = el.scrollHeight;
      });
    }
  }, 0);
})();
